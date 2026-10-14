//! Reading git packfiles: what `git pack-objects` writes and a push carries.
//! Enough of git to show a repository: object headers, zlib, deltas, and the
//! commit, tree and tag formats. Writing is left to git itself.

use std::collections::HashMap;

use miniz_oxide::inflate::core::{decompress, inflate_flags, DecompressorOxide};
use miniz_oxide::inflate::TINFLStatus;

pub type Sha = [u8; 20];

pub const COMMIT: u8 = 1;
pub const TREE: u8 = 2;
pub const BLOB: u8 = 3;
pub const TAG: u8 = 4;
const OFS_DELTA: u8 = 6;
const REF_DELTA: u8 = 7;

/// Largest object read, whole: bigger blobs are named, not shown.
pub const MAX_OBJECT: usize = 32 * 1024 * 1024;

pub fn hex(sha: &Sha) -> String {
    sha.iter().map(|b| format!("{b:02x}")).collect()
}

pub fn unhex(text: &str) -> Option<Sha> {
    if text.len() != 40 {
        return None;
    }
    let mut sha = [0u8; 20];
    for (i, b) in sha.iter_mut().enumerate() {
        *b = u8::from_str_radix(text.get(i * 2..i * 2 + 2)?, 16).ok()?;
    }
    Some(sha)
}

pub fn object_sha(kind: u8, data: &[u8]) -> Sha {
    let mut h = sha1_smol::Sha1::new();
    h.update(format!("{} {}\0", type_name(kind), data.len()).as_bytes());
    h.update(data);
    h.digest().bytes()
}

pub fn type_name(kind: u8) -> &'static str {
    match kind {
        COMMIT => "commit",
        TREE => "tree",
        BLOB => "blob",
        TAG => "tag",
        _ => "unknown",
    }
}

/// Checks a pack's header and trailing checksum; returns its object count.
pub fn check(pack: &[u8]) -> Result<u32, String> {
    if pack.len() < 32 || &pack[..4] != b"PACK" {
        return Err("not a git pack".into());
    }
    let version = u32::from_be_bytes(pack[4..8].try_into().unwrap());
    if version != 2 && version != 3 {
        return Err(format!("pack version {version} is not supported"));
    }
    let body = pack.len() - 20;
    if sha1_smol::Sha1::from(&pack[..body]).digest().bytes()[..] != pack[body..] {
        return Err("pack checksum does not match".into());
    }
    Ok(u32::from_be_bytes(pack[8..12].try_into().unwrap()))
}

/// One entry's header: its type, inflated size, where its data starts, and
/// for a delta, its base.
struct Header {
    kind: u8,
    size: usize,
    data: usize,
    base: Option<Base>,
}

enum Base {
    Offset(usize),
    Sha(Sha),
}

fn header(pack: &[u8], at: usize) -> Result<Header, String> {
    let bad = || "pack is cut short".to_string();
    let mut pos = at;
    let mut c = *pack.get(pos).ok_or_else(bad)?;
    pos += 1;
    let kind = (c >> 4) & 7;
    let mut size = (c & 15) as usize;
    let mut shift = 4;
    while c & 0x80 != 0 {
        c = *pack.get(pos).ok_or_else(bad)?;
        pos += 1;
        if shift > 50 {
            return Err("bad object size".into());
        }
        size |= ((c & 0x7f) as usize) << shift;
        shift += 7;
    }
    let base = match kind {
        OFS_DELTA => {
            let mut c = *pack.get(pos).ok_or_else(bad)?;
            pos += 1;
            let mut ofs = (c & 0x7f) as usize;
            while c & 0x80 != 0 {
                c = *pack.get(pos).ok_or_else(bad)?;
                pos += 1;
                ofs = ((ofs + 1) << 7) | (c & 0x7f) as usize;
                if ofs > at {
                    return Err("delta base before the pack".into());
                }
            }
            if ofs == 0 || ofs > at {
                return Err("bad delta base".into());
            }
            Some(Base::Offset(at - ofs))
        }
        REF_DELTA => {
            let sha: Sha = pack.get(pos..pos + 20).ok_or_else(bad)?.try_into().unwrap();
            pos += 20;
            Some(Base::Sha(sha))
        }
        COMMIT | TREE | BLOB | TAG => None,
        _ => return Err(format!("unknown object type {kind}")),
    };
    if size > MAX_OBJECT {
        return Err("object too large".into());
    }
    Ok(Header { kind, size, data: pos, base })
}

/// Inflates the zlib stream at [at], which should give [size] bytes; returns
/// them and how many bytes of the pack the stream took.
fn inflate(pack: &[u8], at: usize, size: usize) -> Result<(Vec<u8>, usize), String> {
    let mut out = vec![0u8; size + 1];
    let mut state = DecompressorOxide::new();
    let flags = inflate_flags::TINFL_FLAG_PARSE_ZLIB_HEADER
        | inflate_flags::TINFL_FLAG_USING_NON_WRAPPING_OUTPUT_BUF
        | inflate_flags::TINFL_FLAG_COMPUTE_ADLER32;
    let input = pack.get(at..).ok_or("pack is cut short")?;
    let (status, used, written) = decompress(&mut state, input, &mut out, 0, flags);
    if status != TINFLStatus::Done || written != size {
        return Err("bad compressed data".into());
    }
    out.truncate(size);
    Ok((out, used))
}

fn varint(delta: &[u8], pos: &mut usize) -> Result<usize, String> {
    let mut value = 0usize;
    let mut shift = 0;
    loop {
        let c = *delta.get(*pos).ok_or("bad delta")?;
        *pos += 1;
        value |= ((c & 0x7f) as usize) << shift;
        shift += 7;
        if c & 0x80 == 0 || shift > 56 {
            return Ok(value);
        }
    }
}

pub fn apply_delta(base: &[u8], delta: &[u8]) -> Result<Vec<u8>, String> {
    let mut pos = 0;
    if varint(delta, &mut pos)? != base.len() {
        return Err("delta does not fit its base".into());
    }
    let size = varint(delta, &mut pos)?;
    if size > MAX_OBJECT {
        return Err("object too large".into());
    }
    let mut out = Vec::with_capacity(size);
    while pos < delta.len() {
        let op = delta[pos];
        pos += 1;
        if op & 0x80 != 0 {
            let mut offset = 0usize;
            let mut len = 0usize;
            for i in 0..4 {
                if op & (1 << i) != 0 {
                    offset |= (*delta.get(pos).ok_or("bad delta")? as usize) << (8 * i);
                    pos += 1;
                }
            }
            for i in 0..3 {
                if op & (0x10 << i) != 0 {
                    len |= (*delta.get(pos).ok_or("bad delta")? as usize) << (8 * i);
                    pos += 1;
                }
            }
            if len == 0 {
                len = 0x10000;
            }
            out.extend_from_slice(base.get(offset..offset + len).ok_or("bad delta copy")?);
        } else if op != 0 {
            let n = op as usize;
            out.extend_from_slice(delta.get(pos..pos + n).ok_or("bad delta insert")?);
            pos += n;
        } else {
            return Err("bad delta op".into());
        }
    }
    if out.len() != size {
        return Err("delta gave the wrong size".into());
    }
    Ok(out)
}

/// Finds objects that a pack's REF deltas name but it does not hold.
pub trait Lookup {
    fn object(&mut self, sha: &Sha) -> Option<(u8, Vec<u8>)>;
}

/// Reads the object at [offset], following its delta chain.
pub fn read_at(
    pack: &[u8],
    offset: usize,
    own: &HashMap<Sha, u32>,
    other: &mut dyn Lookup,
) -> Result<(u8, Vec<u8>), String> {
    // Walk down to a whole object, then apply the deltas back up.
    let mut deltas: Vec<Vec<u8>> = Vec::new();
    let mut at = offset;
    let (kind, mut data) = loop {
        if deltas.len() > 64 {
            return Err("delta chain too long".into());
        }
        let h = header(pack, at)?;
        let (data, _) = inflate(pack, h.data, h.size)?;
        match h.base {
            None => break (h.kind, data),
            Some(Base::Offset(base)) => {
                deltas.push(data);
                at = base;
            }
            Some(Base::Sha(sha)) => {
                deltas.push(data);
                if let Some(&base) = own.get(&sha) {
                    at = base as usize;
                } else {
                    break other.object(&sha).ok_or("delta base is missing")?;
                }
            }
        }
    };
    while let Some(delta) = deltas.pop() {
        data = apply_delta(&data, &delta)?;
    }
    Ok((kind, data))
}

/// An object found while indexing a pack.
#[derive(Clone, Copy)]
pub struct Entry {
    pub sha: Sha,
    pub offset: u32,
    pub kind: u8,
}

/// Indexes a pack a piece at a time, so a big one is spread over several
/// calls: each [Indexer::step] reads until its time is up.
pub struct Indexer {
    pub pack: Vec<u8>,
    count: u32,
    done: u32,
    pos: usize,
    pub entries: Vec<Entry>,
    own: HashMap<Sha, u32>,
    /// Whole objects by offset, kept while their deltas are likely near.
    cache: HashMap<usize, (u8, std::rc::Rc<Vec<u8>>)>,
    cached: usize,
}

const CACHE_BYTES: usize = 12 * 1024 * 1024;

impl Indexer {
    pub fn new(pack: Vec<u8>) -> Result<Indexer, String> {
        let count = check(&pack)?;
        Ok(Indexer {
            pack,
            count,
            done: 0,
            pos: 12,
            entries: Vec::new(),
            own: HashMap::new(),
            cache: HashMap::new(),
            cached: 0,
        })
    }

    pub fn finished(&self) -> bool {
        self.done >= self.count
    }

    /// Reads entries until [more] says stop; true when the pack is done.
    pub fn step(&mut self, other: &mut dyn Lookup, mut more: impl FnMut() -> bool) -> Result<bool, String> {
        while !self.finished() && more() {
            let at = self.pos;
            let h = header(&self.pack, at)?;
            let (data, used) = inflate(&self.pack, h.data, h.size)?;
            self.pos = h.data + used;
            if self.pos > self.pack.len() - 20 {
                return Err("pack is cut short".into());
            }
            let (kind, whole) = match h.base {
                None => (h.kind, data),
                Some(base) => {
                    let (kind, base) = match base {
                        Base::Offset(o) => self.whole(o, other)?,
                        Base::Sha(sha) => match self.own.get(&sha) {
                            Some(&o) => self.whole(o as usize, other)?,
                            None => {
                                let (k, d) = other.object(&sha).ok_or("delta base is missing")?;
                                (k, std::rc::Rc::new(d))
                            }
                        },
                    };
                    (kind, apply_delta(&base, &data)?)
                }
            };
            let sha = object_sha(kind, &whole);
            self.own.insert(sha, at as u32);
            self.entries.push(Entry { sha, offset: at as u32, kind });
            // Trees and small objects are the usual delta bases.
            if whole.len() < 1024 * 1024 {
                self.keep(at, kind, std::rc::Rc::new(whole));
            }
            self.done += 1;
        }
        Ok(self.finished())
    }

    fn keep(&mut self, at: usize, kind: u8, data: std::rc::Rc<Vec<u8>>) {
        if self.cached + data.len() > CACHE_BYTES {
            self.cache.clear();
            self.cached = 0;
        }
        self.cached += data.len();
        self.cache.insert(at, (kind, data));
    }

    fn whole(&mut self, at: usize, other: &mut dyn Lookup) -> Result<(u8, std::rc::Rc<Vec<u8>>), String> {
        if let Some((k, d)) = self.cache.get(&at) {
            return Ok((*k, d.clone()));
        }
        let (k, d) = read_at(&self.pack, at, &self.own, other)?;
        let d = std::rc::Rc::new(d);
        self.keep(at, k, d.clone());
        Ok((k, d))
    }
}

/// Serialised entries: 20-byte SHA, 4-byte offset, 1-byte type each.
pub fn save_entries(entries: &[Entry]) -> Vec<u8> {
    let mut out = Vec::with_capacity(entries.len() * 25);
    for e in entries {
        out.extend_from_slice(&e.sha);
        out.extend_from_slice(&e.offset.to_be_bytes());
        out.push(e.kind);
    }
    out
}

pub fn load_entries(bytes: &[u8]) -> Vec<Entry> {
    bytes
        .chunks_exact(25)
        .map(|c| Entry {
            sha: c[..20].try_into().unwrap(),
            offset: u32::from_be_bytes(c[20..24].try_into().unwrap()),
            kind: c[24],
        })
        .collect()
}

#[derive(Clone, Debug, Default, PartialEq)]
pub struct Person {
    pub name: String,
    pub email: String,
    /// Seconds since the epoch.
    pub time: i64,
}

fn person(line: &str) -> Person {
    // "Name <email> 1700000000 +0100"
    let (name, rest) = line.split_once('<').unwrap_or((line, ""));
    let (email, rest) = rest.split_once('>').unwrap_or((rest, ""));
    let time = rest.split_whitespace().next().and_then(|t| t.parse().ok()).unwrap_or(0);
    Person { name: name.trim().to_string(), email: email.trim().to_string(), time }
}

#[derive(Clone, Debug, Default)]
pub struct Commit {
    pub tree: Option<Sha>,
    pub parents: Vec<Sha>,
    pub author: Person,
    pub committer: Person,
    pub message: String,
}

impl Commit {
    pub fn title(&self) -> &str {
        self.message.lines().next().unwrap_or("")
    }
}

pub fn parse_commit(data: &[u8]) -> Commit {
    let text = String::from_utf8_lossy(data);
    let (head, message) = text.split_once("\n\n").unwrap_or((&text, ""));
    let mut c = Commit { message: message.to_string(), ..Default::default() };
    for line in head.lines() {
        let (key, value) = line.split_once(' ').unwrap_or((line, ""));
        match key {
            "tree" => c.tree = unhex(value),
            "parent" => c.parents.extend(unhex(value)),
            "author" => c.author = person(value),
            "committer" => c.committer = person(value),
            _ => {}
        }
    }
    c
}

/// An annotated tag's target.
pub fn tag_target(data: &[u8]) -> Option<Sha> {
    let text = String::from_utf8_lossy(data);
    let line = text.lines().next()?;
    unhex(line.strip_prefix("object ")?)
}

#[derive(Clone, Debug)]
pub struct TreeEntry {
    pub mode: u32,
    pub name: String,
    pub sha: Sha,
}

impl TreeEntry {
    pub fn is_dir(&self) -> bool {
        self.mode == 0o40000
    }
    pub fn is_submodule(&self) -> bool {
        self.mode == 0o160000
    }
}

pub fn parse_tree(data: &[u8]) -> Vec<TreeEntry> {
    let mut out = Vec::new();
    let mut pos = 0;
    while pos < data.len() {
        let Some(space) = data[pos..].iter().position(|&b| b == b' ') else { break };
        let mode = u32::from_str_radix(&String::from_utf8_lossy(&data[pos..pos + space]), 8).unwrap_or(0);
        pos += space + 1;
        let Some(nul) = data[pos..].iter().position(|&b| b == 0) else { break };
        let name = String::from_utf8_lossy(&data[pos..pos + nul]).to_string();
        pos += nul + 1;
        let Some(sha) = data.get(pos..pos + 20) else { break };
        out.push(TreeEntry { mode, name, sha: sha.try_into().unwrap() });
        pos += 20;
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn deltas_copy_and_insert() {
        let base = b"hello world";
        // src 11, dst 11; copy 6 bytes at 0, insert "there".
        let delta = [11u8, 11, 0x90, 6, 5, b't', b'h', b'e', b'r', b'e'];
        assert_eq!(apply_delta(base, &delta).unwrap(), b"hello there");
        assert!(apply_delta(b"short", &delta).is_err());
    }

    #[test]
    fn hashes_like_git() {
        // `printf 'hi\n' | git hash-object --stdin`
        assert_eq!(hex(&object_sha(BLOB, b"hi\n")), "45b983be36b73c0788dc9cbcb76cbb80fc7bb057");
    }

    #[test]
    fn commits_and_trees_parse() {
        let c = parse_commit(
            b"tree 4b825dc642cb6eb9a060e54bf8d69288fbee4904\nauthor A B <a@b> 1700000000 +0000\ncommitter A B <a@b> 1700000001 +0000\n\nFirst line\n\nMore",
        );
        assert_eq!(hex(&c.tree.unwrap()), "4b825dc642cb6eb9a060e54bf8d69288fbee4904");
        assert_eq!(c.author.name, "A B");
        assert_eq!(c.committer.time, 1700000001);
        assert_eq!(c.title(), "First line");
        let mut t = b"100644 a.txt\0".to_vec();
        t.extend_from_slice(&[1; 20]);
        t.extend_from_slice(b"40000 src\0");
        t.extend_from_slice(&[2; 20]);
        let entries = parse_tree(&t);
        assert_eq!(entries.len(), 2);
        assert!(entries[1].is_dir());
        assert_eq!(entries[0].name, "a.txt");
    }
}
