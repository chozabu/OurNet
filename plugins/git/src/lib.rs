//! Git over OurNet. A repository is a signed `x.git.repo`; each push is an
//! `x.git.push` naming the refs it moved and the `x.git.chunk`s that carry
//! its packfile, exactly as `git pack-objects` wrote it. They sync like any
//! object to the repository's audience: this person's devices, a group, or
//! (in each person's own public space) friends who follow them. Nobody has
//! to be online for a clone, and every push says who made it.
//!
//! Real git reaches it through `git-remote-ournet`, which talks to this
//! plugin over the app's local bridge (the `local` grant): live requests
//! from device "local". The plugin also reads packs itself, a piece per
//! timer tick, to show repositories: files, READMEs, commits with their
//! diffs, and who pushed what.

mod diff;
mod pack;

use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::rc::Rc;

use ournet_plugin::{json, store, ui, Audience, Context, Object, Plugin, Scope, Value};
use pack::{Lookup, Sha};
use serde::{Deserialize, Serialize};

const REPO: &str = "x.git.repo";
const PUSH: &str = "x.git.push";
const CHUNK: &str = "x.git.chunk";
const PERSONAL: &str = "x.git";
const SURFACE: &str = "Git";

/// Raw bytes of pack per chunk: 60000 characters of base64.
const CHUNK_BYTES: usize = 45_000;
/// Largest pack one push may carry.
const MAX_PACK: usize = 16 * 1024 * 1024;
/// Time an indexing step may take before it yields, in milliseconds.
const STEP_MS: u64 = 300;
const INDEX_TIMER: u64 = 1;

/// A person's public space: their own repositories, followed by friends.
fn home(person: &str) -> String {
    format!("x.git.u.{person}")
}

#[derive(Clone, Copy, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
enum Where {
    #[default]
    Personal,
    Group,
    Public,
}

fn where_of(space: &str) -> Where {
    if space == PERSONAL {
        Where::Personal
    } else if space.starts_with("x.git.u.") {
        Where::Public
    } else {
        Where::Group
    }
}

/// The repository's key: names it in `ournet://` addresses.
fn repo_key(space: &str, name: &str) -> String {
    let digest = sha1_smol::Sha1::from(format!("{space}\n{name}")).digest().bytes();
    pack::hex(&digest)[..10].to_string()
}

fn valid_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 100
        && !name.starts_with('.')
        && name.chars().all(|c| c.is_ascii_alphanumeric() || "._-".contains(c))
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Repo {
    key: String,
    name: String,
    space: String,
    place: Where,
    /// Who made it; in public, the only one who may push.
    owner: String,
    description: String,
    created: u64,
    /// When it last changed: created, described or pushed to.
    updated: u64,
    /// The group's name, where known.
    #[serde(default)]
    group: String,
}

#[derive(Clone, Default, Serialize, Deserialize)]
struct Push {
    id: String,
    author: String,
    created: u64,
    /// Ref → new SHA; empty deletes the ref.
    refs: BTreeMap<String, String>,
    /// Ref → the SHA the pusher saw before; empty for a new ref.
    old: BTreeMap<String, String>,
    #[serde(default)]
    force: bool,
    #[serde(default)]
    head: Option<String>,
    chunks: Vec<String>,
    size: u64,
    objects: u32,
    /// Chunks not yet here.
    missing: Vec<String>,
    /// 0 waiting, 1 indexed, 2 could not be read.
    #[serde(default)]
    indexed: u8,
    #[serde(default)]
    error: String,
}

impl Push {
    fn complete(&self) -> bool {
        self.missing.is_empty()
    }
}

fn b64(bytes: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for c in bytes.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        out.push(T[(n >> 18) as usize & 63] as char);
        out.push(T[(n >> 12) as usize & 63] as char);
        out.push(if c.len() > 1 { T[(n >> 6) as usize & 63] as char } else { '=' });
        out.push(if c.len() > 2 { T[n as usize & 63] as char } else { '=' });
    }
    out
}

fn unb64(text: &str) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(text.len() / 4 * 3);
    let (mut acc, mut bits) = (0u32, 0);
    for c in text.bytes() {
        let v = match c {
            b'A'..=b'Z' => c - b'A',
            b'a'..=b'z' => c - b'a' + 26,
            b'0'..=b'9' => c - b'0' + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => break,
            _ => return None,
        };
        acc = acc << 6 | v as u32;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// Joins a pack back together from its chunks.
fn load_pack(chunks: &[String]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    for id in chunks {
        let o = ournet_plugin::get(id).ok_or("a part of it has not arrived yet")?;
        let data = o.json()["data"].as_str().and_then(unb64).ok_or("a part of it is damaged")?;
        out.extend_from_slice(&data);
    }
    Ok(out)
}

/// The objects of one repository: where each is, and the packs lately read.
struct Objects {
    key: String,
    /// Indexed pushes, by ID, with their chunks.
    packs: Vec<(String, Vec<String>)>,
    at: HashMap<Sha, (u16, u32)>,
    cache: Vec<(u16, Rc<Vec<u8>>)>,
}

impl Objects {
    fn load(key: &str, pushes: &[Push]) -> Objects {
        let mut o = Objects { key: key.into(), packs: Vec::new(), at: HashMap::new(), cache: Vec::new() };
        for p in pushes.iter().filter(|p| p.indexed == 1 && !p.chunks.is_empty()) {
            let n = o.packs.len() as u16;
            for e in pack::load_entries(&store::get(&format!("idx/{}", p.id)).unwrap_or_default()) {
                o.at.insert(e.sha, (n, e.offset));
            }
            o.packs.push((p.id.clone(), p.chunks.clone()));
        }
        o
    }

    fn pack(&mut self, n: u16) -> Result<Rc<Vec<u8>>, String> {
        if let Some((_, p)) = self.cache.iter().find(|(i, _)| *i == n) {
            return Ok(p.clone());
        }
        let bytes = Rc::new(load_pack(&self.packs[n as usize].1)?);
        let held: usize = self.cache.iter().map(|(_, p)| p.len()).sum();
        if held + bytes.len() > 24 * 1024 * 1024 || self.cache.len() >= 4 {
            self.cache.remove(0);
        }
        self.cache.push((n, bytes.clone()));
        Ok(bytes)
    }

    fn read(&mut self, sha: &Sha) -> Option<(u8, Vec<u8>)> {
        let (n, offset) = *self.at.get(sha)?;
        let pack = self.pack(n).ok()?;
        pack::read_at(&pack, offset as usize, &HashMap::new(), self).ok()
    }

    fn commit(&mut self, sha: &Sha) -> Option<pack::Commit> {
        match self.read(sha)? {
            (pack::COMMIT, data) => Some(pack::parse_commit(&data)),
            _ => None,
        }
    }

    fn tree(&mut self, sha: &Sha) -> Vec<pack::TreeEntry> {
        match self.read(sha) {
            Some((pack::TREE, data)) => pack::parse_tree(&data),
            _ => Vec::new(),
        }
    }

    /// Follows annotated tags down to what they name.
    fn peel(&mut self, mut sha: Sha) -> Sha {
        for _ in 0..8 {
            match self.read(&sha) {
                Some((pack::TAG, data)) => match pack::tag_target(&data) {
                    Some(t) => sha = t,
                    None => break,
                },
                _ => break,
            }
        }
        sha
    }
}

impl Lookup for Objects {
    fn object(&mut self, sha: &Sha) -> Option<(u8, Vec<u8>)> {
        self.read(sha)
    }
}

/// Lets an indexer resolve deltas against packs indexed earlier.
struct Earlier<'a>(&'a mut Option<Objects>);
impl Lookup for Earlier<'_> {
    fn object(&mut self, sha: &Sha) -> Option<(u8, Vec<u8>)> {
        self.0.as_mut()?.read(sha)
    }
}

#[derive(Default, Clone, Copy, PartialEq)]
enum Mode {
    #[default]
    List,
    New,
    Repo,
    File,
    Commit,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum Tab {
    #[default]
    Code,
    Commits,
    Pushes,
}

#[derive(Default)]
struct Git {
    me: String,
    repos: BTreeMap<String, Repo>,
    pushes: HashMap<String, Vec<Push>>,
    objects: Option<Objects>,
    /// Pushes to index, in order, and the one being indexed.
    queue: Vec<(String, String)>,
    indexing: Option<(String, String, pack::Indexer)>,
    followed: BTreeSet<String>,

    // Where the page is.
    space: String,
    place: Where,
    group_name: String,
    mode: Mode,
    tab: Tab,
    repo: Option<String>,
    branch: Option<String>,
    path: Vec<String>,
    file: Option<String>,
    commit: Option<String>,
    commits_shown: usize,
    draft_name: String,
    draft_description: String,
    error: String,
}

impl Git {
    fn load_pushes(&mut self, key: &str) -> &mut Vec<Push> {
        if !self.pushes.contains_key(key) {
            let list = store::get_json(&format!("pushes/{key}")).unwrap_or_default();
            self.pushes.insert(key.to_string(), list);
        }
        self.pushes.get_mut(key).unwrap()
    }

    fn save_pushes(&self, key: &str) {
        if let Some(list) = self.pushes.get(key) {
            let _ = store::set_json(&format!("pushes/{key}"), list);
        }
    }

    fn save_repos(&self) {
        let _ = store::set_json("repos", &self.repos);
    }

    /// The repository [space]/[name], made from what is known if it is new.
    fn repo_for(&mut self, space: &str, name: &str, author: &str, created: u64) -> &mut Repo {
        let key = repo_key(space, name);
        let place = where_of(space);
        self.repos.entry(key.clone()).or_insert_with(|| Repo {
            key,
            name: name.into(),
            space: space.into(),
            place,
            owner: match place {
                Where::Public => space.trim_start_matches("x.git.u.").to_string(),
                _ => author.to_string(),
            },
            created,
            updated: created,
            ..Default::default()
        })
    }

    /// Whether [author] may change [space]'s repositories. In public only
    /// the space's own person; elsewhere the audience decides.
    fn may_write(space: &str, author: &str) -> bool {
        match where_of(space) {
            Where::Public => space == home(author),
            _ => true,
        }
    }

    fn take(&mut self, o: &Object) -> Option<String> {
        let p = o.json();
        let name = p["repo"].as_str().or(p["name"].as_str())?.to_string();
        if !valid_name(&name) || !Self::may_write(&o.space, &o.author) {
            return None;
        }
        let key = repo_key(&o.space, &name);
        match o.kind.as_str() {
            REPO => {
                let repo = self.repo_for(&o.space, &name, &o.author, o.created);
                if o.created < repo.created || repo.owner.is_empty() {
                    repo.created = o.created;
                    if repo.place != Where::Public {
                        repo.owner = o.author.clone();
                    }
                }
                if o.created >= repo.updated || repo.description.is_empty() {
                    repo.description = p["description"].as_str().unwrap_or("").to_string();
                }
                repo.updated = repo.updated.max(o.created);
                self.save_repos();
            }
            PUSH => {
                self.repo_for(&o.space, &name, &o.author, o.created).updated = o.created;
                let text_map = |v: &Value| -> BTreeMap<String, String> {
                    v.as_object()
                        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string())).collect())
                        .unwrap_or_default()
                };
                // `parts`, not `chunks`: every build reads `chunks` as a file's.
                let chunks: Vec<String> = p["parts"]
                    .as_array()
                    .map(|a| a.iter().filter_map(|c| c.as_str().map(String::from)).collect())
                    .unwrap_or_default();
                let missing = chunks.iter().filter(|c| ournet_plugin::get(c).is_none()).cloned().collect();
                let push = Push {
                    id: o.id.clone(),
                    author: o.author.clone(),
                    created: o.created,
                    refs: text_map(&p["refs"]),
                    old: text_map(&p["old"]),
                    force: p["force"].as_bool().unwrap_or(false),
                    head: p["head"].as_str().map(String::from),
                    size: p["size"].as_u64().unwrap_or(0),
                    objects: p["objects"].as_u64().unwrap_or(0) as u32,
                    chunks,
                    missing,
                    indexed: 0,
                    error: String::new(),
                };
                let complete = push.complete();
                let list = self.load_pushes(&key);
                if list.iter().any(|q| q.id == push.id) {
                    return None;
                }
                list.push(push);
                list.sort_by(|a, b| (a.created, &a.id).cmp(&(b.created, &b.id)));
                self.save_pushes(&key);
                self.save_repos();
                if complete {
                    self.queue.push((key.clone(), o.id.clone()));
                }
            }
            CHUNK => {
                let list = self.load_pushes(&key);
                let mut done = Vec::new();
                for push in list.iter_mut() {
                    if let Some(i) = push.missing.iter().position(|c| *c == o.id) {
                        push.missing.remove(i);
                        if push.complete() {
                            done.push(push.id.clone());
                        }
                    }
                }
                self.save_pushes(&key);
                for id in done {
                    self.queue.push((key.clone(), id));
                }
            }
            _ => return None,
        }
        Some(key)
    }

    /// The refs as the pushes left them, oldest first.
    fn refs(&mut self, key: &str) -> BTreeMap<String, String> {
        let mut refs = BTreeMap::new();
        for p in self.load_pushes(key).iter() {
            for (r, sha) in &p.refs {
                if sha.is_empty() {
                    refs.remove(r);
                } else {
                    refs.insert(r.clone(), sha.clone());
                }
            }
        }
        refs
    }

    fn head(&mut self, key: &str, refs: &BTreeMap<String, String>) -> Option<String> {
        let named = self.load_pushes(key).iter().rev().find_map(|p| p.head.clone());
        named
            .filter(|h| refs.contains_key(h))
            .or_else(|| ["refs/heads/main", "refs/heads/master"].iter().find(|h| refs.contains_key(**h)).map(|h| h.to_string()))
            .or_else(|| refs.keys().find(|r| r.starts_with("refs/heads/")).cloned())
            .or_else(|| refs.keys().next().cloned())
    }

    // Indexing ------------------------------------------------------------

    fn schedule(&self) {
        if self.indexing.is_some() || !self.queue.is_empty() {
            ournet_plugin::timer::set(INDEX_TIMER, 10);
        }
    }

    fn index_step(&mut self) {
        if self.indexing.is_none() {
            while let Some((key, id)) = (!self.queue.is_empty()).then(|| self.queue.remove(0)) {
                let Some(push) = self.load_pushes(&key).iter().find(|p| p.id == id).cloned() else { continue };
                if push.indexed != 0 || !push.complete() {
                    continue;
                }
                if push.chunks.is_empty() {
                    self.finish(&key, &id, Ok(Vec::new()));
                    continue;
                }
                let _ = store::set("indexing", id.as_bytes());
                match load_pack(&push.chunks).and_then(pack::Indexer::new) {
                    Ok(ix) => {
                        self.indexing = Some((key, id, ix));
                        break;
                    }
                    Err(e) => self.finish(&key, &id, Err(e)),
                }
            }
        }
        let Some((key, id, mut ix)) = self.indexing.take() else { return };
        if self.objects.as_ref().map(|o| o.key != key).unwrap_or(true) {
            let pushes = self.load_pushes(&key).clone();
            self.objects = Some(Objects::load(&key, &pushes));
        }
        let until = ournet_plugin::now() + STEP_MS;
        match ix.step(&mut Earlier(&mut self.objects), || ournet_plugin::now() < until) {
            Ok(true) => self.finish(&key, &id, Ok(ix.entries)),
            Ok(false) => self.indexing = Some((key, id, ix)),
            Err(e) => self.finish(&key, &id, Err(e)),
        }
        self.schedule();
    }

    fn finish(&mut self, key: &str, id: &str, result: Result<Vec<pack::Entry>, String>) {
        let outcome = match result {
            Ok(entries) => store::set(&format!("idx/{id}"), &pack::save_entries(&entries)).map(|_| ()),
            Err(e) => Err(e),
        };
        if let Some(p) = self.load_pushes(key).iter_mut().find(|p| p.id == id) {
            match outcome {
                Ok(()) => p.indexed = 1,
                Err(e) => {
                    ournet_plugin::warn(&format!("could not read push {id}: {e}"));
                    p.indexed = 2;
                    p.error = e;
                }
            }
        }
        self.save_pushes(key);
        store::remove("indexing");
        if self.objects.as_ref().map(|o| o.key == key).unwrap_or(false) {
            let pushes = self.load_pushes(key).clone();
            self.objects = Some(Objects::load(key, &pushes));
        }
        if self.repo.as_deref() == Some(key) {
            self.show();
        }
    }

    // The local bridge ----------------------------------------------------

    /// Finds the repository an `ournet://` address names: its key (as the
    /// app shows it), optionally followed by `/name`, or a name alone when
    /// only one repository here has it.
    fn resolve(&self, address: &str) -> Result<String, String> {
        let address = address.trim().trim_start_matches("ournet://").trim_end_matches('/');
        let address = address.strip_suffix(".git").unwrap_or(address);
        let first = address.split('/').next().unwrap_or("");
        if self.repos.contains_key(first) {
            return Ok(first.to_string());
        }
        let name = address.rsplit('/').next().unwrap_or("");
        let found: Vec<&Repo> = self.repos.values().filter(|r| r.name == name).collect();
        match found.as_slice() {
            [one] => Ok(one.key.clone()),
            [] => Err(format!(
                "no repository {address} here; make it in OurNet's Git page first, or wait for it to sync"
            )),
            many => Err(format!(
                "several repositories are called {name}: use one of {}",
                many.iter().map(|r| format!("ournet://{}/{}", r.key, r.name)).collect::<Vec<_>>().join(", ")
            )),
        }
    }

    fn bridge(&mut self, request: &Value, body: &[u8]) -> Result<(Value, Vec<u8>), String> {
        let op = request["op"].as_str().unwrap_or("");
        if op == "repos" {
            let list: Vec<Value> = self
                .repos
                .values()
                .map(|r| json!({"url": format!("ournet://{}/{}", r.key, r.name), "where": r.place}))
                .collect();
            return Ok((json!({"repos": list}), Vec::new()));
        }
        let key = self.resolve(request["repo"].as_str().unwrap_or(""))?;
        match op {
            "list" => {
                let refs = self.refs(&key);
                let head = self.head(&key, &refs);
                let waiting = self.load_pushes(&key).iter().filter(|p| !p.complete()).count();
                Ok((json!({"refs": refs, "head": head, "waiting": waiting}), Vec::new()))
            }
            "packs" => {
                let pushes = self.load_pushes(&key);
                let packs: Vec<Value> = pushes
                    .iter()
                    .filter(|p| p.complete() && !p.chunks.is_empty())
                    .map(|p| {
                        json!({
                            "id": p.id,
                            "tips": p.refs.values().filter(|s| !s.is_empty()).collect::<Vec<_>>(),
                            "size": p.size,
                        })
                    })
                    .collect();
                let waiting = pushes.iter().filter(|p| !p.complete()).count();
                Ok((json!({"packs": packs, "waiting": waiting}), Vec::new()))
            }
            "pack" => {
                let id = request["id"].as_str().unwrap_or("");
                let push = self.load_pushes(&key).iter().find(|p| p.id == id).cloned().ok_or("no such push")?;
                Ok((json!({}), load_pack(&push.chunks)?))
            }
            "push" => self.receive(&key, request, body).map(|id| (json!({"id": id}), Vec::new())),
            _ => Err(format!("unknown request {op}")),
        }
    }

    /// Publishes a push from local git: its pack in chunks, then the refs.
    fn receive(&mut self, key: &str, request: &Value, pack_bytes: &[u8]) -> Result<String, String> {
        let repo = self.repos.get(key).cloned().ok_or("no such repository")?;
        if !Self::may_write(&repo.space, &self.me) {
            return Err("only its owner can push to it; make your own copy and push there".into());
        }
        let text_map = |v: &Value| -> BTreeMap<String, String> {
            v.as_object()
                .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string())).collect())
                .unwrap_or_default()
        };
        let refs = text_map(&request["refs"]);
        let old = text_map(&request["old"]);
        let force = request["force"].as_bool().unwrap_or(false);
        if refs.is_empty() || refs.len() > 100 {
            return Err("nothing to push".into());
        }
        for (r, sha) in &refs {
            if !r.starts_with("refs/") || r.len() > 200 || !(sha.is_empty() || pack::unhex(sha).is_some()) {
                return Err(format!("bad ref {r}"));
            }
        }
        // Someone else may have pushed since git listed the refs.
        let current = self.refs(key);
        if !force {
            for r in refs.keys() {
                let was = old.get(r).map(String::as_str).unwrap_or("");
                if current.get(r).map(String::as_str).unwrap_or("") != was {
                    return Err(format!("{r} changed since you fetched; fetch and try again"));
                }
            }
        }
        let objects = if pack_bytes.is_empty() { 0 } else { pack::check(pack_bytes)? };
        if pack_bytes.len() > MAX_PACK {
            return Err(format!("too large to push here ({} MB at most)", MAX_PACK / 1024 / 1024));
        }
        let to = match repo.place {
            Where::Personal => Audience::Personal,
            Where::Group => Audience::Group,
            Where::Public => Audience::Public,
        };
        let mut chunks = Vec::new();
        if objects > 0 {
            for part in pack_bytes.chunks(CHUNK_BYTES) {
                let payload = json!({"repo": repo.name, "data": b64(part)});
                chunks.push(ournet_plugin::publish(CHUNK, &repo.space, to.clone(), &payload)?);
            }
        }
        let mut payload = json!({
            "repo": repo.name,
            "refs": refs,
            "old": old,
            "parts": chunks,
            "size": if objects > 0 { pack_bytes.len() } else { 0 },
            "objects": objects,
        });
        if force {
            payload["force"] = true.into();
        }
        if let Some(head) = request["head"].as_str().filter(|h| h.starts_with("refs/heads/")) {
            payload["head"] = head.into();
        }
        ournet_plugin::publish(PUSH, &repo.space, to, &payload)
    }

    // The page ------------------------------------------------------------

    fn open_objects(&mut self, key: &str) -> &mut Objects {
        if self.objects.as_ref().map(|o| o.key != key).unwrap_or(true) {
            let pushes = self.load_pushes(key).clone();
            self.objects = Some(Objects::load(key, &pushes));
        }
        self.objects.as_mut().unwrap()
    }

    fn show(&mut self) {
        let mut data = json!({
            "mode": match self.mode {
                Mode::List => "list",
                Mode::New => "new",
                Mode::Repo => "repo",
                Mode::File => "file",
                Mode::Commit => "commit",
            },
            "where": match self.place {
                Where::Personal => "Your own repositories, on your devices".to_string(),
                Where::Group => format!("Shared with {}", self.group_name),
                Where::Public => "Public: yours, and friends' you follow".to_string(),
            },
        });
        match self.mode {
            Mode::List => self.show_list(&mut data),
            Mode::New => {
                data["draftName"] = self.draft_name.clone().into();
                data["draftDescription"] = self.draft_description.clone().into();
                data["error"] = self.error.clone().into();
            }
            Mode::Repo | Mode::File | Mode::Commit => self.show_repo(&mut data),
        }
        ui::update(SURFACE, &data);
    }

    fn visible(&self) -> Vec<&Repo> {
        let mut list: Vec<&Repo> = self
            .repos
            .values()
            .filter(|r| match self.place {
                Where::Public => r.place == Where::Public,
                _ => r.space == self.space,
            })
            .collect();
        list.sort_by(|a, b| b.updated.cmp(&a.updated));
        list
    }

    fn show_list(&mut self, data: &mut Value) {
        let repos: Vec<Value> = self
            .visible()
            .iter()
            .map(|r| {
                json!({
                    "key": r.key,
                    "name": r.name,
                    "description": if r.description.is_empty() { "No description".to_string() } else { r.description.clone() },
                    "owner": r.owner,
                    "at": r.updated as i64,
                })
            })
            .collect();
        data["empty"] = repos.is_empty().into();
        data["repos"] = repos.into();
        data["emptyText"] = match self.place {
            Where::Public => "No public repositories yet. Yours are followed by your friends; theirs show here.",
            _ => "No repositories yet. Make one with New repository, then push to it with git.",
        }
        .into();
    }

    fn show_repo(&mut self, data: &mut Value) {
        let Some(key) = self.repo.clone() else { return };
        let Some(repo) = self.repos.get(&key).cloned() else { return };
        let refs = self.refs(&key);
        let head = self.head(&key, &refs);
        let branch = self.branch.clone().filter(|b| refs.contains_key(b)).or(head);
        self.branch = branch.clone();
        let pushes = self.load_pushes(&key).clone();
        let waiting: usize = pushes.iter().map(|p| p.missing.len()).sum();
        let unread = pushes.iter().filter(|p| p.complete() && p.indexed == 0).count();
        let failed = pushes.iter().filter(|p| p.indexed == 2).count();
        let mut notice = Vec::new();
        if waiting > 0 {
            notice.push(format!("Waiting for {waiting} parts from friends."));
        }
        if unread > 0 {
            notice.push("Reading the newest pushes…".to_string());
        }
        if failed > 0 {
            notice.push(format!("{failed} pushes could not be read here; git can still fetch them."));
        }
        let url = format!("ournet://{}/{}", repo.key, repo.name);
        data["repo"] = json!({
            "name": repo.name,
            "description": repo.description,
            "owner": repo.owner,
            "url": url,
            "clone": format!("git clone {url}"),
            "notice": notice.join(" "),
            "mine": Self::may_write(&repo.space, &self.me),
        });
        data["tab"] = match self.tab {
            Tab::Code => "code",
            Tab::Commits => "commits",
            Tab::Pushes => "pushes",
        }
        .into();
        data["branches"] = refs
            .keys()
            .filter(|r| r.starts_with("refs/heads/") || r.starts_with("refs/tags/"))
            .map(|r| {
                let short = r.trim_start_matches("refs/heads/").replace("refs/tags/", "tag ");
                json!({"ref": r, "name": short, "selected": Some(r) == branch.as_ref()})
            })
            .collect::<Vec<_>>()
            .into();
        data["branch"] = branch
            .as_deref()
            .map(|b| b.trim_start_matches("refs/heads/").to_string())
            .unwrap_or_default()
            .into();
        data["empty"] = refs.is_empty().into();
        data["pushHelp"] = format!(
            "git remote add ournet {url}\ngit push ournet main"
        )
        .into();
        let tip = branch.as_ref().and_then(|b| refs.get(b)).and_then(|s| pack::unhex(s));
        match self.mode {
            Mode::Repo => match self.tab {
                Tab::Code => self.show_code(data, tip),
                Tab::Commits => self.show_commits(data, tip),
                Tab::Pushes => self.show_pushes(data, &pushes),
            },
            Mode::File => self.show_file(data, tip),
            Mode::Commit => self.show_commit(data),
            _ => {}
        }
    }

    /// The tree at [path] under [commit], or None where it is not (yet) here.
    fn tree_at(&mut self, commit: Sha, path: &[String]) -> Option<Vec<pack::TreeEntry>> {
        let key = self.repo.clone()?;
        let objects = self.open_objects(&key);
        let commit = objects.peel(commit);
        let mut tree = objects.commit(&commit)?.tree?;
        for part in path {
            let entry = objects.tree(&tree).into_iter().find(|e| &e.name == part && e.is_dir())?;
            tree = entry.sha;
        }
        objects.read(&tree)?;
        Some(objects.tree(&tree))
    }

    fn crumbs(&self, data: &mut Value) {
        let mut crumbs = vec![json!({"name": data["repo"]["name"].clone(), "depth": 0})];
        for (i, part) in self.path.iter().enumerate() {
            crumbs.push(json!({"name": part, "depth": i + 1}));
        }
        data["crumbs"] = crumbs.into();
    }

    fn show_code(&mut self, data: &mut Value, tip: Option<Sha>) {
        self.crumbs(data);
        data["hasLast"] = false.into();
        let Some(tip) = tip else {
            data["entries"] = json!([]);
            data["readme"] = "".into();
            data["missing"] = false.into();
            return;
        };
        let Some(mut entries) = self.tree_at(tip, &self.path.clone()) else {
            data["entries"] = json!([]);
            data["readme"] = "".into();
            data["missing"] = true.into();
            return;
        };
        data["missing"] = false.into();
        entries.sort_by(|a, b| (!a.is_dir(), a.name.to_lowercase()).cmp(&(!b.is_dir(), b.name.to_lowercase())));
        data["entries"] = entries
            .iter()
            .map(|e| {
                json!({
                    "name": e.name,
                    "icon": if e.is_dir() { "📁" } else if e.is_submodule() { "🔗" } else { "📄" },
                    "dir": e.is_dir(),
                })
            })
            .collect::<Vec<_>>()
            .into();
        let key = self.repo.clone().unwrap();
        let objects = self.open_objects(&key);
        let readme = entries
            .iter()
            .find(|e| !e.is_dir() && ["readme.md", "readme", "readme.txt"].contains(&e.name.to_lowercase().as_str()))
            .and_then(|e| objects.read(&e.sha))
            .map(|(_, d)| text_of(&d, 100_000).0)
            .unwrap_or_default();
        data["readme"] = readme.into();
        let commit = objects.peel(tip);
        if let Some(c) = objects.commit(&commit) {
            data["hasLast"] = true.into();
            data["last"] = json!({
                "title": c.title(),
                "author": c.author.name,
                "at": c.committer.time * 1000,
                "short": &pack::hex(&commit)[..7],
                "sha": pack::hex(&commit),
            });
        }
    }

    fn show_commits(&mut self, data: &mut Value, tip: Option<Sha>) {
        let key = self.repo.clone().unwrap();
        let shown = self.commits_shown;
        let objects = self.open_objects(&key);
        let mut list = Vec::new();
        let mut at = tip.map(|t| objects.peel(t));
        let mut more = false;
        while let Some(sha) = at {
            if list.len() >= shown {
                more = true;
                break;
            }
            let Some(c) = objects.commit(&sha) else { break };
            list.push(json!({
                "sha": pack::hex(&sha),
                "short": &pack::hex(&sha)[..7],
                "title": c.title(),
                "author": c.author.name,
                "at": c.committer.time * 1000,
            }));
            at = c.parents.first().copied();
        }
        data["commits"] = list.into();
        data["more"] = more.into();
    }

    fn show_pushes(&mut self, data: &mut Value, pushes: &[Push]) {
        let list: Vec<Value> = pushes
            .iter()
            .rev()
            .take(100)
            .map(|p| {
                let mut moved: Vec<String> = p
                    .refs
                    .iter()
                    .map(|(r, sha)| {
                        let name = r.trim_start_matches("refs/heads/").replace("refs/tags/", "tag ");
                        if sha.is_empty() {
                            format!("deleted {name}")
                        } else {
                            format!("{name} → {}", &sha[..7.min(sha.len())])
                        }
                    })
                    .collect();
                if p.force {
                    moved.push("(forced)".into());
                }
                let state = if !p.complete() {
                    format!(" · waiting for {} of {} parts", p.missing.len(), p.chunks.len())
                } else if p.indexed == 2 {
                    format!(" · could not be read: {}", p.error)
                } else {
                    String::new()
                };
                json!({
                    "author": p.author,
                    "at": p.created as i64,
                    "summary": moved.join(", "),
                    "detail": format!("{} objects, {}{}", p.objects, size(p.size), state),
                })
            })
            .collect();
        data["pushes"] = list.into();
    }

    fn show_file(&mut self, data: &mut Value, tip: Option<Sha>) {
        self.crumbs(data);
        let name = self.file.clone().unwrap_or_default();
        let at = match &self.commit {
            Some(c) => pack::unhex(c),
            None => tip,
        };
        let entry = at
            .and_then(|t| self.tree_at(t, &self.path.clone()))
            .and_then(|entries| entries.into_iter().find(|e| e.name == name));
        let key = self.repo.clone().unwrap();
        let objects = self.open_objects(&key);
        let (text, note) = match entry.and_then(|e| objects.read(&e.sha)) {
            Some((_, bytes)) => {
                let (text, binary) = text_of(&bytes, 200_000);
                if binary {
                    (String::new(), format!("Binary file, {}", size(bytes.len() as u64)))
                } else if text.len() < bytes.len() {
                    (text, format!("Showing the start of {}", size(bytes.len() as u64)))
                } else {
                    let lines = text.lines().count();
                    (text, format!("{lines} lines, {}", size(bytes.len() as u64)))
                }
            }
            None => (String::new(), "Not here yet.".to_string()),
        };
        data["file"] = json!({"name": name, "text": text, "note": note});
    }

    fn show_commit(&mut self, data: &mut Value) {
        let key = self.repo.clone().unwrap();
        let Some(sha) = self.commit.as_deref().and_then(pack::unhex) else { return };
        let objects = self.open_objects(&key);
        let Some(c) = objects.commit(&sha) else {
            data["commit"] = json!({"title": "Not here yet", "body": "", "short": "", "author": "", "at": 0});
            data["diff"] = json!([]);
            return;
        };
        let body = c.message.split_once('\n').map(|(_, b)| b.trim().to_string()).unwrap_or_default();
        data["commit"] = json!({
            "title": c.title(),
            "body": body,
            "short": &pack::hex(&sha)[..7],
            "sha": pack::hex(&sha),
            "author": c.author.name,
            "at": c.committer.time * 1000,
            "parents": c.parents.iter().map(|p| pack::hex(p)[..7].to_string()).collect::<Vec<_>>().join(", "),
        });
        let parent_tree = c.parents.first().and_then(|p| objects.commit(p)).and_then(|p| p.tree);
        let mut changes = Vec::new();
        diff_trees(objects, parent_tree, c.tree, "", &mut changes);
        let mut lines: Vec<Value> = Vec::new();
        let mut files: Vec<Value> = Vec::new();
        for (path, status, a, b) in &changes {
            files.push(json!({"path": path, "status": status}));
            let add = |lines: &mut Vec<Value>, kind: char, text: String| {
                let bg: u32 = match kind {
                    '+' => 0x3328A745,
                    '-' => 0x33D73A49,
                    '@' => 0x220366D6,
                    'f' => 0x22808080,
                    _ => 0x00000000,
                };
                let prefix = if kind == '@' || kind == 'f' { String::new() } else { kind.to_string() };
                lines.push(json!({"text": format!("{prefix}{text}"), "bg": bg as i64}));
            };
            add(&mut lines, 'f', format!("{status} {path}"));
            if lines.len() > 1500 {
                add(&mut lines, ' ', "More changes are not shown here.".into());
                continue;
            }
            let read = |o: &mut Objects, s: &Option<Sha>| -> Option<(String, bool)> {
                match s {
                    None => Some((String::new(), false)),
                    Some(s) => o.read(s).map(|(_, d)| {
                        let (t, binary) = text_of(&d, 300_000);
                        let cut = t.len() < d.len();
                        (t, binary || cut)
                    }),
                }
            };
            match (read(objects, a), read(objects, b)) {
                (Some((old, false)), Some((new, false))) => match diff::unified(&old, &new, 3) {
                    Some(hunks) => {
                        for (k, l) in hunks {
                            add(&mut lines, k, l);
                        }
                    }
                    None => add(&mut lines, ' ', "Too large to compare here.".into()),
                },
                (Some(_), Some(_)) => add(&mut lines, ' ', "Binary or large file.".into()),
                _ => add(&mut lines, ' ', "Not here yet.".into()),
            }
        }
        data["files"] = files.into();
        data["diff"] = lines.into();
    }

    fn open_repo(&mut self, key: &str) {
        self.repo = Some(key.to_string());
        self.mode = Mode::Repo;
        self.tab = Tab::Code;
        self.branch = None;
        self.path.clear();
        self.file = None;
        self.commit = None;
        self.commits_shown = 30;
        self.show();
    }

    fn create(&mut self) {
        let name = self.draft_name.trim().to_string();
        if !valid_name(&name) {
            self.error = "Use letters, digits, '.', '-' and '_' for the name.".into();
            return self.show();
        }
        let space = match self.place {
            Where::Public => home(&self.me),
            _ => self.space.clone(),
        };
        let key = repo_key(&space, &name);
        if self.repos.contains_key(&key) {
            self.error = "There is already a repository with that name here.".into();
            return self.show();
        }
        let to = match self.place {
            Where::Personal => Audience::Personal,
            Where::Group => Audience::Group,
            Where::Public => Audience::Public,
        };
        let payload = json!({"name": name, "description": self.draft_description.trim()});
        match ournet_plugin::publish(REPO, &space, to, &payload) {
            Ok(_) => {
                // Taken straight away, so the page can open it; the host
                // also hands it back.
                let me = self.me.clone();
                let group = if self.place == Where::Group { self.group_name.clone() } else { String::new() };
                let repo = self.repo_for(&space, &name, &me, ournet_plugin::now());
                repo.description = payload["description"].as_str().unwrap_or("").into();
                repo.group = group;
                self.save_repos();
                self.error.clear();
                self.open_repo(&key);
            }
            Err(e) => {
                self.error = e;
                self.show();
            }
        }
    }

    fn follow_friends(&mut self) {
        let mut people = vec![self.me.clone()];
        people.extend(ournet_plugin::contacts().into_iter().map(|c| c.person));
        let mut changed = false;
        for person in people {
            if self.followed.insert(person.clone()) {
                let _ = ournet_plugin::follow(&home(&person), true);
                changed = true;
            }
        }
        if changed {
            let _ = store::set_json("followed", &self.followed);
        }
    }
}

/// Changed files between two trees: path, A/M/D, old and new blob.
fn diff_trees(
    objects: &mut Objects,
    a: Option<Sha>,
    b: Option<Sha>,
    prefix: &str,
    out: &mut Vec<(String, &'static str, Option<Sha>, Option<Sha>)>,
) {
    if a == b || out.len() >= 300 {
        return;
    }
    let left = a.map(|t| objects.tree(&t)).unwrap_or_default();
    let right = b.map(|t| objects.tree(&t)).unwrap_or_default();
    let mut names: BTreeSet<&str> = left.iter().map(|e| e.name.as_str()).collect();
    names.extend(right.iter().map(|e| e.name.as_str()));
    for name in names {
        let l = left.iter().find(|e| e.name == name);
        let r = right.iter().find(|e| e.name == name);
        let path = format!("{prefix}{name}");
        let dir = |e: Option<&pack::TreeEntry>| e.filter(|e| e.is_dir()).map(|e| e.sha);
        let file = |e: Option<&pack::TreeEntry>| e.filter(|e| !e.is_dir() && !e.is_submodule()).map(|e| e.sha);
        if dir(l).is_some() || dir(r).is_some() {
            diff_trees(objects, dir(l), dir(r), &format!("{path}/"), out);
        }
        let (fl, fr) = (file(l), file(r));
        if fl != fr {
            let status = match (fl, fr) {
                (None, Some(_)) => "Added",
                (Some(_), None) => "Deleted",
                _ => "Changed",
            };
            out.push((path, status, fl, fr));
        }
    }
}

/// Text to show for [bytes], at most [max] of them; true when binary.
fn text_of(bytes: &[u8], max: usize) -> (String, bool) {
    if bytes[..bytes.len().min(8000)].contains(&0) {
        return (String::new(), true);
    }
    let mut end = bytes.len().min(max);
    while end < bytes.len() && end > 0 && (bytes[end] & 0xC0) == 0x80 {
        end -= 1;
    }
    (String::from_utf8_lossy(&bytes[..end]).into_owned(), false)
}

fn size(bytes: u64) -> String {
    match bytes {
        b if b < 1024 => format!("{b} bytes"),
        b if b < 1024 * 1024 => format!("{:.1} KB", b as f64 / 1024.0),
        b => format!("{:.1} MB", b as f64 / 1024.0 / 1024.0),
    }
}

/// A local request or reply: a JSON line, then raw bytes.
fn split(payload: &[u8]) -> (Value, &[u8]) {
    let end = payload.iter().position(|&b| b == b'\n').unwrap_or(payload.len());
    let header = ournet_plugin::serde_json::from_slice(&payload[..end]).unwrap_or(Value::Null);
    (header, payload.get(end + 1..).unwrap_or(&[]))
}

impl Plugin for Git {
    fn init(&mut self) {
        self.me = ournet_plugin::me();
        self.repos = store::get_json("repos").unwrap_or_default();
        self.followed = store::get_json("followed").unwrap_or_default();
        // A pack that stopped the plugin mid-read is not read again.
        if let Some(id) = store::get("indexing") {
            let id = String::from_utf8_lossy(&id).to_string();
            for key in self.repos.keys().cloned().collect::<Vec<_>>() {
                if self.load_pushes(&key).iter().any(|p| p.id == id) {
                    self.finish(&key.clone(), &id, Err("it stopped the plugin while being read".into()));
                }
            }
            store::remove("indexing");
        }
        for key in self.repos.keys().cloned().collect::<Vec<_>>() {
            for p in self.load_pushes(&key).clone() {
                if p.complete() && p.indexed == 0 {
                    self.queue.push((key.clone(), p.id));
                }
            }
        }
        if self.space.is_empty() {
            self.space = PERSONAL.into();
        }
        self.schedule();
    }

    fn on_objects(&mut self, objects: Vec<Object>) {
        let mut changed = BTreeSet::new();
        for o in &objects {
            if let Some(key) = self.take(o) {
                changed.insert(key);
            }
        }
        self.schedule();
        let shown = match self.mode {
            Mode::List => true,
            Mode::New => false,
            _ => self.repo.as_ref().is_some_and(|r| changed.contains(r)),
        };
        if shown && !changed.is_empty() {
            self.show();
        }
    }

    fn on_open(&mut self, _surface: &str, context: Context) {
        let (space, place) = match (context.scope, &context.space) {
            (Scope::Group, Some(space)) => (space.clone(), Where::Group),
            (Scope::Public, _) => (home(&self.me), Where::Public),
            _ => (PERSONAL.to_string(), Where::Personal),
        };
        if place == Where::Public {
            self.follow_friends();
        }
        self.group_name = context.name.unwrap_or_else(|| "the group".into());
        if space != self.space || place != self.place {
            self.mode = Mode::List;
            self.repo = None;
        }
        self.space = space;
        self.place = place;
        self.show();
    }

    fn on_event(&mut self, _surface: &str, name: &str, args: Value) {
        let text = |k: &str| args[k].as_str().unwrap_or("").to_string();
        match name {
            "new" => {
                self.mode = Mode::New;
                self.draft_name.clear();
                self.draft_description.clear();
                self.error.clear();
                self.show();
            }
            "draftName" => self.draft_name = text("value"),
            "draftDescription" => self.draft_description = text("value"),
            "create" => self.create(),
            "open" => self.open_repo(&text("key")),
            "tab" => {
                self.tab = match text("tab").as_str() {
                    "commits" => Tab::Commits,
                    "pushes" => Tab::Pushes,
                    _ => Tab::Code,
                };
                self.mode = Mode::Repo;
                self.commit = None;
                self.show();
            }
            "branch" => {
                self.branch = Some(text("ref"));
                self.path.clear();
                self.mode = Mode::Repo;
                self.show();
            }
            "entry" => {
                if args["dir"].as_bool() == Some(true) {
                    self.path.push(text("name"));
                    self.mode = Mode::Repo;
                } else {
                    self.file = Some(text("name"));
                    self.commit = None;
                    self.mode = Mode::File;
                }
                self.show();
            }
            "crumb" => {
                let depth = args["depth"].as_u64().unwrap_or(0) as usize;
                self.path.truncate(depth);
                self.file = None;
                self.commit = None;
                self.mode = Mode::Repo;
                self.tab = Tab::Code;
                self.show();
            }
            "commit" => {
                self.commit = Some(text("sha"));
                self.mode = Mode::Commit;
                self.show();
            }
            "more" => {
                self.commits_shown += 30;
                self.show();
            }
            "back" => {
                self.mode = match self.mode {
                    Mode::File | Mode::Commit => Mode::Repo,
                    _ => Mode::List,
                };
                if self.mode == Mode::List {
                    self.repo = None;
                }
                self.file = None;
                self.commit = None;
                self.show();
            }
            _ => {}
        }
    }

    fn on_request(&mut self, device: &str, payload: &[u8]) -> Result<Vec<u8>, String> {
        // Only the app's local bridge, for git on this computer.
        if device != "local" {
            return Err("not handled".into());
        }
        let (request, body) = split(payload);
        let (header, bytes) = self.bridge(&request, body)?;
        let mut out = header.to_string().into_bytes();
        out.push(b'\n');
        out.extend_from_slice(&bytes);
        Ok(out)
    }

    fn on_timer(&mut self, token: u64) {
        if token == INDEX_TIMER {
            self.index_step();
        }
    }

    fn save_state(&mut self) -> Vec<u8> {
        json!({"space": self.space, "place": self.place, "group": self.group_name, "repo": self.repo})
            .to_string()
            .into_bytes()
    }

    fn restore(&mut self, state: Vec<u8>) {
        let v: Value = ournet_plugin::serde_json::from_slice(&state).unwrap_or(Value::Null);
        self.space = v["space"].as_str().unwrap_or(PERSONAL).into();
        self.place = ournet_plugin::serde_json::from_value(v["place"].clone()).unwrap_or_default();
        self.group_name = v["group"].as_str().unwrap_or("").into();
        if let Some(repo) = v["repo"].as_str() {
            self.repo = Some(repo.into());
            self.mode = Mode::Repo;
            self.commits_shown = 30;
        }
    }
}

ournet_plugin::plugin!(Git);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn base64_round_trips() {
        for n in 0..10 {
            let bytes: Vec<u8> = (0..n).map(|i| (i * 37) as u8).collect();
            assert_eq!(unb64(&b64(&bytes)).unwrap(), bytes);
        }
        assert_eq!(b64(b"hi!"), "aGkh");
    }

    #[test]
    fn names_and_places() {
        assert!(valid_name("my-repo.v2_x"));
        assert!(!valid_name(".hidden"));
        assert!(!valid_name("a b"));
        assert_eq!(where_of(PERSONAL), Where::Personal);
        assert_eq!(where_of(&home("abc")), Where::Public);
        assert_eq!(where_of("g123"), Where::Group);
        assert!(Git::may_write(&home("abc"), "abc"));
        assert!(!Git::may_write(&home("abc"), "def"));
        assert_eq!(repo_key("x.git", "a").len(), 10);
    }
}
