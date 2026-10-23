//! Git over OurNet. A repository is a signed `x.git.repo`; each push is an
//! `x.git.push` naming the refs it moved, with its packfile, exactly as
//! `git pack-objects` wrote it, attached as the push's file. They sync like
//! any object to the repository's audience: this person's devices, a group,
//! or (in each person's own public space) friends who follow them; a pack is
//! fetched from whoever has it when it is read. Nobody has to be online for
//! a clone, and every push says who made it.
//!
//! Real git reaches it through `git-remote-ournet`, which talks to this
//! plugin over the app's local bridge (the `local` grant): live requests
//! from device "local". The plugin also reads packs itself, a piece per
//! timer tick, to show repositories: files, READMEs, commits with their
//! diffs, and who pushed what.

mod diff;
mod pack;

use std::collections::{BTreeMap, BTreeSet, HashMap, VecDeque};
use std::rc::Rc;
use std::cell::RefCell;

use ournet_plugin::{files, file_ranges, index, json, store, ui, Audience, Context, Object, Plugin, Scope, Value};
use pack::{Lookup, Sha};
use serde::{Deserialize, Serialize};

const REPO: &str = "x.git.repo";
const PUSH: &str = "x.git.push";
const DELETE: &str = "x.git.delete";
const PERSONAL: &str = "x.git";
const SURFACE: &str = "Git";

/// Largest pack one push may carry: the most a plugin's file may hold.
const MAX_PACK: usize = 16 * 1024 * 1024;
/// Time an indexing step may take before it yields, in milliseconds.
const STEP_MS: u64 = 16;
const INDEX_TIMER: u64 = 1;
/// Packs not here yet are asked for again after this, in milliseconds.
const RETRY_MS: u32 = 30_000;
const RETRY_TIMER: u64 = 2;
/// What this version keeps in storage. Before 2, packs travelled as
/// `x.git.chunk` objects; those pushes are left out and pushed again.
const FORMAT: &[u8] = b"4";

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

fn valid_ref(name: &str) -> bool {
    name.starts_with("refs/") && !name.ends_with('/') && !name.ends_with('.')
        && !name.contains("..") && !name.contains("@{") && !name.contains("//")
        && !name.bytes().any(|b| b <= 32 || b == 127 || b"~^:?*[\\".contains(&b))
        && name.split('/').all(|part| !part.is_empty() && !part.starts_with('.') && !part.ends_with(".lock"))
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
    /// A signed deletion hides this incarnation, including late old pushes.
    #[serde(default)]
    deleted_at: u64,
    #[serde(default)]
    metadata_at: u64,
    #[serde(default)]
    metadata_owner: String,
    #[serde(default)]
    deleted: bool,
}

impl Repo {
    fn delete_before(&mut self, at: u64) -> bool {
        if at <= self.deleted_at { return false; }
        self.deleted_at = at;
        self.deleted = self.metadata_at <= at;
        if !self.deleted {
            self.created = self.metadata_at;
            self.owner = self.metadata_owner.clone();
        }
        true
    }
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
    /// It carries a pack as its file (a push that only deletes refs does
    /// not).
    pack: bool,
    size: u64,
    objects: u32,
    /// 0 waiting, 1 indexed, 2 could not be read.
    #[serde(default)]
    indexed: u8,
    /// Why it could not be read, or that its pack is not here yet.
    #[serde(default)]
    error: String,
}

impl Push {
    fn counts(&self) -> [usize; 3] {
        [usize::from(self.fetching()), usize::from(!self.complete() && !self.fetching()), usize::from(self.indexed == 2)]
    }
    /// Its pack (if any) has been read here.
    fn complete(&self) -> bool {
        self.indexed != 0
    }

    /// Its pack could not be fetched yet: no friend that has it answered.
    fn fetching(&self) -> bool {
        self.indexed == 0 && !self.error.is_empty()
    }
}

/// A push's pack: its file, fetched from friends when it is not here.
fn load_pack(push: &str) -> Result<Vec<u8>, String> {
    files::read(push)
}

fn transient(error: &str) -> bool {
    ["not here", "No online source", "TimeoutException", "queue is full"].iter().any(|s| error.contains(s))
}

/// Packed attachment windows. Clones share a small page LRU, never the pack.
#[derive(Clone)]
struct FilePack {
    id: String,
    size: u64,
    bucket: String,
    pages: Rc<RefCell<Vec<(u64, Rc<Vec<u8>>)>>>,
}

impl FilePack {
    fn new(id: &str, size: u64, key: &str) -> Self {
        Self { id: id.into(), size, bucket: format!("objects/{key}"), pages: Rc::new(RefCell::new(Vec::new())) }
    }
}

impl pack::Source for FilePack {
    fn len(&self) -> u64 { self.size }
    fn range(&mut self, offset: u64, length: usize) -> Result<Vec<u8>, String> {
        if offset > self.size || length as u64 > self.size - offset { return Err("pack range is outside file".into()); }
        let mut out = Vec::with_capacity(length);
        let mut at = offset;
        while out.len() < length {
            let page = at / 65536 * 65536;
            let cached = { let mut pages = self.pages.borrow_mut(); pages.iter().position(|(p,_)| *p == page).map(|i| { let v=pages.remove(i); let data=v.1.clone(); pages.push(v); data }) };
            let bytes = match cached {
                Some(bytes) => bytes,
                None => {
                    let n = (self.size - page).min(65536) as u32;
                    let bytes = Rc::new(file_ranges::read(&self.id, page, n)?);
                    if bytes.len() != n as usize { return Err("file range was cut short".into()); }
                    let mut pages = self.pages.borrow_mut();
                    if pages.len() >= 4 { pages.remove(0); }
                    pages.push((page, bytes.clone()));
                    bytes
                }
            };
            let start = (at - page) as usize;
            let n = (length-out.len()).min(bytes.len()-start);
            out.extend_from_slice(&bytes[start..start+n]);
            at += n as u64;
        }
        Ok(out)
    }
    fn find(&mut self, sha: &Sha) -> Option<u64> {
        let record = index::get(&self.bucket, &pack::hex(sha)).ok()??;
        if record.len() < 17 || &record[17..] != self.id.as_bytes() { return None; }
        Some(u64::from_be_bytes(record[..8].try_into().ok()?))
    }
}

/// Object locations are indexed on disk; only recent range windows live here.
struct Objects {
    key: String,
    sources: Vec<FilePack>,
    reading: BTreeSet<Sha>,
}

impl Objects {
    fn load(key: &str, _pushes: &[Push]) -> Self {
        Self { key: key.into(), sources: Vec::new(), reading: BTreeSet::new() }
    }

    fn read(&mut self, sha: &Sha) -> Option<(u8, Vec<u8>)> {
        if !self.reading.insert(*sha) { return None; }
        let result = self.read_inner(sha);
        self.reading.remove(sha);
        result
    }

    fn read_inner(&mut self, sha: &Sha) -> Option<(u8, Vec<u8>)> {
        let record = index::get(&format!("objects/{}", self.key), &pack::hex(sha)).ok()??;
        if record.len() < 17 { return None; }
        let offset = u64::from_be_bytes(record[..8].try_into().ok()?);
        let size = u64::from_be_bytes(record[8..16].try_into().ok()?);
        let id = std::str::from_utf8(&record[17..]).ok()?;
        let mut source = if let Some(i) = self.sources.iter().position(|p| p.id == id) {
            let source = self.sources.remove(i);
            self.sources.push(source.clone());
            source
        } else {
            let source = FilePack::new(id, size, &self.key);
            if self.sources.len() >= 4 { self.sources.remove(0); }
            self.sources.push(source.clone());
            source
        };
        pack::read_at(&mut source, offset, &HashMap::new(), self).ok()
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
    fn peel(&mut self, sha: Sha) -> Sha { pack::peel(sha, self) }

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
    Settings,
}

struct CommitPage {
    key: String,
    tip: Option<Sha>,
    pending: Vec<Sha>,
    seen: BTreeSet<Sha>,
    rows: Vec<Value>,
}

#[derive(Default)]
struct Git {
    me: String,
    repos: BTreeMap<String, Repo>,
    pushes: HashMap<String, Vec<Push>>,
    push_positions: HashMap<String, HashMap<String, usize>>,
    ref_cache: HashMap<String, RefState>,
    status_cache: HashMap<String, [usize; 3]>,
    objects: Option<Objects>,
    /// Pushes to index, in order, and the one being indexed.
    queue: VecDeque<(String, String)>,
    /// Pushes whose packs were not here, to ask for again.
    retry: Vec<(String, String)>,
    indexing: Option<(String, String, pack::Indexer)>,
    index_waiting: bool,
    progress_at: u64,
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
    pushes_shown: usize,
    branch_filter: String,
    branch_offset: usize,
    delete_name: String,
    clone_open: bool,
    branches_open: bool,
    diff_shown: usize,
    commit_page: Option<CommitPage>,
    draft_name: String,
    draft_description: String,
    error: String,
}

impl Git {
    fn load_pushes(&mut self, key: &str) -> &mut Vec<Push> {
        if !self.pushes.contains_key(key) {
            let mut list: Vec<Push> = store::keys(&format!("push/{key}/")).iter().filter_map(|k| store::get_json(k)).collect();
            list.sort_by(|a, b| (a.created, &a.id).cmp(&(b.created, &b.id)));
            self.push_positions.insert(key.into(), list.iter().enumerate().map(|(i, p)| (p.id.clone(), i)).collect());
            self.pushes.insert(key.to_string(), list);
        }
        self.pushes.get_mut(key).unwrap()
    }

    fn reindex_positions(&mut self, key: &str) {
        let positions = self.pushes[key].iter().enumerate().map(|(i, p)| (p.id.clone(), i)).collect();
        self.push_positions.insert(key.into(), positions);
    }

    fn push_position(&mut self, key: &str, id: &str) -> Option<usize> {
        self.load_pushes(key);
        self.push_positions.get(key)?.get(id).copied()
    }

    fn save_push(&self, key: &str, id: &str) {
        if let Some(p) = self.push_positions.get(key).and_then(|m| m.get(id)).and_then(|i| self.pushes.get(key)?.get(*i)) {
            let _ = store::set_json(&format!("push/{key}/{id}"), p);
        }
    }

    fn save_pushes(&self, key: &str) {
        if let Some(list) = self.pushes.get(key) {
            for p in list { self.save_push(key, &p.id); }
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
        if o.kind == DELETE {
            let repo = self.repo_for(&o.space, &name, &o.author, o.created);
            if !repo.delete_before(o.created) { return None; }
            let _ = index::clear(&format!("objects/{key}"));
            self.ref_cache.remove(&key);
            self.status_cache.remove(&key);
            self.load_pushes(&key).retain(|p| {
                if p.created > o.created { return true; }
                store::remove(&format!("push/{key}/{}", p.id));
                store::remove(&format!("idx/{}", p.id));
                false
            });
            self.reindex_positions(&key);
            self.queue.retain(|(k, _)| k != &key);
            self.retry.retain(|(k, _)| k != &key);
            if self.indexing.as_ref().is_some_and(|(k, _, _)| k == &key) {
                self.indexing = None;
                store::remove("indexing");
            }
            self.index_waiting = false;
            self.objects = None;
            let retained: Vec<String> = self.load_pushes(&key).iter_mut().map(|p| { p.indexed=0; p.error.clear(); p.id.clone() }).collect();
            for id in retained { self.queue.push_back((key.clone(), id)); }
            self.save_pushes(&key);
            self.save_repos();
            return Some(key);
        }
        if self.repos.get(&key).is_some_and(|r| o.created <= r.deleted_at) {
            return None;
        }
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
                if o.created >= repo.metadata_at {
                    repo.metadata_at = o.created;
                    repo.metadata_owner = o.author.clone();
                }
                if repo.deleted_at > 0 && repo.created <= repo.deleted_at {
                    repo.created = o.created;
                    repo.owner = o.author.clone();
                }
                repo.deleted = false;
                self.save_repos();
            }
            PUSH => {
                let repo = self.repo_for(&o.space, &name, &o.author, o.created);
                repo.updated = repo.updated.max(o.created);
                let text_map = |v: &Value| -> BTreeMap<String, String> {
                    v.as_object()
                        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string())).collect())
                        .unwrap_or_default()
                };
                // Before format 2 a pack came in `parts`: not readable now.
                if p["parts"].as_array().is_some_and(|a| !a.is_empty()) {
                    return None;
                }
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
                    pack: p.get("chunks").is_some(),
                    indexed: 0,
                    error: String::new(),
                };
                self.load_pushes(&key);
                if self.push_positions[&key].contains_key(&push.id) { return None; }
                let list = self.pushes.get_mut(&key).unwrap();
                let appended = list.last().is_none_or(|p| (p.created, &p.id) < (push.created, &push.id));
                let incoming = push.clone();
                if appended {
                    let position = list.len();
                    list.push(push);
                    self.push_positions.get_mut(&key).unwrap().insert(o.id.clone(), position);
                } else {
                    let position = list.partition_point(|p| (p.created, &p.id) < (push.created, &push.id));
                    list.insert(position, push);
                    self.reindex_positions(&key);
                }
                if let Some(counts) = self.status_cache.get_mut(&key) {
                    for (total, n) in counts.iter_mut().zip(incoming.counts()) { *total += n; }
                }
                if appended {
                    if let Some(state) = self.ref_cache.get_mut(&key) { state.apply(&incoming); }
                } else {
                    self.ref_cache.remove(&key);
                }
                self.save_push(&key, &o.id);
                self.save_repos();
                self.queue.push_back((key.clone(), o.id.clone()));
            }
            _ => return None,
        }
        Some(key)
    }

    /// The refs as the pushes left them (see [ref_state]).
    fn refs(&mut self, key: &str) -> BTreeMap<String, String> {
        self.ref_state_cached(key).refs.clone()
    }

    fn status(&mut self, key: &str) -> [usize; 3] {
        if let Some(counts) = self.status_cache.get(key) { return *counts; }
        let mut counts = [0; 3];
        for p in self.load_pushes(key) {
            for (total, n) in counts.iter_mut().zip(p.counts()) { *total += n; }
        }
        self.status_cache.insert(key.into(), counts);
        counts
    }

    fn update_status(&mut self, key: &str, before: [usize; 3], after: [usize; 3]) {
        if let Some(counts) = self.status_cache.get_mut(key) {
            for i in 0..3 { counts[i] = counts[i] - before[i] + after[i]; }
        }
    }

    fn ref_state_cached(&mut self, key: &str) -> &RefState {
        if !self.ref_cache.contains_key(key) {
            let mut state = RefState::default();
            for p in self.load_pushes(key) { state.apply(p); }
            self.ref_cache.insert(key.into(), state);
        }
        &self.ref_cache[key]
    }

    fn head(&mut self, key: &str, refs: &BTreeMap<String, String>) -> Option<String> {
        let named = self.ref_state_cached(key).head.clone();
        named
            .filter(|h| refs.contains_key(h))
            .or_else(|| ["refs/heads/main", "refs/heads/master"].iter().find(|h| refs.contains_key(**h)).map(|h| h.to_string()))
            .or_else(|| refs.keys().find(|r| r.starts_with("refs/heads/")).cloned())
            .or_else(|| refs.keys().next().cloned())
    }

    // Indexing ------------------------------------------------------------

    fn schedule(&self) {
        if !self.index_waiting && (self.indexing.is_some() || !self.queue.is_empty()) {
            ournet_plugin::timer::set(INDEX_TIMER, 10);
        }
    }

    fn index_step(&mut self) {
        let tick_end = ournet_plugin::now() + STEP_MS;
        if self.indexing.is_none() {
            while let Some((key, id)) = self.queue.pop_front() {
                if ournet_plugin::now() >= tick_end { self.queue.push_front((key, id)); break; }
                let Some(position) = self.push_position(&key, &id) else { continue };
                let push = self.pushes[&key][position].clone();
                if push.complete() {
                    continue;
                }
                if !push.pack {
                    self.finish(&key, &id, Ok(Vec::new()));
                    continue;
                }
                let source = FilePack::new(&id, push.size, &key);
                let _ = store::set("indexing", id.as_bytes());
                match pack::Indexer::from_source(Box::new(source)) {
                    Ok(ix) => {
                        let checkpoint = store::get_json(&format!("checkpoint/{id}")).unwrap_or((12u64, 0u32, false));
                        self.indexing = Some((key, id, ix.resume(checkpoint)));
                        break;
                    }
                    Err(e) if transient(&e) => self.waiting(&key, &id, e),
                    Err(e) => self.finish(&key, &id, Err(e)),
                }
            }
        }
        let Some((key, id, mut ix)) = self.indexing.take() else { self.schedule(); return };
        if self.objects.as_ref().map(|o| o.key != key).unwrap_or(true) {
            self.objects = Some(Objects::load(&key, &[]));
        }
        let until = ournet_plugin::now() + STEP_MS;
        let result = ix.step(&mut Earlier(&mut self.objects), || ournet_plugin::now() < until);
        if self.repo.as_deref() == Some(&key) && ournet_plugin::now().saturating_sub(self.progress_at) >= 200 {
            self.progress_at = ournet_plugin::now();
            ui::update(SURFACE, &json!({"indexProgress": ix.progress()}));
        }
        let entries = ix.take_entries();
        let size = self.pushes[&key][self.push_positions[&key][&id]].size;
        let values: Vec<(String, Vec<u8>)> = entries.iter().map(|e| {
            let mut value = e.offset.to_be_bytes().to_vec();
            value.extend_from_slice(&size.to_be_bytes());
            value.push(e.kind);
            value.extend_from_slice(id.as_bytes());
            (pack::hex(&e.sha), value)
        }).collect();
        let stored = if values.is_empty() { Ok(()) } else { index::put(&format!("objects/{key}"), &values) };
        if let Err(error) = stored {
            self.finish(&key, &id, Err(error));
        } else {
            let _ = store::set_json(&format!("checkpoint/{id}"), &ix.checkpoint());
            match result {
                Ok(true) => self.finish(&key, &id, Ok(Vec::new())),
                Ok(false) => self.indexing = Some((key, id, ix)),
                Err(error) if transient(&error) => {
                    self.waiting(&key, &id, error);
                    self.index_waiting = true;
                    self.indexing = Some((key, id, ix));
                },
                Err(error) => self.finish(&key, &id, Err(error)),
            }
        }
        self.schedule();
    }

    /// Starts storage again in this version's format: forgets what an
    /// earlier one kept and reads every repository and push back from the
    /// host, which sends each object only once.
    fn rebuild(&mut self) {
        // Object entries are derived and isolated from signed history.
        // Existing repository buckets are cleared once when migrating formats.
        let known: BTreeMap<String, Repo> = store::get_json("repos").unwrap_or_default();
        for key in known.keys() { let _ = index::clear(&format!("objects/{key}")); }
        for key in store::keys("") {
            store::remove(&key);
        }
        let mut found = Vec::new();
        for kind in [REPO, PUSH, DELETE] {
            let mut before: Option<Object> = None;
            loop {
                let page = ournet_plugin::query(kind, None, before.as_ref(), 500);
                let done = page.len() < 500;
                before = page.last().cloned();
                found.extend(page);
                if done {
                    break;
                }
            }
        }
        found.sort_by(|a, b| (a.created, &a.id).cmp(&(b.created, &b.id)));
        for o in &found {
            self.take(o);
        }
        // `init` queues what is unread from storage.
        self.queue.clear();
        self.pushes.clear();
        let _ = store::set("format", FORMAT);
    }

    /// [id]'s pack could not be fetched: says why, and tries again later.
    fn waiting(&mut self, key: &str, id: &str, why: String) {
        if let Some(position) = self.push_position(key, id) {
            let p = &mut self.pushes.get_mut(key).unwrap()[position];
            let before = p.counts();
            p.error = why;
            let after = p.counts();
            self.update_status(key, before, after);
        }
        self.save_push(key, id);
        if !self.retry.iter().any(|(k, i)| k == key && i == id) {
            self.retry.push((key.to_string(), id.to_string()));
        }
        ournet_plugin::timer::set(RETRY_TIMER, RETRY_MS);
        if self.repo.as_deref() == Some(key) {
            self.show();
        }
    }

    fn finish(&mut self, key: &str, id: &str, result: Result<Vec<pack::Entry>, String>) {
        let outcome = match result {
            Ok(_) => Ok(()),
            Err(e) => Err(e),
        };
        if let Some(position) = self.push_position(key, id) {
            let p = &mut self.pushes.get_mut(key).unwrap()[position];
            let before = p.counts();
            match outcome {
                Ok(()) => {
                    p.indexed = 1;
                    p.error.clear();
                }
                Err(e) => {
                    ournet_plugin::warn(&format!("could not read push {id}: {e}"));
                    p.indexed = 2;
                    p.error = e;
                }
            }
            let after = p.counts();
            self.update_status(key, before, after);
        }
        self.save_push(key, id);
        store::remove("indexing");
        store::remove(&format!("checkpoint/{id}"));
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
        if self.repos.get(first).is_some_and(|r| !r.deleted) {
            return Ok(first.to_string());
        }
        let name = address.rsplit('/').next().unwrap_or("");
        let found: Vec<&Repo> = self.repos.values().filter(|r| !r.deleted && r.name == name).collect();
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
                .filter(|r| !r.deleted)
                .map(|r| json!({"url": format!("ournet://{}/{}", r.key, r.name), "where": r.place}))
                .collect();
            return Ok((json!({"repos": list}), Vec::new()));
        }
        let key = self.resolve(request["repo"].as_str().unwrap_or(""))?;
        match op {
            "blob" => {
                let commit = request["commit"].as_str().and_then(pack::unhex).ok_or("invalid commit")?;
                let path = repository_path(request["path"].as_str().unwrap_or(""))?;
                let (name, parents) = path.split_last().ok_or("no file path")?;
                let objects = self.open_objects(&key);
                let commit = objects.peel(commit);
                let mut tree = objects.commit(&commit).and_then(|c| c.tree).ok_or("commit not available yet")?;
                for parent in parents {
                    tree = objects.tree(&tree).into_iter().find(|e| e.name == *parent && e.is_dir())
                        .ok_or("folder not available yet")?.sha;
                }
                let entry = objects.tree(&tree).into_iter().find(|e| e.name == *name && !e.is_dir() && !e.is_submodule())
                    .ok_or("file not available yet")?;
                let (_, bytes) = objects.read(&entry.sha).ok_or("image preview unavailable; clone to open the original")?;
                Ok((json!({"size": bytes.len()}), bytes))
            }
            "list" => {
                let refs = self.refs(&key);
                let head = self.head(&key, &refs);
                let waiting = self.load_pushes(&key).iter().filter(|p| p.fetching()).count();
                Ok((json!({"refs": refs, "head": head, "waiting": waiting}), Vec::new()))
            }
            "packs" => {
                // Every pack, read here or not: `pack` fetches one not here.
                let pushes = self.load_pushes(&key);
                let packs: Vec<Value> = pushes
                    .iter()
                    .filter(|p| p.pack)
                    .map(|p| {
                        json!({
                            "id": p.id,
                            "tips": p.refs.values().filter(|s| !s.is_empty()).collect::<Vec<_>>(),
                            "size": p.size,
                        })
                    })
                    .collect();
                let waiting = pushes.iter().filter(|p| p.fetching()).count();
                Ok((json!({"packs": packs, "waiting": waiting}), Vec::new()))
            }
            "pack" => {
                let id = request["id"].as_str().unwrap_or("");
                let push = self.load_pushes(&key).iter().find(|p| p.id == id).cloned().ok_or("no such push")?;
                if !push.pack {
                    return Err("that push carries no pack".into());
                }
                Ok((json!({}), load_pack(&push.id)?))
            }
            "push-file" => self.receive(&key, request, &[]).map(|id| (json!({"id": id}), Vec::new())),
            "push" => self.receive(&key, request, body).map(|id| (json!({"id": id}), Vec::new())),
            _ => Err(format!("unknown request {op}")),
        }
    }

    /// Publishes a push from local git: the refs it moves, with its pack.
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
        if refs.is_empty() {
            return Err("nothing to push".into());
        }
        for (r, sha) in &refs {
            if !valid_ref(r) || !(sha.is_empty() || pack::unhex(sha).is_some()) {
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
        let file = request["file"].as_str().filter(|_| request["op"] == "push-file");
        let objects = if file.is_some() {
            request["objects"].as_u64().and_then(|n| u32::try_from(n).ok()).ok_or("missing pack object count")?
        } else if pack_bytes.is_empty() { 0 } else { pack::check(pack_bytes)? };
        if pack_bytes.len() > MAX_PACK {
            return Err(format!("too large to push here ({} MB at most)", MAX_PACK / 1024 / 1024));
        }
        let to = match repo.place {
            Where::Personal => Audience::Personal,
            Where::Group => Audience::Group,
            Where::Public => Audience::Public,
        };
        let mut payload = json!({
            "repo": repo.name,
            "refs": refs,
            "old": old,
            "size": if file.is_some() { request["size"].as_u64().ok_or("missing pack size")? } else if objects > 0 { pack_bytes.len() as u64 } else { 0 },
            "objects": objects,
        });
        if force {
            payload["force"] = true.into();
        }
        if let Some(head) = request["head"].as_str().filter(|h| h.starts_with("refs/heads/")) {
            payload["head"] = head.into();
        }
        if let Some(file) = file {
            return files::publish(PUSH, &repo.space, to, &payload, file);
        }
        if objects == 0 {
            return ournet_plugin::publish(PUSH, &repo.space, to, &payload);
        }
        // The pack is the push's file; the file's `size` is the pack's.
        let file = files::store("pack", pack_bytes)?;
        files::publish(PUSH, &repo.space, to, &payload, &file)
    }

    // The page ------------------------------------------------------------

    fn open_objects(&mut self, key: &str) -> &mut Objects {
        if self.objects.as_ref().map(|o| o.key != key).unwrap_or(true) {
            self.objects = Some(Objects::load(key, &[]));
        }
        self.objects.as_mut().unwrap()
    }

    fn show(&mut self) {
        let progress = self.indexing.as_ref().filter(|(key,_,_)| self.repo.as_ref() == Some(key)).map(|(_,_,ix)| ix.progress()).unwrap_or_default();
        let mut data = json!({
            "indexProgress": progress,
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
            .filter(|r| !r.deleted)
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
        if repo.deleted {
            self.mode = Mode::List;
            self.repo = None;
            data["mode"] = "list".into();
            self.show_list(data);
            return;
        }
        data["error"] = self.error.clone().into();
        data["deleteName"] = self.delete_name.clone().into();
        data["cloneOpen"] = self.clone_open.into();
        data["branchesOpen"] = self.branches_open.into();
        data["branchFilter"] = self.branch_filter.clone().into();
        let refs = self.refs(&key);
        let head = self.head(&key, &refs);
        let branch = self.branch.clone().filter(|b| refs.contains_key(b)).or(head);
        self.branch = branch.clone();
        let [waiting, unread, failed] = self.status(&key);
        let mut notice = Vec::new();
        for (side, (base, _)) in self.ref_state_cached(&key).conflicts.clone() {
            let short = |r: &str| r.trim_start_matches("refs/heads/").replace("refs/tags/", "tag ");
            notice.push(format!(
                "{} was pushed from two places at once: the later push is kept as {}. Fetch, merge it and push again.",
                short(&base),
                short(&side)
            ));
        }
        if waiting > 0 {
            notice.push(format!("Waiting for {waiting} pushes' changes from friends."));
        }
        if unread > 0 {
            notice.push("Reading the newest pushes…".to_string());
        }
        if failed > 0 {
            notice.push(format!("{failed} {} could not be read here; Activity shows the error. Git can still fetch the original packs.", if failed == 1 { "push" } else { "pushes" }));
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
            Tab::Settings => "settings",
        }
        .into();
        let filter = self.branch_filter.to_lowercase();
        let mut branches: Vec<Value> = if self.branches_open {
            refs.keys().filter(|r| r.starts_with("refs/heads/") || r.starts_with("refs/tags/"))
                .filter(|r| filter.is_empty() || r.to_lowercase().contains(&filter))
                .skip(self.branch_offset).take(51)
                .map(|r| json!({"ref": r, "name": r.trim_start_matches("refs/heads/").replace("refs/tags/", "tag "), "selected": Some(r) == branch.as_ref()})).collect()
        } else { Vec::new() };
        let more_branches = branches.len() > 50;
        branches.truncate(50);
        data["branches"] = branches.into();
        data["moreBranches"] = more_branches.into();
        data["previousBranches"] = (self.branch_offset > 0).into();
        data["refCount"] = refs.len().into();
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
                Tab::Pushes => self.show_pushes(data, &key),
                Tab::Settings => {},
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

    /// Offers the script plugin at the top of the selected branch or tag
    /// for this person to install: the app asks them, saying where it
    /// came from.
    fn install(&mut self) {
        let Some(key) = self.repo.clone() else { return };
        let refs = self.refs(&key);
        let Some(branch) = self.branch.clone() else { return };
        let Some(tip) = refs.get(&branch).and_then(|s| pack::unhex(s)) else { return };
        let mut files = Vec::new();
        let result = self.package_files(tip, &[], &mut files);
        let commit = {
            let objects = self.open_objects(&key);
            pack::hex(&objects.peel(tip))
        };
        let pushes = self.load_pushes(&key).clone();
        // Who moved the ref there: the person answerable for this code.
        let pusher = pushes
            .iter()
            .rev()
            .find(|p| p.refs.get(&branch) == refs.get(&branch))
            .map(|p| p.author.clone())
            .unwrap_or_default();
        let Some(repo) = self.repos.get(&key) else { return };
        let source = json!({"git": {
            "repo": repo.name,
            "url": format!("ournet://{}/{}", repo.key, repo.name),
            "ref": branch,
            "commit": commit,
            "pusher": pusher,
        }});
        let offered = result.and_then(|()| ournet_plugin::offer_plugin(&files, &source));
        if let Err(e) = offered {
            ui::notify("Not offered", &e);
        }
    }

    /// The package entries under [path] at [commit]: the manifest and UI at
    /// the top, and everything under `scripts/` and `assets/`.
    fn package_files(
        &mut self,
        commit: Sha,
        path: &[String],
        files: &mut Vec<(String, Vec<u8>)>,
    ) -> Result<(), String> {
        let key = self.repo.clone().ok_or("no repository")?;
        let entries = self
            .tree_at(commit, path)
            .ok_or("Its files have not all arrived here yet")?;
        for e in entries {
            let mut name = path.to_vec();
            name.push(e.name.clone());
            let wanted = match path.first().map(String::as_str) {
                None => matches!(e.name.as_str(), "manifest.json" | "ui.rfwtxt" | "scripts" | "assets"),
                Some(_) => true,
            };
            if !wanted || e.is_submodule() {
                continue;
            }
            if e.is_dir() {
                if name.len() > 6 {
                    return Err("Its folders go too deep".into());
                }
                self.package_files(commit, &name, files)?;
            } else {
                let objects = self.open_objects(&key);
                let (_, bytes) = objects.read(&e.sha).ok_or("Its files have not all arrived here yet")?;
                files.push((name.join("/"), bytes));
            }
        }
        Ok(())
    }

    fn crumbs(&self, data: &mut Value) {
        let mut crumbs = vec![json!({"name": data["repo"]["name"].clone(), "depth": 0})];
        for (i, part) in self.path.iter().enumerate() {
            crumbs.push(json!({"name": part, "depth": i + 1}));
        }
        data["crumbs"] = crumbs.into();
    }

    fn show_code(&mut self, data: &mut Value, tip: Option<Sha>) {
        let tip = self.commit.as_deref().and_then(pack::unhex).or(tip);
        self.crumbs(data);
        data["markdownDirectory"] = self.path.join("/").into();
        data["markdownCommit"] = tip.map(|s| pack::hex(&s)).unwrap_or_default().into();
        data["hasLast"] = false.into();
        data["plugin"] = "".into();
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
        let at_top = self.path.is_empty();
        let objects = self.open_objects(&key);
        let readme = entries
            .iter()
            .find(|e| !e.is_dir() && ["readme.md", "readme", "readme.txt"].contains(&e.name.to_lowercase().as_str()))
            .and_then(|e| objects.read(&e.sha))
            .map(|(_, d)| text_of(&d, 100_000).0)
            .unwrap_or_default();
        data["readme"] = readme.into();
        // A script plugin at the top of the tree can be installed from here.
        if at_top {
            let manifest = entries
                .iter()
                .find(|e| e.name == "manifest.json" && !e.is_dir())
                .and_then(|e| objects.read(&e.sha))
                .and_then(|(_, d)| ournet_plugin::serde_json::from_slice::<Value>(&d).ok());
            if let Some(m) = manifest.filter(|m| m["runtime"].is_string()) {
                data["plugin"] = format!(
                    "{} {}, a script plugin",
                    m["name"].as_str().unwrap_or("This"),
                    m["version"].as_str().unwrap_or("")
                )
                .into();
            }
        }
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
        let mut page = self.commit_page.take().filter(|p| p.key == key && p.tip == tip)
            .unwrap_or_else(|| CommitPage { key: key.clone(), tip, pending: tip.into_iter().collect(), seen: BTreeSet::new(), rows: Vec::new() });
        let objects = self.open_objects(&key);
        while page.rows.len() < shown {
            let Some(sha) = page.pending.pop() else { break };
            let sha = objects.peel(sha);
            if !page.seen.insert(sha) { continue; }
            let Some(c) = objects.commit(&sha) else {
                page.seen.remove(&sha);
                page.pending.push(sha);
                break;
            };
            page.rows.push(json!({
                "sha": pack::hex(&sha),
                "short": &pack::hex(&sha)[..7],
                "title": c.title(),
                "author": c.author.name,
                "at": c.committer.time * 1000,
            }));
            page.pending.extend(c.parents.iter().rev().copied());
        }
        while page.pending.last().is_some_and(|sha| page.seen.contains(sha)) { page.pending.pop(); }
        data["commits"] = page.rows.clone().into();
        data["more"] = (!page.pending.is_empty()).into();
        self.commit_page = Some(page);
    }

    fn show_pushes(&mut self, data: &mut Value, key: &str) {
        let shown = self.pushes_shown;
        let pushes = self.load_pushes(key);
        let more = pushes.len() > shown;
        let list: Vec<Value> = pushes
            .iter()
            .rev()
            .take(shown)
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
                let state = if p.fetching() {
                    " · waiting for its changes from friends".to_string()
                } else if !p.complete() {
                    " · reading".to_string()
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
        data["morePushes"] = more.into();
        data["pushes"] = list.into();
    }

    fn show_file(&mut self, data: &mut Value, tip: Option<Sha>) {
        self.crumbs(data);
        let name = self.file.clone().unwrap_or_default();
        let at = match &self.commit {
            Some(c) => pack::unhex(c),
            None => tip,
        };
        data["markdownDirectory"] = self.path.join("/").into();
        data["markdownCommit"] = at.map(|s| pack::hex(&s)).unwrap_or_default().into();
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
            None => (String::new(), "Preview unavailable here; clone the repository to open this object.".to_string()),
        };
        data["file"] = json!({"name": name, "text": text, "note": note,
            "markdown": is_markdown(&name)});
    }

    fn show_commit(&mut self, data: &mut Value) {
        let key = self.repo.clone().unwrap();
        let Some(sha) = self.commit.as_deref().and_then(pack::unhex) else { return };
        let limit = self.diff_shown.max(1500);
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
        let truncated = diff_trees(&mut |sha| objects.tree(sha), parent_tree, c.tree, "", limit + 1, &mut changes);
        let mut lines: Vec<Value> = Vec::new();
        let mut files: Vec<Value> = Vec::new();
        let mut more = truncated;
        for (path, status, a, b) in &changes {
            if lines.len() >= limit { more = true; break; }
            files.push(json!({"path": path, "status": status}));
            let (mut old_line, mut new_line) = (0usize, 0usize);
            let mut add = |lines: &mut Vec<Value>, kind: char, text: String| {
                if kind == '@' {
                    let positions: Vec<usize> = text.split_whitespace().skip(1).take(2)
                        .map(|s| s.trim_start_matches(['-', '+']).split(',').next().unwrap_or("0").parse().unwrap_or(0)).collect();
                    if positions.len() == 2 { old_line = positions[0]; new_line = positions[1]; }
                }
                let numbered = matches!(kind, ' ' | '+' | '-') && (old_line > 0 || new_line > 0);
                let old = if numbered && kind != '+' { let n = old_line.to_string(); old_line += 1; n } else { String::new() };
                let new = if numbered && kind != '-' { let n = new_line.to_string(); new_line += 1; n } else { String::new() };
                let bg: u32 = match kind {
                    '+' => 0x3328A745,
                    '-' => 0x33D73A49,
                    '@' => 0x220366D6,
                    'f' => 0x22808080,
                    _ => 0x00000000,
                };
                let prefix = if kind == '@' || kind == 'f' { String::new() } else { kind.to_string() };
                lines.push(json!({"text": format!("{prefix}{text}"), "bg": bg as i64, "oldLine": old, "newLine": new}));
            };
            add(&mut lines, 'f', format!("{status} {path}"));
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
                        let remaining = limit.saturating_sub(lines.len());
                        more |= hunks.len() > remaining;
                        for (k, l) in hunks.into_iter().take(remaining) {
                            add(&mut lines, k, l);
                        }
                    }
                    None => add(&mut lines, ' ', "Too large to compare here.".into()),
                },
                (Some(_), Some(_)) => add(&mut lines, ' ', "Binary or large file.".into()),
                _ => add(&mut lines, ' ', "Not here yet.".into()),
            }
        }
        data["moreDiff"] = more.into();
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
        self.pushes_shown = 30;
        self.branch_filter.clear();
        self.branch_offset = 0;
        self.delete_name.clear();
        self.clone_open = false;
        self.branches_open = false;
        self.diff_shown = 1500;
        self.error.clear();
        self.show();
    }

    fn repair_repo(&mut self) {
        let Some(key) = self.repo.clone() else { return };
        if let Err(e) = index::clear(&format!("objects/{key}")) { self.error = e; return self.show(); }
        self.index_waiting = false;
        self.status_cache.remove(&key);
        self.commit_page = None;
        self.queue.retain(|(k, _)| k != &key);
        self.retry.retain(|(k, _)| k != &key);
        if self.indexing.as_ref().is_some_and(|(k, _, _)| k == &key) {
            self.indexing = None;
            store::remove("indexing");
        }
        let ids: Vec<String> = self.load_pushes(&key).iter_mut().map(|p| {
            p.indexed = 0;
            p.error.clear();
            p.id.clone()
        }).collect();
        for id in ids {
            store::remove(&format!("idx/{id}"));
            store::remove(&format!("checkpoint/{id}"));
            self.queue.push_back((key.clone(), id));
        }
        self.objects = None;
        self.save_pushes(&key);
        self.error = "Rebuilding this repository's local index. You can keep browsing.".into();
        self.schedule();
        self.show();
    }

    fn delete_repo(&mut self) {
        let Some(repo) = self.repo.as_ref().and_then(|k| self.repos.get(k)).cloned() else { return };
        if !Self::may_write(&repo.space, &self.me) { return; }
        if self.delete_name.trim() != repo.name {
            self.error = "Type the repository name to confirm deletion.".into();
            return self.show();
        }
        let to = match repo.place {
            Where::Personal => Audience::Personal,
            Where::Group => Audience::Group,
            Where::Public => Audience::Public,
        };
        match ournet_plugin::publish(DELETE, &repo.space, to, &json!({"repo": repo.name})) {
            Ok(id) => {
                if let Some(o) = ournet_plugin::get(&id) { self.take(&o); }
                self.mode = Mode::List;
                self.repo = None;
                self.error.clear();
            },
            Err(e) => self.error = e,
        }
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
        if self.repos.get(&key).is_some_and(|r| !r.deleted) {
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
                repo.deleted = false;
                repo.updated = ournet_plugin::now();
                repo.metadata_at = repo.updated;
                repo.metadata_owner = me.clone();
                repo.created = repo.updated;
                repo.owner = me;
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

/// The refs as [pushes] (oldest first, by when they were signed) leave
/// them, and the refs that diverged: `(ref, side branch, author)`.
///
/// Pushes made apart (offline, or before the other arrived) can each be
/// built on a tip the other replaced. The first signed keeps the ref; a
/// later push that was not built on the tip it found, and was not forced,
/// goes to `<ref>@<first 8 of its author>` instead, so no commits are
/// lost and its author can fetch, merge and push again (and delete the
/// side branch with `git push ournet :main@…`).
#[derive(Default)]
struct RefState {
    refs: BTreeMap<String, String>,
    conflicts: BTreeMap<String, (String, String)>,
    head: Option<String>,
}

impl RefState {
    fn apply(&mut self, p: &Push) {
        if p.head.is_some() { self.head = p.head.clone(); }
        for (r, sha) in &p.refs {
            let current = self.refs.get(r).map(String::as_str).unwrap_or("");
            let was = p.old.get(r).map(String::as_str).unwrap_or("");
            if p.force || current == was || r.contains('@') {
                if sha.is_empty() {
                    self.refs.remove(r);
                    self.conflicts.remove(r);
                } else {
                    self.refs.insert(r.clone(), sha.clone());
                }
            } else if !sha.is_empty() {
                let side = format!("{r}@{}", &p.author[..8.min(p.author.len())]);
                self.refs.insert(side.clone(), sha.clone());
                self.conflicts.insert(side, (r.clone(), p.author.clone()));
            }
        }
    }
}

#[cfg(test)]
fn ref_state(pushes: &[Push]) -> (BTreeMap<String, String>, Vec<(String, String, String)>) {
    let mut state = RefState::default();
    for p in pushes { state.apply(p); }
    let conflicts = state.conflicts.into_iter().map(|(side, (base, author))| (base, side, author)).collect();
    (state.refs, conflicts)
}

/// Changed files between two trees: path, A/M/D, old and new blob.
fn diff_trees(
    tree: &mut impl FnMut(&Sha) -> Vec<pack::TreeEntry>,
    a: Option<Sha>, b: Option<Sha>, prefix: &str, limit: usize,
    out: &mut Vec<(String, &'static str, Option<Sha>, Option<Sha>)>,
) -> bool {
    enum Task { Tree(Option<Sha>,Option<Sha>,String), File(String,Option<Sha>,Option<Sha>) }
    let mut pending = vec![Task::Tree(a,b,prefix.into())];
    while let Some(task) = pending.pop() {
        if out.len() >= limit { return true; }
        match task {
            Task::File(path, left, right) => {
                let status = match (left,right) { (None,Some(_)) => "Added", (Some(_),None) => "Deleted", _ => "Changed" };
                out.push((path,status,left,right));
            },
            Task::Tree(a,b,prefix) => {
                if a==b { continue; }
                let left: BTreeMap<String,pack::TreeEntry> = a.as_ref().map(&mut *tree).unwrap_or_default().into_iter().map(|e| (e.name.clone(), e)).collect();
                let right: BTreeMap<String,pack::TreeEntry> = b.as_ref().map(&mut *tree).unwrap_or_default().into_iter().map(|e| (e.name.clone(), e)).collect();
                let names: BTreeSet<&str> = left.keys().chain(right.keys()).map(String::as_str).collect();
                for name in names.into_iter().rev() {
                    let l=left.get(name); let r=right.get(name);
                    let path=format!("{prefix}{name}");
                    let dir=|e: Option<&pack::TreeEntry>| e.filter(|e|e.is_dir()).map(|e|e.sha);
                    let file=|e: Option<&pack::TreeEntry>| e.filter(|e| !e.is_dir() && !e.is_submodule()).map(|e|e.sha);
                    let (fl,fr)=(file(l),file(r));
                    if fl!=fr { pending.push(Task::File(path.clone(),fl,fr)); }
                    if dir(l)!=dir(r) { pending.push(Task::Tree(dir(l),dir(r),format!("{path}/"))); }
                }
            }
        }
    }
    false
}

/// Text to show for [bytes], at most [max] of them; true when binary.
fn repository_path(path: &str) -> Result<Vec<String>, String> {
    let mut parts = Vec::new();
    for part in path.split('/') {
        match part {
            "" | "." => {},
            ".." => { if parts.pop().is_none() { return Err("path leaves repository".into()); } },
            p if p.contains('\\') || p.contains('\0') => return Err("invalid repository path".into()),
            p => parts.push(p.to_string()),
        }
    }
    Ok(parts)
}

fn is_markdown(name: &str) -> bool {
    let name = name.to_lowercase();
    name == "readme" || [".md", ".markdown", ".mdown", ".mkdn"].iter().any(|s| name.ends_with(s))
}

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
        let disk_format = index::get("control", "format").ok().flatten();
        if store::get("format").as_deref() != Some(FORMAT) || disk_format.as_deref() != Some(FORMAT) {
            self.rebuild();
            let _ = index::put("control", &[("format".into(), FORMAT.to_vec())]);
        }
        self.repos = store::get_json("repos").unwrap_or_default();
        self.followed = store::get_json("followed").unwrap_or_default();
        // A pack that stopped the plugin mid-read is not read again.
        if let Some(id) = store::get("indexing") {
            let id = String::from_utf8_lossy(&id).to_string();
            for key in self.repos.keys().cloned().collect::<Vec<_>>() {
                if self.load_pushes(&key).iter().any(|p| p.id == id) && store::get(&format!("checkpoint/{id}")).is_none() {
                    self.finish(&key.clone(), &id, Err("indexing stopped before its first checkpoint; rebuild the local index to retry".into()));
                }
            }
            store::remove("indexing");
        }
        for key in self.repos.keys().cloned().collect::<Vec<_>>() {
            for p in self.load_pushes(&key).clone() {
                if !p.complete() {
                    self.queue.push_back((key.clone(), p.id));
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
        // Opened from search or the activity feed: show that repository.
        let opened = context.object.and_then(|id| ournet_plugin::get(&id)).and_then(|o| {
            let p = o.json();
            let name = p["repo"].as_str().or(p["name"].as_str())?.to_string();
            Some(repo_key(&o.space, &name))
        });
        match opened.filter(|key| self.repos.contains_key(key)) {
            Some(key) => self.open_repo(&key),
            None => self.show(),
        }
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
            "branches" => { self.branches_open = !self.branches_open; self.show(); },
            "clone" => { self.clone_open = !self.clone_open; self.show(); },
            "moreDiff" => { self.diff_shown += 1500; self.show(); },
            "deleteName" => self.delete_name = text("value"),
            "delete" => self.delete_repo(),
            "repair" => self.repair_repo(),
            "branchFilter" => { self.branch_filter = text("value"); self.branch_offset = 0; self.show(); },
            "nextBranches" => { self.branch_offset += 50; self.show(); },
            "previousBranches" => { self.branch_offset = self.branch_offset.saturating_sub(50); self.show(); },
            "morePushes" => { self.pushes_shown += 30; self.show(); },
            "open" => self.open_repo(&text("key")),
            "tab" => {
                self.tab = match text("tab").as_str() {
                    "commits" => Tab::Commits,
                    "pushes" => Tab::Pushes,
                    "settings" => Tab::Settings,
                    _ => Tab::Code,
                };
                self.mode = Mode::Repo;
                self.commit = None;
                self.show();
            }
            "branch" => {
                self.branch = Some(text("ref"));
                self.branches_open = false;
                self.branch_filter.clear();
                self.branch_offset = 0;
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
            "markdownLink" => {
                if let Ok(mut path) = repository_path(&text("target")) {
                    self.commit = Some(text("commit"));
                    if let Some(name) = path.pop() {
                        let is_dir = self.commit.as_deref().and_then(pack::unhex)
                            .and_then(|tip| self.tree_at(tip, &path))
                            .and_then(|entries| entries.into_iter().find(|e| e.name == name))
                            .is_some_and(|e| e.is_dir());
                        if is_dir {
                            path.push(name);
                            self.file = None;
                            self.mode = Mode::Repo;
                        } else {
                            self.file = Some(name);
                            self.mode = Mode::File;
                        }
                    } else { self.file = None; self.mode = Mode::Repo; }
                    self.path = path;
                    self.show();
                }
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
                self.diff_shown = 1500;
                self.mode = Mode::Commit;
                self.show();
            }
            "more" => {
                self.commits_shown += 30;
                self.show();
            }
            "install" => self.install(),
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
        if token == RETRY_TIMER {
            self.index_waiting = false;
            self.queue.extend(self.retry.drain(..));
            self.schedule();
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
            self.pushes_shown = 30;
        }
    }
}

ournet_plugin::plugin!(Git);

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deletion_is_monotonic_and_recreation_survives_late_delivery() {
        let mut repo = Repo { metadata_at: 10, updated: 50, ..Default::default() };
        assert!(repo.delete_before(20));
        // A push at 50 cannot resurrect a deleted repository.
        assert!(repo.deleted);
        assert!(!repo.delete_before(19));
        repo.metadata_at = 40;
        repo.deleted = false;
        // An earlier deletion delivered after recreation still retires old data.
        assert!(repo.delete_before(30));
        assert!(!repo.deleted);
        assert_eq!(repo.deleted_at, 30);
    }

    #[test]
    fn incremental_refs_match_replay_and_clear_resolved_conflicts() {
        let pushes = [
            push("alice", 1, "refs/heads/main", "", "one"),
            push("bob", 2, "refs/heads/main", "", "two"),
            push("alice", 3, "refs/heads/main", "one", "three"),
            push("bob", 4, "refs/heads/main@bob", "two", ""),
        ];
        let mut cached = RefState::default();
        for (i, p) in pushes.iter().enumerate() {
            cached.apply(p);
            assert_eq!(cached.refs, ref_state(&pushes[..=i]).0);
        }
        assert!(cached.conflicts.is_empty());
        assert_eq!(cached.refs["refs/heads/main"], "three");
    }

    fn push(author: &str, created: u64, r: &str, old: &str, new: &str) -> Push {
        Push {
            id: format!("{author}{created}"),
            author: author.into(),
            created,
            refs: [(r.to_string(), new.to_string())].into(),
            old: [(r.to_string(), old.to_string())].into(),
            ..Default::default()
        }
    }

    #[test]
    fn pushes_made_apart_keep_both_sides() {
        let main = "refs/heads/main";
        // Both built on a1 while apart; Ada's was signed first.
        let pushes = [
            push("ada00000aaaa", 1, main, "", "a1"),
            push("ada00000aaaa", 2, main, "a1", "a2"),
            push("bob11111bbbb", 3, main, "a1", "b2"),
        ];
        let (refs, conflicts) = ref_state(&pushes);
        assert_eq!(refs[main], "a2");
        assert_eq!(refs["refs/heads/main@bob11111"], "b2");
        assert_eq!(conflicts, [(main.to_string(), "refs/heads/main@bob11111".to_string(), "bob11111bbbb".to_string())]);

        // Bob merges and pushes onto Ada's tip, then drops his side branch.
        let mut more = pushes.to_vec();
        more.push(push("bob11111bbbb", 4, main, "a2", "m"));
        more.push(push("bob11111bbbb", 5, "refs/heads/main@bob11111", "b2", ""));
        let (refs, conflicts) = ref_state(&more);
        assert_eq!(refs.len(), 1);
        assert_eq!(refs[main], "m");
        assert!(conflicts.is_empty());

        // A forced push replaces whatever was there.
        let mut forced = push("bob11111bbbb", 3, main, "a1", "b2");
        forced.force = true;
        let (refs, _) = ref_state(&[pushes[0].clone(), pushes[1].clone(), forced]);
        assert_eq!(refs[main], "b2");
    }

    #[test]
    fn tree_diffs_page_beyond_300_files_and_do_not_recurse_on_the_stack() {
        let root=[1;20];
        let entries: Vec<_>=(0..1000).map(|i|pack::TreeEntry { mode: 0o100644, name: format!("file-{i:04}"), sha: [2;20] }).collect();
        let mut lookup=|_: &Sha| entries.clone();
        let mut changes=Vec::new();
        assert!(diff_trees(&mut lookup,None,Some(root),"",501,&mut changes));
        assert_eq!(changes.len(),501);
        changes.clear();
        assert!(!diff_trees(&mut lookup,None,Some(root),"",1500,&mut changes));
        assert_eq!(changes.len(),1000);
        let mut deep=|sha: &Sha| {
            let depth=u32::from_be_bytes(sha[..4].try_into().unwrap());
            let mut next=[0;20]; next[..4].copy_from_slice(&(depth+1).to_be_bytes());
            vec![pack::TreeEntry { mode: if depth<2000 {0o40000} else {0o100644}, name: "d".into(), sha: next }]
        };
        changes.clear();
        diff_trees(&mut deep,None,Some([0;20]),"",10,&mut changes);
        assert_eq!(changes.len(),1);
    }

    #[test]
    fn git_ref_validation_does_not_impose_a_200_byte_name_limit() {
        assert!(valid_ref(&format!("refs/heads/{}", "branch-".repeat(80))));
        for bad in ["refs/heads/a b", "refs/heads/a\nb", "refs/heads/a.lock", "refs/heads/.hidden", "refs/heads/a..b", "refs/heads/a@{b", "refs/heads/a\\b"] { assert!(!valid_ref(bad), "{bad}"); }
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
