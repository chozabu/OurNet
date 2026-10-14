use std::{fs, io::Write, path::PathBuf, process::Command};
fn main() -> Result<(), Box<dyn std::error::Error>> {
    let root = PathBuf::from(env!("CARGO_MANIFEST_DIR"))
        .parent()
        .unwrap()
        .to_owned();
    if !Command::new("cargo")
        .args([
            "build",
            "--release",
            "--target",
            "wasm32-unknown-unknown",
            "-p",
            "blast-garden",
        ])
        .current_dir(&root)
        .status()?
        .success()
    {
        return Err("plugin build failed".into());
    }
    let module = fs::read(root.join("target/wasm32-unknown-unknown/release/blast_garden.wasm"))?;
    let component = wit_component::ComponentEncoder::default()
        .validate(true)
        .module(&module)?
        .encode()?;
    fs::create_dir_all(root.join("dist"))?;
    let output = root.join("dist/blast-garden.ournet-plugin");
    let temporary = output.with_extension("next");
    let mut zip = zip::ZipWriter::new(fs::File::create(&temporary)?);
    let options = zip::write::SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .last_modified_time(zip::DateTime::default());
    for name in ["manifest.json", "ui.rfwtxt"] {
        zip.start_file(name, options)?;
        let path = if name == "manifest.json" {
            root.join("package").join(name)
        } else {
            root.join(name)
        };
        zip.write_all(&fs::read(path)?)?;
    }
    zip.start_file("plugin.wasm", options)?;
    zip.write_all(&component)?;
    zip.finish()?;
    fs::rename(temporary, &output)?;
    println!("{}", output.display());
    Ok(())
}
