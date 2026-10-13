//! Builds OurNet plugins into installable packages.
//!
//!     cargo run -p pack --release [-- <plugin>…] [--watch]
//!
//! For each plugin directory here (one holding `manifest.json`), builds its
//! crate for `wasm32-unknown-unknown`, wraps the module as a component and
//! zips it with the manifest, `ui.rfwtxt` and anything in `assets/` into
//! `dist/<id>.ournet-plugin`. With `--watch`, does so again whenever a
//! plugin's sources change, for the app's hot reload (PLUGINS.md).

use std::fs;
use std::io::Write;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{Duration, SystemTime};

use serde_json::Value;

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let watch = args.iter().any(|a| a == "--watch");
    let only: Vec<&String> = args.iter().filter(|a| !a.starts_with("--")).collect();
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..");
    let plugins: Vec<PathBuf> = fs::read_dir(&root)
        .expect("plugins directory")
        .filter_map(|e| e.ok().map(|e| e.path()))
        .filter(|p| p.join("manifest.json").exists())
        .filter(|p| only.is_empty() || only.iter().any(|o| p.ends_with(o.as_str())))
        .collect();
    if plugins.is_empty() {
        eprintln!("No plugins found");
        std::process::exit(1);
    }
    let mut built = vec![SystemTime::UNIX_EPOCH; plugins.len()];
    loop {
        let mut failed = false;
        for (i, dir) in plugins.iter().enumerate() {
            let changed = newest(dir);
            if changed <= built[i] {
                continue;
            }
            built[i] = changed;
            match pack(&root, dir) {
                Ok(out) => println!("{}", out.display()),
                Err(e) => {
                    eprintln!("{}: {e}", dir.display());
                    failed = true;
                }
            }
        }
        if !watch {
            std::process::exit(failed as i32);
        }
        std::thread::sleep(Duration::from_millis(500));
    }
}

/// When anything in [dir] (outside build output) last changed.
fn newest(dir: &Path) -> SystemTime {
    let mut latest = SystemTime::UNIX_EPOCH;
    let Ok(entries) = fs::read_dir(dir) else { return latest };
    for entry in entries.flatten() {
        let path = entry.path();
        let time = if path.is_dir() {
            newest(&path)
        } else {
            entry.metadata().and_then(|m| m.modified()).unwrap_or(latest)
        };
        latest = latest.max(time);
    }
    latest
}

fn pack(root: &Path, dir: &Path) -> Result<PathBuf, String> {
    let manifest_text = fs::read_to_string(dir.join("manifest.json")).map_err(|e| e.to_string())?;
    let manifest: Value = serde_json::from_str(&manifest_text).map_err(|e| format!("manifest.json: {e}"))?;
    let id = manifest["id"].as_str().ok_or("manifest.json: no id")?;
    let krate = dir.file_name().unwrap().to_string_lossy().to_string();
    let status = Command::new("cargo")
        .args(["build", "--release", "--target", "wasm32-unknown-unknown", "-p", &krate])
        .current_dir(root)
        .status()
        .map_err(|e| e.to_string())?;
    if !status.success() {
        return Err("cargo build failed".into());
    }
    let module_path = root
        .join("target/wasm32-unknown-unknown/release")
        .join(format!("{}.wasm", krate.replace('-', "_")));
    let module = fs::read(&module_path).map_err(|e| format!("{}: {e}", module_path.display()))?;
    let component = wit_component::ComponentEncoder::default()
        .validate(true)
        .module(&module)
        .and_then(|e| e.encode())
        .map_err(|e| format!("componentizing: {e:#}"))?;

    let dist = root.join("dist");
    fs::create_dir_all(&dist).map_err(|e| e.to_string())?;
    let out = dist.join(format!("{id}.ournet-plugin"));
    let next = out.with_extension("next");
    let file = fs::File::create(&next).map_err(|e| e.to_string())?;
    let mut zip = zip::ZipWriter::new(file);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .last_modified_time(zip::DateTime::default());
    let mut add = |name: &str, bytes: &[u8]| -> Result<(), String> {
        zip.start_file(name, options).map_err(|e| e.to_string())?;
        zip.write_all(bytes).map_err(|e| e.to_string())
    };
    add("manifest.json", manifest_text.as_bytes())?;
    add("plugin.wasm", &component)?;
    if let Ok(ui) = fs::read(dir.join("ui.rfwtxt")) {
        add("ui.rfwtxt", &ui)?;
    }
    if let Ok(entries) = fs::read_dir(dir.join("assets")) {
        for entry in entries.flatten() {
            if let Ok(bytes) = fs::read(entry.path()) {
                add(&format!("assets/{}", entry.file_name().to_string_lossy()), &bytes)?;
            }
        }
    }
    zip.finish().map_err(|e| e.to_string())?;
    // Replaced whole, so a watching app never reads half a package.
    fs::rename(&next, &out).map_err(|e| e.to_string())?;
    Ok(out)
}
