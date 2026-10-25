//! Derived collaboration state. Each signed record stays separate on disk;
//! paging a discussion never loads the repository's complete discussion history.
use ournet_plugin::{index, json, Object, Value};
use serde::{Deserialize, Serialize};

pub const PULL: &str = "x.git.pull";
pub const EVENT: &str = "x.git.pull_event";

pub fn get(bucket: &str, key: &str) -> Option<Value> {
    ournet_plugin::serde_json::from_slice(&index::get(bucket, key).ok()??).ok()
}
pub fn put(bucket: &str, key: &str, value: &Value) -> Result<(), String> {
    index::put(bucket, &[(key.into(), value.to_string().into_bytes())])
}

/// Idempotent linked pages. Arrival order is local; identity, timestamps and
/// reducer results come from the signed records, independently of that order.
pub fn append(bucket: &str, id: &str, value: Value) -> Result<bool, String> {
    if get(bucket, id).is_some() { return Ok(false); }
    let next = get(bucket, "head").and_then(|v| v.as_str().map(String::from)).unwrap_or_default();
    index::put(bucket, &[
        (id.into(), json!({"next": next, "value": value}).to_string().into_bytes()),
        ("head".into(), json!(id).to_string().into_bytes()),
    ])?;
    Ok(true)
}
pub fn page(bucket: &str, after: &str, count: usize) -> (Vec<Value>, String) {
    let mut next = if after.is_empty() {
        get(bucket, "head").and_then(|v| v.as_str().map(String::from)).unwrap_or_default()
    } else { after.into() };
    let mut rows = Vec::new();
    while rows.len() < count && !next.is_empty() {
        let Some(node) = get(bucket, &next) else { break };
        rows.push(node["value"].clone());
        next = node["next"].as_str().unwrap_or("").into();
    }
    (rows, next)
}

#[derive(Clone, Default, Serialize, Deserialize)]
pub struct Pull {
    pub id: String,
    pub repo: String,
    pub source: String,
    pub author: String,
    pub space: String,
    pub title: String,
    pub body: String,
    pub base_ref: String,
    pub head_ref: String,
    pub base: String,
    pub head: String,
    pub status: String,
    pub state_at: (u64, String),
    pub head_at: (u64, String),
    pub created: u64,
    #[serde(default)] pub target_created:u64,
    #[serde(default)] pub source_created:u64,
}
impl Pull {
    pub fn load(id: &str) -> Option<Self> {
        ournet_plugin::serde_json::from_value(get("pulls", id)?).ok()
    }
    fn save(&self) -> Result<(), String> {
        put("pulls", &self.id, &ournet_plugin::serde_json::to_value(self).map_err(|e| e.to_string())?)
    }
    pub fn from_object(o: &Object) -> Option<Self> {
        let p = o.json();
        let field = |k: &str| p[k].as_str().unwrap_or("").to_string();
        let pull = Self { id: o.id.clone(), repo: field("repo"), source: field("source"),
            author: o.author.clone(), space: o.space.clone(), title: field("title"), body: field("body"),
            base_ref: field("baseRef"), head_ref: field("headRef"), base: field("base"), head: field("head"),
            status: "open".into(), created: o.created, target_created:p["targetCreated"].as_u64().unwrap_or(0),source_created:p["sourceCreated"].as_u64().unwrap_or(0), state_at: (o.created, o.id.clone()),
            head_at: (o.created, o.id.clone()) };
        if pull.title.trim().is_empty() || !super::valid_ref(&pull.base_ref) || !super::valid_ref(&pull.head_ref)
            || super::pack::unhex(&pull.base).is_none() || super::pack::unhex(&pull.head).is_none() { return None; }
        Some(pull)
    }
    pub fn apply(&mut self, e: &Value, maintainer: bool) {
        let author = e["author"].as_str().unwrap_or("");
        let stamp = (e["at"].as_u64().unwrap_or(0), e["id"].as_str().unwrap_or("").to_string());
        match e["action"].as_str().unwrap_or("") {
            "close" | "reopen" if self.status != "merged" && (author == self.author || maintainer) && stamp > self.state_at => {
                self.status = if e["action"] == "close" { "closed" } else { "open" }.into();
                self.state_at = stamp;
            }
            "merged" if maintainer && (self.status != "merged" || stamp > self.state_at) => {
                self.status = "merged".into(); self.state_at = stamp.clone();
                if let Some(head)=e["head"].as_str().filter(|s|super::pack::unhex(s).is_some()) {
                    self.head=head.into(); self.head_at=stamp;
                }
            }
            "update" if self.status != "merged" && author == self.author && stamp > self.head_at => {
                if super::pack::unhex(e["head"].as_str().unwrap_or("")).is_some() {
                    self.head = e["head"].as_str().unwrap().into(); self.head_at = stamp;
                }
            }
            _ => {},
        }
    }
}

pub fn create(pull: Pull) -> Result<(), String> {
    if Pull::load(&pull.id).is_some() { return Ok(()); }
    append(&format!("pull-list/{}", pull.repo), &pull.id, json!(pull.id))?;
    pull.save()?;
    Ok(())
}
pub fn event(o: &Object, maintainer: bool) -> Result<Option<String>, String> {
    let p = o.json();
    let id = p["pull"].as_str().unwrap_or("");
    let e = json!({"id": o.id, "author": o.author, "at": o.created, "space": o.space,
        "action": p["action"], "body": p["body"], "head": p["head"]});
    append(&format!("pull-events/{id}"), &o.id, e.clone())?;
    let Some(mut pull) = Pull::load(id) else { return Ok(None) };
    pull.apply(&e, maintainer);
    pull.save()?;
    Ok(Some(pull.repo))
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn state_authority_and_order_are_independent_of_delivery() {
        let base = Pull { author: "alice".into(), status: "open".into(), ..Default::default() };
        let close = json!({"id":"a", "author":"alice", "at":2, "action":"close"});
        let reopen = json!({"id":"b", "author":"alice", "at":3, "action":"reopen"});
        let forged = json!({"id":"c", "author":"mallory", "at":100, "action":"merged"});
        let mut a = base.clone(); a.apply(&close, false); a.apply(&reopen, false); a.apply(&forged, false);
        let mut b = base; b.apply(&reopen, false); b.apply(&close, false);
        assert_eq!(a.status, "open"); assert_eq!(a.state_at, b.state_at);
        a.apply(&forged, true); assert_eq!(a.status, "merged");
    }
}
