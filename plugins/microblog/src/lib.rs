//! Microblogging. A post is a signed `x.microblog.post`; a like is an
//! `x.microblog.like` that a later one of the same person's replaces.
//!
//! In public, each person posts in their own space, `x.microblog.u.<person>`,
//! and following someone is following that space: their posts then reach
//! this device from whichever friends hold them. Friends are followed
//! unless unfollowed. In a group, posts go to the group's space and members.
//!
//! The host hands each object over once, so the plugin keeps recent posts
//! and like tallies in its storage.

use std::collections::{BTreeMap, BTreeSet};

use ournet_plugin::{json, store, ui, Audience, Context, Object, Plugin, Scope, Value};
use serde::{Deserialize, Serialize};

const POST: &str = "x.microblog.post";
const LIKE: &str = "x.microblog.like";
const SURFACE: &str = "Feed";
/// Posts kept per space; older ones are read back with a query when needed.
const KEEP: usize = 400;

#[derive(Clone, Serialize, Deserialize)]
struct Post {
    id: String,
    author: String,
    space: String,
    at: u64,
    text: String,
    #[serde(default)]
    reply: Option<String>,
}

/// Who likes a post: each person's newest like decides.
#[derive(Default, Serialize, Deserialize)]
struct Likes {
    by: BTreeMap<String, (u64, bool)>,
}

impl Likes {
    fn count(&self) -> usize {
        self.by.values().filter(|(_, on)| *on).count()
    }
}

#[derive(Default, Serialize, Deserialize)]
struct Saved {
    posts: BTreeMap<String, Vec<Post>>,
    likes: BTreeMap<String, Likes>,
    /// People this person stopped following.
    unfollowed: BTreeSet<String>,
}

#[derive(Default)]
struct Microblog {
    saved: Saved,
    me: String,
    /// The group's space in group scope; None in public.
    group: Option<String>,
    group_name: String,
    reply_to: Option<String>,
    show_people: bool,
}

fn home(person: &str) -> String {
    format!("x.microblog.u.{person}")
}

impl Microblog {
    fn save(&self) {
        let _ = store::set_json("state", &self.saved);
    }

    /// The spaces the feed shows: the group's, or this person's and
    /// everyone followed.
    fn spaces(&self) -> Vec<String> {
        match &self.group {
            Some(space) => vec![space.clone()],
            None => {
                let mut spaces = vec![home(&self.me)];
                spaces.extend(self.following().iter().map(|p| home(p)));
                spaces
            }
        }
    }

    fn following(&self) -> Vec<String> {
        ournet_plugin::contacts()
            .into_iter()
            .map(|c| c.person)
            .filter(|p| *p != self.me && !self.saved.unfollowed.contains(p))
            .collect()
    }

    /// Follows friends' spaces, so their posts are fetched.
    fn follow_friends(&self) {
        let _ = ournet_plugin::follow(&home(&self.me), true);
        for c in ournet_plugin::contacts() {
            if c.person != self.me {
                let _ = ournet_plugin::follow(&home(&c.person), !self.saved.unfollowed.contains(&c.person));
            }
        }
    }

    fn find(&self, id: &str) -> Option<&Post> {
        self.saved.posts.values().flatten().find(|p| p.id == id)
    }

    fn show(&self) {
        let spaces = self.spaces();
        let mut posts: Vec<&Post> = spaces
            .iter()
            .filter_map(|s| self.saved.posts.get(s))
            .flatten()
            .collect();
        posts.sort_by(|a, b| (b.at, &b.id).cmp(&(a.at, &a.id)));
        posts.truncate(200);
        let replies = |id: &str| -> usize {
            self.saved.posts.values().flatten().filter(|p| p.reply.as_deref() == Some(id)).count()
        };
        let view: Vec<Value> = posts
            .iter()
            .map(|p| {
                let likes = self.saved.likes.get(&p.id);
                let mine = likes.and_then(|l| l.by.get(&self.me)).map_or(false, |(_, on)| *on);
                let count = likes.map_or(0, Likes::count);
                let reply_to = p
                    .reply
                    .as_ref()
                    .map(|r| match self.find(r) {
                        Some(q) => q.text.chars().take(60).collect::<String>(),
                        None => "an earlier post".into(),
                    })
                    .unwrap_or_default();
                let n = replies(&p.id);
                json!({
                    "id": p.id,
                    "author": p.author,
                    "at": p.at as i64,
                    "text": p.text,
                    "replyTo": reply_to,
                    "likes": format!("{} {}", if mine { "♥" } else { "♡" }, if count > 0 { count.to_string() } else { String::new() }),
                    "replies": if n > 0 { format!("Reply · {n}") } else { "Reply".into() },
                })
            })
            .collect();
        let people: Vec<Value> = if self.show_people {
            ournet_plugin::contacts()
                .into_iter()
                .filter(|c| c.person != self.me)
                .map(|c| {
                    let following = !self.saved.unfollowed.contains(&c.person);
                    json!({"id": c.person, "action": if following { "Following" } else { "Follow" }})
                })
                .collect()
        } else {
            Vec::new()
        };
        let replying = self
            .reply_to
            .as_ref()
            .and_then(|id| self.find(id))
            .map(|p| p.text.chars().take(60).collect::<String>())
            .unwrap_or_default();
        ui::update(
            SURFACE,
            &json!({
                "heading": "Microblog",
                "public": self.group.is_none(),
                "where": match &self.group {
                    Some(_) => format!("Posts in {}, for its members", self.group_name),
                    None => "Your posts and the friends you follow, in public".into(),
                },
                "peopleLabel": if self.show_people { "Done" } else { "People" },
                "showPeople": self.show_people,
                "people": people.clone(),
                "noPeople": self.show_people && people.is_empty(),
                "hint": if self.reply_to.is_some() { "Your reply" } else { "What's happening?" },
                "draft": "",
                "replying": replying,
                "empty": view.is_empty(),
                "emptyText": "Nothing yet. Say something, or follow friends under People.",
                "posts": view,
            }),
        );
    }

    fn take(&mut self, o: &Object) -> bool {
        let p = o.json();
        match o.name() {
            "post" => {
                let Some(text) = p["text"].as_str() else { return false };
                let posts = self.saved.posts.entry(o.space.clone()).or_default();
                if posts.iter().any(|q| q.id == o.id) {
                    return false;
                }
                let at = p["sent"].as_u64().filter(|s| *s <= o.created).unwrap_or(o.created);
                posts.push(Post {
                    id: o.id.clone(),
                    author: o.author.clone(),
                    space: o.space.clone(),
                    at,
                    text: text.to_string(),
                    reply: p["reply"].as_str().map(String::from),
                });
                posts.sort_by(|a, b| (b.at, &b.id).cmp(&(a.at, &a.id)));
                posts.truncate(KEEP);
                true
            }
            "like" => {
                let Some(post) = p["post"].as_str() else { return false };
                let on = p["on"].as_bool().unwrap_or(false);
                let likes = self.saved.likes.entry(post.to_string()).or_default();
                match likes.by.get(&o.author) {
                    Some((at, _)) if *at >= o.created => false,
                    _ => {
                        likes.by.insert(o.author.clone(), (o.created, on));
                        true
                    }
                }
            }
            _ => false,
        }
    }

    /// Where a new post or like goes, and to whom.
    fn target(&self) -> (String, Audience) {
        match &self.group {
            Some(space) => (space.clone(), Audience::Group),
            None => (home(&self.me), Audience::Public),
        }
    }
}

impl Plugin for Microblog {
    fn init(&mut self) {
        self.saved = store::get_json("state").unwrap_or_default();
        self.me = ournet_plugin::me();
        self.follow_friends();
    }

    fn on_objects(&mut self, objects: Vec<Object>) {
        let mut changed = false;
        for o in &objects {
            changed |= self.take(o);
        }
        if changed {
            self.save();
            self.show();
        }
    }

    fn on_open(&mut self, _surface: &str, context: Context) {
        match (context.scope, context.space) {
            (Scope::Group, Some(space)) => {
                self.group = Some(space);
                self.group_name = context.name.unwrap_or_else(|| "the group".into());
            }
            _ => {
                self.group = None;
                // Friends added since last time are followed too.
                self.follow_friends();
            }
        }
        self.reply_to = None;
        self.show();
    }

    fn on_event(&mut self, _surface: &str, name: &str, args: Value) {
        let text = |k: &str| args[k].as_str().unwrap_or("").to_string();
        match name {
            "post" => {
                let body = text("value").trim().to_string();
                if body.is_empty() {
                    return;
                }
                let (space, to) = self.target();
                let mut payload = json!({"text": body, "sent": ournet_plugin::now()});
                if let Some(reply) = self.reply_to.take() {
                    payload["reply"] = reply.into();
                }
                if let Err(e) = ournet_plugin::publish(POST, &space, to, &payload) {
                    ui::notify("Not posted", &e);
                }
                self.show();
            }
            "like" => {
                let id = text("id");
                let Some(post) = self.find(&id) else { return };
                let space = post.space.clone();
                let liked = self
                    .saved
                    .likes
                    .get(&id)
                    .and_then(|l| l.by.get(&self.me))
                    .map_or(false, |(_, on)| *on);
                // A like goes where the post is, so its readers see it.
                let to = if space.starts_with("x.") { Audience::Public } else { Audience::Group };
                let space = if space.starts_with("x.") { home(&self.me) } else { space };
                if let Err(e) = ournet_plugin::publish(LIKE, &space, to, &json!({"post": id, "on": !liked})) {
                    ui::notify("Not liked", &e);
                }
            }
            "reply" => {
                self.reply_to = Some(text("id"));
                self.show();
            }
            "noreply" => {
                self.reply_to = None;
                self.show();
            }
            "people" => {
                self.show_people = !self.show_people;
                self.show();
            }
            "follow" => {
                let person = text("person");
                let following = !self.saved.unfollowed.contains(&person);
                if following {
                    self.saved.unfollowed.insert(person.clone());
                } else {
                    self.saved.unfollowed.remove(&person);
                }
                let _ = ournet_plugin::follow(&home(&person), !following);
                self.save();
                self.show();
            }
            _ => {}
        }
    }
}

ournet_plugin::plugin!(Microblog);
