//! A wiki. Every edit is a signed `x.wiki.page` object holding the whole
//! page and the revision it was based on; the newest revision of a title is
//! the page. Where it lives follows the scope it is opened in: personal
//! pages go to this person's devices, a group's to its members, and public
//! ones to a commons any friend following it can read and edit.
//!
//! The host hands every revision over once, so the plugin keeps a small
//! index per space (title → newest revision) in its storage and fetches a
//! page's text only to show it.
//!
//! A page longer than fits in an object keeps its whole text in a file
//! attached to the revision, and the start of it in `body`, which is what
//! versions before 0.2 show. Pictures are `x.wiki.image` objects carrying
//! the picture as their file, shown by a `![caption](id)` line.

use std::collections::BTreeMap;

use ournet_plugin::{files, json, store, ui, Audience, Context, Object, Plugin, Scope, Value};
use serde::{Deserialize, Serialize};

const KIND: &str = "x.wiki.page";
const IMAGE: &str = "x.wiki.image";
/// Bytes of a page kept in `body`; longer pages attach the whole text.
/// Small enough that, escaped as JSON, it stays under the host's 64 KiB
/// for a plugin's payload.
const BODY_BYTES: usize = 24_000;
/// The longest page: what a file may hold.
const PAGE_BYTES: usize = 8 << 20;
const PERSONAL: &str = "x.wiki";
const COMMONS: &str = "x.wiki.commons";
const SURFACE: &str = "Wiki";

/// The newest revision of a page, as the index keeps it.
#[derive(Clone, Serialize, Deserialize)]
struct Rev {
    id: String,
    title: String,
    author: String,
    created: u64,
    #[serde(default)]
    deleted: bool,
    /// Another revision was written from an older one than this replaced:
    /// two people edited at once, and the newest won.
    #[serde(default)]
    forked: bool,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum Mode {
    #[default]
    List,
    Read,
    Edit,
    History,
}

#[derive(Default)]
struct Wiki {
    /// Space → page key (lower-cased title) → newest revision.
    index: BTreeMap<String, BTreeMap<String, Rev>>,
    space: String,
    audience: Where,
    place: String,
    mode: Mode,
    /// The page open, by key, and the revision shown when it is an old one.
    page: Option<String>,
    revision: Option<String>,
    draft_title: String,
    draft_body: String,
    search: String,
}

#[derive(Default, Clone, Copy, PartialEq)]
enum Where {
    #[default]
    Personal,
    Group,
    Public,
}

fn key(title: &str) -> String {
    title.trim().to_lowercase()
}

impl Wiki {
    fn pages(&mut self) -> &mut BTreeMap<String, Rev> {
        self.index.entry(self.space.clone()).or_default()
    }

    /// Takes a revision into the index; true when it changed the page.
    fn take(&mut self, o: &Object) -> bool {
        let p = o.json();
        let Some(title) = p["title"].as_str() else { return false };
        let base = p["base"].as_str().map(String::from);
        let rev = Rev {
            id: o.id.clone(),
            title: title.trim().to_string(),
            author: o.author.clone(),
            created: o.created,
            deleted: p["deleted"].as_bool().unwrap_or(false),
            forked: false,
        };
        let pages = self.index.entry(o.space.clone()).or_default();
        match pages.get_mut(&key(title)) {
            Some(current) if (current.created, &current.id) >= (rev.created, &rev.id) => {
                // An older one arriving late: the newest says whether it forked.
                if base.as_deref() != Some(current.id.as_str()) && current.id != rev.id {
                    current.forked |= rev.created + 60_000 > current.created;
                }
                false
            }
            Some(current) => {
                let forked = base.as_deref() != Some(current.id.as_str());
                *current = Rev { forked, ..rev };
                true
            }
            None => {
                pages.insert(key(title), rev);
                true
            }
        }
    }

    fn save_index(&self, space: &str) {
        if let Some(pages) = self.index.get(space) {
            let _ = store::set_json(&format!("index/{space}"), pages);
        }
    }

    fn load_index(&mut self, space: &str) {
        if !self.index.contains_key(space) {
            let pages = store::get_json(&format!("index/{space}")).unwrap_or_default();
            self.index.insert(space.to_string(), pages);
        }
    }

    /// A revision's text: its attached file when it has one (a long page),
    /// else `body`. A file not here yet shows the start, and says so.
    fn body(id: &str) -> String {
        let Some(o) = ournet_plugin::get(id) else { return String::new() };
        let p = o.json();
        let start = p["body"].as_str().unwrap_or("").to_string();
        if p.get("chunks").is_none() {
            return start;
        }
        match files::read(id) {
            Ok(bytes) => String::from_utf8_lossy(&bytes).into_owned(),
            Err(e) => format!("{start}\n\n*The rest of this page is not here yet ({e}).*"),
        }
    }

    fn to(&self) -> Audience {
        match self.audience {
            Where::Personal => Audience::Personal,
            Where::Group => Audience::Group,
            Where::Public => Audience::Public,
        }
    }

    /// Publishes a picture the person picked, where the page lives, and
    /// adds a line showing it to the draft.
    fn add_picture(&mut self, file: &str, name: &str) {
        match files::publish(IMAGE, &self.space, self.to(), &json!({}), file) {
            Ok(id) => {
                let caption: String = name.chars().filter(|c| !"[]()".contains(*c)).collect();
                if !self.draft_body.is_empty() && !self.draft_body.ends_with('\n') {
                    self.draft_body.push('\n');
                }
                self.draft_body.push_str(&format!("![{caption}]({id})\n"));
            }
            Err(e) => ui::notify("Could not add the picture", &e),
        }
    }

    fn show(&mut self) {
        let mode = self.mode;
        let mut data = json!({
            "mode": match mode {
                Mode::List => "list",
                Mode::Read => "read",
                Mode::Edit => "edit",
                Mode::History => "history",
            },
            "heading": "Wiki",
            "where": self.place,
            "search": self.search,
        });
        match mode {
            Mode::List => {
                let search = self.search.to_lowercase();
                let mut pages: Vec<Rev> = self
                    .pages()
                    .values()
                    .filter(|r| !r.deleted && (search.is_empty() || r.title.to_lowercase().contains(&search)))
                    .cloned()
                    .collect();
                pages.sort_by(|a, b| b.created.cmp(&a.created));
                let empty = pages.is_empty();
                data["pages"] = pages
                    .iter()
                    .map(|r| json!({"title": r.title, "author": r.author, "at": r.created as i64}))
                    .collect::<Vec<_>>()
                    .into();
                data["empty"] = empty.into();
                data["emptyText"] = if search.is_empty() {
                    "No pages yet. Start one with New page; link others with [[Page name]].".into()
                } else {
                    "No page has that in its title.".into()
                };
            }
            Mode::Read | Mode::History => {
                let Some(page) = self.page.clone() else { return };
                let current = self.pages().get(&page).cloned();
                let (id, author, at, title, label, notice) = match (&self.revision, &current) {
                    (Some(rev), _) => {
                        let old = ournet_plugin::get(rev);
                        let title = old
                            .as_ref()
                            .and_then(|o| o.json()["title"].as_str().map(String::from))
                            .unwrap_or_default();
                        let (author, at) = old.map(|o| (o.author, o.created)).unwrap_or_default();
                        (rev.clone(), author, at, title, "Written by ", "An older version: Edit to restore it.")
                    }
                    (None, Some(r)) => (
                        r.id.clone(),
                        r.author.clone(),
                        r.created,
                        r.title.clone(),
                        "Last edited by ",
                        if r.forked {
                            "Two people edited this at once: the newest edit is shown, the other is in History."
                        } else {
                            ""
                        },
                    ),
                    (None, None) => return,
                };
                data["page"] = json!({
                    "title": title,
                    "body": if mode == Mode::Read { Self::body(&id) } else { String::new() },
                    "author": author,
                    "at": at as i64,
                    "label": label,
                    "notice": notice,
                });
                if mode == Mode::History {
                    let revisions: Vec<Value> = self
                        .history(&title)
                        .into_iter()
                        .map(|o| {
                            let p = o.json();
                            let body = p["body"].as_str().unwrap_or("");
                            let summary = if p["deleted"].as_bool() == Some(true) {
                                "Deleted".to_string()
                            } else if let Some(size) = p["size"].as_u64().filter(|_| p.get("chunks").is_some()) {
                                format!("A long page, {} KB", size.div_ceil(1024))
                            } else {
                                format!("{} characters", body.chars().count())
                            };
                            json!({"id": o.id, "author": o.author, "at": o.created as i64, "summary": summary})
                        })
                        .collect();
                    data["history"] = revisions.into();
                }
            }
            Mode::Edit => {
                data["editing"] = if self.page.is_some() { "Editing" } else { "New page" }.into();
                data["draftTitle"] = self.draft_title.clone().into();
                data["draftBody"] = self.draft_body.clone().into();
            }
        }
        ui::update(SURFACE, &data);
    }

    /// Every revision of [title] in the current space, newest first.
    fn history(&self, title: &str) -> Vec<Object> {
        let wanted = key(title);
        let mut found = Vec::new();
        let mut before: Option<Object> = None;
        // Paged: a busy wiki has more revisions than one page of results.
        for _ in 0..20 {
            let page = ournet_plugin::query(KIND, Some(&self.space), before.as_ref(), 200);
            let last = page.last().cloned();
            found.extend(page.into_iter().filter(|o| key(o.json()["title"].as_str().unwrap_or("")) == wanted));
            match last {
                Some(o) if found.len() < 100 => before = Some(o),
                _ => break,
            }
        }
        found
    }

    fn open_page(&mut self, title: &str) {
        let k = key(title);
        self.revision = None;
        if self.pages().get(&k).map_or(true, |r| r.deleted) {
            // A link to a page nobody wrote yet starts it.
            self.page = None;
            self.draft_title = title.trim().to_string();
            self.draft_body = String::new();
            self.mode = Mode::Edit;
        } else {
            self.page = Some(k);
            self.mode = Mode::Read;
        }
        self.show();
    }

    fn save(&mut self) {
        let title = self.draft_title.trim().to_string();
        if title.is_empty() {
            ui::notify("Wiki", "A page needs a title");
            return;
        }
        let base = self
            .page
            .as_ref()
            .and_then(|k| self.index.get(&self.space)?.get(k))
            .map(|r| r.id.clone());
        let text = &self.draft_body;
        if text.len() > PAGE_BYTES {
            ui::notify("Could not save", "A page is at most 8 MB");
            return;
        }
        // A long page keeps its start in `body` and all of it in a file.
        let mut start = text.len().min(BODY_BYTES);
        while !text.is_char_boundary(start) {
            start -= 1;
        }
        let mut payload = json!({"title": title, "body": &text[..start]});
        if let Some(base) = base {
            payload["base"] = base.into();
        }
        let published = if start < text.len() {
            files::store("page.md", text.as_bytes())
                .and_then(|file| files::publish(KIND, &self.space, self.to(), &payload, &file))
        } else {
            ournet_plugin::publish(KIND, &self.space, self.to(), &payload)
        };
        match published {
            Ok(_) => {
                // The index takes it when the host hands it back.
                self.page = Some(key(&title));
                self.revision = None;
                self.mode = Mode::Read;
            }
            Err(e) => ui::notify("Could not save", &e),
        }
    }
}

impl Plugin for Wiki {
    fn init(&mut self) {
        // After a hot reload, `restore` has already said where it was.
        if self.space.is_empty() {
            self.space = PERSONAL.into();
            self.place = "Your own pages".into();
        }
    }

    fn on_objects(&mut self, objects: Vec<Object>) {
        let mut changed = Vec::new();
        for o in &objects {
            self.load_index(&o.space);
            if self.take(o) && !changed.contains(&o.space) {
                changed.push(o.space.clone());
            }
        }
        for space in &changed {
            self.save_index(space);
        }
        if changed.contains(&self.space) && self.mode != Mode::Edit {
            self.show();
        }
    }

    fn on_open(&mut self, _surface: &str, context: Context) {
        let (space, audience, place) = match (context.scope, &context.space) {
            (Scope::Group, Some(space)) => (
                space.clone(),
                Where::Group,
                format!("Shared with {}", context.name.as_deref().unwrap_or("the group")),
            ),
            (Scope::Public, _) => {
                let _ = ournet_plugin::follow(COMMONS, true);
                (COMMONS.to_string(), Where::Public, "The public commons: friends who follow it read and edit it".into())
            }
            _ => (PERSONAL.to_string(), Where::Personal, "Your own pages".to_string()),
        };
        if space != self.space {
            self.mode = Mode::List;
            self.page = None;
            self.revision = None;
        }
        self.space = space;
        self.audience = audience;
        self.place = place;
        let space = self.space.clone();
        self.load_index(&space);
        // Opened from search or the activity feed: show that page.
        let page = context
            .object
            .and_then(|id| ournet_plugin::get(&id))
            .filter(|o| o.kind == KIND && o.space == self.space);
        match page.and_then(|o| o.json()["title"].as_str().map(String::from)) {
            Some(title) => self.open_page(&title),
            None => self.show(),
        }
    }

    fn on_event(&mut self, _surface: &str, name: &str, args: Value) {
        let text = |k: &str| args[k].as_str().unwrap_or("").to_string();
        match name {
            "search" => {
                self.search = text("value");
                self.show();
            }
            "open" => self.open_page(&text("title")),
            "link" => self.open_page(&text("target")),
            "new" => {
                self.page = None;
                self.revision = None;
                self.draft_title.clear();
                self.draft_body.clear();
                self.mode = Mode::Edit;
                self.show();
            }
            "edit" => {
                if let Some(page) = self.page.clone() {
                    let current = self.pages().get(&page).cloned();
                    let id = self.revision.clone().or(current.as_ref().map(|r| r.id.clone()));
                    self.draft_title = current.map(|r| r.title).unwrap_or_default();
                    self.draft_body = id.map(|id| Self::body(&id)).unwrap_or_default();
                    self.mode = Mode::Edit;
                    self.show();
                }
            }
            "title" => self.draft_title = text("value"),
            "body" => self.draft_body = text("value"),
            "save" => {
                self.save();
                self.show();
            }
            "picture" => {
                self.add_picture(&text("file"), &text("name"));
                self.show();
            }
            "cancel" => {
                self.mode = if self.page.is_some() { Mode::Read } else { Mode::List };
                self.show();
            }
            "history" => {
                self.mode = Mode::History;
                self.show();
            }
            "revision" => {
                self.revision = Some(text("id"));
                self.mode = Mode::Read;
                self.show();
            }
            "back" => {
                if self.mode == Mode::History || self.revision.is_some() {
                    self.revision = None;
                    self.mode = Mode::Read;
                } else {
                    self.mode = Mode::List;
                    self.page = None;
                }
                self.show();
            }
            _ => {}
        }
    }

    fn save_state(&mut self) -> Vec<u8> {
        json!({
            "space": self.space, "page": self.page, "mode": self.mode as u8,
            "title": self.draft_title, "body": self.draft_body,
        })
        .to_string()
        .into_bytes()
    }

    fn restore(&mut self, state: Vec<u8>) {
        let v: Value = ournet_plugin::serde_json::from_slice(&state).unwrap_or(Value::Null);
        self.space = v["space"].as_str().unwrap_or(PERSONAL).into();
        self.page = v["page"].as_str().map(String::from);
        self.draft_title = v["title"].as_str().unwrap_or("").into();
        self.draft_body = v["body"].as_str().unwrap_or("").into();
        self.mode = match v["mode"].as_u64() {
            Some(1) => Mode::Read,
            Some(2) => Mode::Edit,
            Some(3) => Mode::History,
            _ => Mode::List,
        };
    }
}

ournet_plugin::plugin!(Wiki);
