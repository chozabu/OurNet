//! A git remote helper for OurNet: with this on the PATH and the OurNet app
//! running, `git clone ournet://<repo>` and `git push ournet://<repo>` work
//! against the app's Git plugin.
//!
//! git starts it as `git-remote-ournet <remote> <url>` and talks over stdin
//! and stdout (gitremote-helpers(7)). It answers `list`, `fetch` and `push`
//! with real git doing the object work: `git pack-objects` makes what a push
//! carries and `git index-pack` takes in what a fetch brings. The app is
//! reached through its local bridge, whose port and key it writes to
//! `~/.ournet/bridge.json` (or where `OURNET_BRIDGE` says).

use std::collections::BTreeMap;
use std::io::{self, BufRead, BufReader, Read, Seek, SeekFrom, Write};
use std::fs::{File, OpenOptions};
use std::path::PathBuf;
use std::net::TcpStream;
use std::process::{Command, Stdio};
use std::time::Duration;

use serde_json::{json, Value};


fn main() {
    let args: Vec<String> = std::env::args().collect();
    let Some(url) = args.get(2).or(args.get(1)).cloned() else {
        eprintln!("usage: git-remote-ournet <remote> <url>  (git runs this for ournet:// remotes)");
        std::process::exit(2);
    };
    if let Err(e) = run(&url) {
        eprintln!("fatal: ournet: {e}");
        std::process::exit(1);
    }
}

fn run(url: &str) -> Result<(), String> {
    let stdin = io::stdin();
    let mut input = stdin.lock();
    let mut out = io::stdout().lock();
    let mut remote: Option<BTreeMap<String, String>> = None;
    loop {
        let mut line = String::new();
        if input.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
            return Ok(());
        }
        let line = line.trim_end();
        match line.split(' ').next().unwrap_or("") {
            "" => return Ok(()),
            "capabilities" => write!(out, "fetch\npush\n\n").map_err(|e| e.to_string())?,
            "list" => {
                let listed = call(&json!({"op": "list", "repo": url}), &[])?.0;
                let refs = text_map(&listed["refs"]);
                for (name, sha) in &refs {
                    writeln!(out, "{sha} {name}").map_err(|e| e.to_string())?;
                }
                if let Some(head) = listed["head"].as_str() {
                    writeln!(out, "@{head} HEAD").map_err(|e| e.to_string())?;
                }
                writeln!(out).map_err(|e| e.to_string())?;
                if listed["waiting"].as_u64().unwrap_or(0) > 0 {
                    eprintln!("ournet: some pushes are still arriving from friends; this may not be the newest");
                }
                remote = Some(refs);
            }
            "fetch" => {
                let mut wanted = vec![line.split(' ').nth(1).unwrap_or("").to_string()];
                wanted.extend(batch(&mut input, "fetch")?.iter().map(|l| l.split(' ').nth(1).unwrap_or("").to_string()));
                fetch(url, &wanted)?;
                writeln!(out).map_err(|e| e.to_string())?;
            }
            "push" => {
                let mut specs = vec![line["push ".len()..].to_string()];
                specs.extend(batch(&mut input, "push")?.iter().map(|l| l["push ".len()..].to_string()));
                let refs = match remote.take() {
                    Some(r) => r,
                    None => text_map(&call(&json!({"op": "list", "repo": url}), &[])?.0["refs"]),
                };
                for result in push(url, &specs, &refs)? {
                    writeln!(out, "{result}").map_err(|e| e.to_string())?;
                }
                writeln!(out).map_err(|e| e.to_string())?;
            }
            other => return Err(format!("unknown command {other}")),
        }
        out.flush().map_err(|e| e.to_string())?;
    }
}

/// The rest of a batch of [command] lines, up to the blank line ending it.
fn batch(input: &mut impl BufRead, command: &str) -> Result<Vec<String>, String> {
    let mut lines = Vec::new();
    loop {
        let mut line = String::new();
        if input.read_line(&mut line).map_err(|e| e.to_string())? == 0 {
            return Ok(lines);
        }
        let line = line.trim_end();
        if line.is_empty() {
            return Ok(lines);
        }
        if !line.starts_with(&format!("{command} ")) {
            return Err(format!("expected {command}, got {line}"));
        }
        lines.push(line.to_string());
    }
}

fn text_map(v: &Value) -> BTreeMap<String, String> {
    v.as_object()
        .map(|m| m.iter().map(|(k, v)| (k.clone(), v.as_str().unwrap_or("").to_string())).collect())
        .unwrap_or_default()
}

fn fetch(url: &str, wanted: &[String]) -> Result<(), String> {
    let listed = call(&json!({"op": "packs", "repo": url}), &[])?.0;
    // Oldest first: each push's pack leaves out what earlier ones carried.
    for pack in listed["packs"].as_array().cloned().unwrap_or_default() {
        let tips: Vec<&str> = pack["tips"].as_array().map(|t| t.iter().filter_map(Value::as_str).collect()).unwrap_or_default();
        if !tips.is_empty() && tips.iter().all(|t| has(t)) {
            continue;
        }
        let id = pack["id"].as_str().unwrap_or("");
        let (mut source, length, chunked) = file_request("GET", &format!("/plugins/git/files/{id}"), None)?;
        if chunked { return Err("OurNet returned a chunked pack instead of a file; update the app".into()); }
        let length = length.ok_or("pack response has no length")?;
        let mut child = git()
            .args(["index-pack", "--stdin", "--fix-thin"])
            .stdin(Stdio::piped())
            .stdout(Stdio::null())
            .spawn()
            .map_err(|e| format!("running git: {e}"))?;
        let mut target = child.stdin.take().unwrap();
        let copied = io::copy(&mut source.by_ref().take(length), &mut target).map_err(|e| e.to_string());
        drop(target);
        if copied.as_ref().ok() != Some(&length) {
            let _ = child.kill(); let _ = child.wait();
            return Err(format!("pack transfer interrupted: {}", copied.err().map(|e| e.to_string()).unwrap_or_default()));
        }
        if !child.wait().map_err(|e| e.to_string())?.success() {
            return Err(format!("git could not read push {id}"));
        }
    }
    let missing = wanted.iter().filter(|w| !has(w)).count();
    if missing > 0 {
        let waiting = listed["waiting"].as_u64().unwrap_or(0);
        return Err(if waiting > 0 {
            format!("{waiting} pushes have not fully arrived from friends yet; try again later")
        } else {
            format!("{missing} wanted objects are not in any push")
        });
    }
    Ok(())
}

/// Pushes [specs] (`[+]src:dst`) and says how each went, as git expects.
fn push(url: &str, specs: &[String], remote: &BTreeMap<String, String>) -> Result<Vec<String>, String> {
    let mut results = Vec::new();
    let mut refs = BTreeMap::new();
    let mut old = BTreeMap::new();
    let mut force = false;
    for spec in specs {
        let (forced, spec) = match spec.strip_prefix('+') {
            Some(s) => (true, s),
            None => (false, spec.as_str()),
        };
        let (src, dst) = spec.split_once(':').unwrap_or((spec, spec));
        let was = remote.get(dst).cloned().unwrap_or_default();
        let new = if src.is_empty() {
            String::new()
        } else {
            match output(&["rev-parse", "--verify", "--quiet", src]) {
                Some(sha) => sha,
                None => {
                    results.push(format!("error {dst} cannot resolve {src}"));
                    continue;
                }
            }
        };
        if !forced && !was.is_empty() && !new.is_empty() && was != new {
            if !has(&was) {
                results.push(format!("error {dst} fetch first"));
                continue;
            }
            if !git().args(["merge-base", "--is-ancestor", &was, &new]).status().map(|s| s.success()).unwrap_or(false) {
                results.push(format!("error {dst} non-fast-forward"));
                continue;
            }
        }
        force |= forced;
        refs.insert(dst.to_string(), new);
        old.insert(dst.to_string(), was);
    }
    if refs.is_empty() {
        return Ok(results);
    }

    // What is new: everything reachable from the pushed commits that is
    // not reachable from what the remote already has.
    let mut revs = String::new();
    for sha in refs.values().filter(|s| !s.is_empty()) {
        revs.push_str(&format!("{sha}\n"));
    }
    for sha in remote.values().filter(|s| has(s)) {
        revs.push_str(&format!("^{sha}\n"));
    }
    let mut spool = Spool::new()?;
    let has_pack = refs.values().any(|s| !s.is_empty());
    let (size, objects) = if has_pack {
        let file = spool.file.as_mut().unwrap();
        let mut child = git()
            .args(["pack-objects", "--stdout", "--revs", "--delta-base-offset", "-q"])
            .stdin(Stdio::piped())
            .stdout(Stdio::from(file.try_clone().map_err(|e| e.to_string())?))
            .spawn().map_err(|e| format!("running git: {e}"))?;
        let write = child.stdin.take().unwrap().write_all(revs.as_bytes());
        if write.is_err() { let _ = child.kill(); }
        let status = child.wait().map_err(|e| e.to_string())?;
        write.map_err(|e| e.to_string())?;
        if !status.success() { return Err("git pack-objects failed".into()); }
        let size = file.metadata().map_err(|e| e.to_string())?.len();
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        let mut header = [0u8; 12];
        file.read_exact(&mut header).map_err(|e| e.to_string())?;
        if &header[..4] != b"PACK" { return Err("git produced an invalid pack".into()); }
        (size, u32::from_be_bytes(header[8..12].try_into().unwrap()))
    } else { (0, 0) };
    let mut request = json!({"op": "push", "repo": url, "refs": refs, "old": old});
    if force {
        request["force"] = true.into();
    }
    if remote.is_empty() {
        let head = output(&["symbolic-ref", "-q", "HEAD"]).filter(|h| refs.contains_key(h));
        if let Some(head) = head.or_else(|| refs.keys().find(|r| r.starts_with("refs/heads/")).cloned()) {
            request["head"] = head.into();
        }
    }
    if has_pack {
        let file = spool.file.as_mut().unwrap();
        file.seek(SeekFrom::Start(0)).map_err(|e| e.to_string())?;
        eprintln!("ournet: uploading {size} bytes");
        let (mut reply, _, chunked) = file_request("POST", "/plugins/git/files", Some((file, size)))?;
        let mut bytes = Vec::new();
        reply.by_ref().take(64 * 1024).read_to_end(&mut bytes).map_err(|e| e.to_string())?;
        let bytes = if chunked { dechunk(&bytes)? } else { bytes };
        let uploaded: Value = serde_json::from_slice(&bytes).map_err(|e| format!("bad upload answer: {e}"))?;
        request["op"] = "push-file".into();
        request["file"] = uploaded["file"].clone();
        request["size"] = size.into();
        request["objects"] = objects.into();
    }
    match call(&request, &[]) {
        Ok(_) => results.extend(refs.keys().map(|dst| format!("ok {dst}"))),
        Err(e) => {
            let e = e.replace('\n', " ");
            results.extend(refs.keys().map(|dst| format!("error {dst} {e}")));
        }
    }
    Ok(results)
}

/// A temporary pack on disk: producing/uploading it never grows the heap.
struct Spool { path: PathBuf, file: Option<File> }
impl Spool {
    fn new() -> Result<Self, String> {
        let stamp = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map_err(|e| e.to_string())?.as_nanos();
        let path = std::env::temp_dir().join(format!("ournet-pack-{}-{stamp}", std::process::id()));
        let file = OpenOptions::new().read(true).write(true).create_new(true).open(&path).map_err(|e| e.to_string())?;
        Ok(Self { path, file: Some(file) })
    }
}
impl Drop for Spool {
    fn drop(&mut self) { self.file.take(); let _ = std::fs::remove_file(&self.path); }
}

/// Streaming attachment endpoints of the authenticated local bridge.
fn file_request(method: &str, path: &str, body: Option<(&mut File, u64)>) -> Result<(BufReader<TcpStream>, Option<u64>, bool), String> {
    let (port, token) = bridge()?;
    let mut stream = TcpStream::connect(("127.0.0.1", port)).map_err(|e| e.to_string())?;
    // An inactivity timeout, not a deadline on the total transfer size.
    stream.set_read_timeout(Some(Duration::from_secs(300))).map_err(|e| e.to_string())?;
    stream.set_write_timeout(Some(Duration::from_secs(300))).map_err(|e| e.to_string())?;
    let length = body.as_ref().map(|(_, size)| *size).unwrap_or(0);
    write!(stream, "{method} {path} HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nContent-Type: application/octet-stream\r\nContent-Length: {length}\r\nConnection: close\r\n\r\n").map_err(|e| e.to_string())?;
    if let Some((file, size)) = body {
        let copied = io::copy(&mut file.take(size), &mut stream).map_err(|e| e.to_string())?;
        if copied != size { return Err("temporary pack changed during upload".into()); }
    }
    let mut source = BufReader::new(stream);
    let mut status = String::new();
    source.read_line(&mut status).map_err(|e| e.to_string())?;
    let code = status.split_whitespace().nth(1).unwrap_or("").to_string();
    let mut length = None;
    let mut chunked = false;
    let mut total = status.len();
    loop {
        let mut line = String::new();
        source.read_line(&mut line).map_err(|e| e.to_string())?;
        total += line.len();
        if total > 64 * 1024 { return Err("oversized HTTP header".into()); }
        if line == "\r\n" { break; }
        if line.is_empty() { return Err("incomplete HTTP answer".into()); }
        if let Some((name, value)) = line.split_once(':') {
            if name.eq_ignore_ascii_case("content-length") { length = value.trim().parse().ok(); }
            if name.eq_ignore_ascii_case("transfer-encoding") { chunked = value.trim().eq_ignore_ascii_case("chunked"); }
        }
    }
    if code != "200" {
        let mut reason = String::new();
        source.by_ref().take(4096).read_to_string(&mut reason).map_err(|e| e.to_string())?;
        return Err(format!("OurNet file transfer ({code}): {reason}. Check that the app supports streaming Git files"));
    }
    Ok((source, length, chunked))
}

fn git() -> Command {
    Command::new("git")
}

fn output(args: &[&str]) -> Option<String> {
    let out = git().args(args).stderr(Stdio::null()).output().ok()?;
    let text = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !text.is_empty()).then_some(text)
}

/// Whether this repository has object [sha].
fn has(sha: &str) -> bool {
    git()
        .args(["cat-file", "-e", sha])
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

fn bridge() -> Result<(u16, String), String> {
    let path = match std::env::var_os("OURNET_BRIDGE") {
        Some(p) => std::path::PathBuf::from(p),
        None => {
            let home = std::env::var_os("USERPROFILE").or_else(|| std::env::var_os("HOME")).ok_or("no home folder")?;
            std::path::PathBuf::from(home).join(".ournet").join("bridge.json")
        }
    };
    let text = std::fs::read_to_string(&path)
        .map_err(|_| "OurNet is not running here, or its Git plugin is not installed and switched on".to_string())?;
    let v: Value = serde_json::from_str(&text).map_err(|e| format!("{}: {e}", path.display()))?;
    let port = v["port"].as_u64().ok_or("bridge file has no port")? as u16;
    let token = v["token"].as_str().ok_or("bridge file has no key")?.to_string();
    Ok((port, token))
}

/// Asks the Git plugin: a JSON line and [body] there, the same back.
fn call(request: &Value, body: &[u8]) -> Result<(Value, Vec<u8>), String> {
    let (port, token) = bridge()?;
    let mut payload = request.to_string().into_bytes();
    payload.push(b'\n');
    payload.extend_from_slice(body);
    let mut stream = TcpStream::connect(("127.0.0.1", port))
        .map_err(|_| "OurNet is not running here (its local bridge did not answer)".to_string())?;
    stream.set_read_timeout(Some(Duration::from_secs(300))).ok();
    let head = format!(
        "POST /plugins/git HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nContent-Type: application/octet-stream\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
        payload.len()
    );
    stream.write_all(head.as_bytes()).map_err(|e| e.to_string())?;
    stream.write_all(&payload).map_err(|e| e.to_string())?;
    let mut response = Vec::new();
    stream.read_to_end(&mut response).map_err(|e| e.to_string())?;
    let split = response.windows(4).position(|w| w == b"\r\n\r\n").ok_or("bad answer from OurNet")?;
    let status = String::from_utf8_lossy(&response[..split]);
    let mut reply = response[split + 4..].to_vec();
    let chunked = status.lines().any(|l| l.to_ascii_lowercase().starts_with("transfer-encoding:") && l.contains("chunked"));
    if chunked {
        reply = dechunk(&reply)?;
    }
    let code: u16 = status.split(' ').nth(1).and_then(|c| c.parse().ok()).unwrap_or(0);
    if code != 200 {
        return Err(String::from_utf8_lossy(&reply).trim().to_string());
    }
    let end = reply.iter().position(|&b| b == b'\n').unwrap_or(reply.len());
    let header = serde_json::from_slice(&reply[..end]).map_err(|e| format!("bad answer from OurNet: {e}"))?;
    Ok((header, reply.get(end + 1..).unwrap_or(&[]).to_vec()))
}

fn dechunk(mut data: &[u8]) -> Result<Vec<u8>, String> {
    let mut out = Vec::new();
    loop {
        let line = data.windows(2).position(|w| w == b"\r\n").ok_or("bad chunked answer")?;
        let size_text = String::from_utf8_lossy(&data[..line]);
        let size = usize::from_str_radix(size_text.split(';').next().unwrap_or("").trim(), 16).map_err(|_| "bad chunked answer")?;
        data = &data[line + 2..];
        if size == 0 {
            return Ok(out);
        }
        out.extend_from_slice(data.get(..size).ok_or("bad chunked answer")?);
        data = data.get(size + 2..).unwrap_or(&[]);
    }
}
