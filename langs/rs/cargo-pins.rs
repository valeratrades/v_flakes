#!/usr/bin/env -S cargo -Zscript -q
---cargo
[package]
edition = "2024"

[dependencies]
clap = { version = "4", features = ["derive"] }
serde_json = "1"
toml_edit = "0.25"
---

use std::{
	collections::{BTreeMap, BTreeSet},
	path::{Path, PathBuf},
	process::Command,
};

use clap::Parser;
use toml_edit::{DocumentMut, TableLike, Value};

const KINDS: [&str; 3] = ["dependencies", "dev-dependencies", "build-dependencies"];

#[derive(Parser)]
struct Cli {
	cargo_path: PathBuf,
	/// a manifest whose `[workspace.dependencies]` maps crate name to requirement
	pins_path: PathBuf,
}

fn main() {
	let args = Cli::parse();
	let pins_doc: DocumentMut = std::fs::read_to_string(&args.pins_path).expect("reading pins").parse().expect("valid pins TOML");
	let pins: BTreeMap<&str, &str> = pins_doc["workspace"]["dependencies"]
		.as_table_like()
		.expect("pins: [workspace.dependencies] is a table")
		.iter()
		.map(|(k, v)| {
			(
				k,
				v.as_str().unwrap_or_else(|| panic!("pins: `{k}` must be a requirement string: features stay with each consumer")),
			)
		})
		.collect();

	let out = Command::new("cargo")
		.args(["metadata", "--no-deps", "--format-version", "1", "--manifest-path"])
		.arg(&args.cargo_path)
		.output()
		.expect("running cargo metadata");
	assert!(out.status.success(), "cargo metadata: {}", String::from_utf8_lossy(&out.stderr));
	let meta: serde_json::Value = serde_json::from_slice(&out.stdout).expect("cargo metadata emits JSON");
	let root = Path::new(meta["workspace_root"].as_str().expect("metadata has workspace_root"));
	let manifests: BTreeSet<PathBuf> = meta["packages"]
		.as_array()
		.expect("metadata has packages")
		.iter()
		.map(|p| PathBuf::from(p["manifest_path"].as_str().expect("package has manifest_path")))
		.chain([root.join("Cargo.toml")])
		.collect();

	for path in manifests {
		let src = std::fs::read_to_string(&path).unwrap_or_else(|e| panic!("reading {}: {e}", path.display()));
		let mut doc: DocumentMut = src.parse().unwrap_or_else(|e| panic!("parsing {}: {e}", path.display()));
		let shown = path.strip_prefix(root).expect("members live under the workspace root").display().to_string();
		let mut tables: Vec<&mut dyn TableLike> = Vec::new();
		for (k, item) in doc.as_table_mut().iter_mut() {
			match k.get() {
				"workspace" =>
					if let Some(deps) = item.get_mut("dependencies") {
						tables.push(deps.as_table_like_mut().unwrap_or_else(|| panic!("{shown}: [workspace.dependencies] is a table")));
					},
				"target" =>
					for (_, platform) in item.as_table_like_mut().unwrap_or_else(|| panic!("{shown}: [target] is a table")).iter_mut() {
						for (k, deps) in platform.as_table_like_mut().unwrap_or_else(|| panic!("{shown}: [target.*] is a table")).iter_mut() {
							if KINDS.contains(&k.get()) {
								tables.push(deps.as_table_like_mut().unwrap_or_else(|| panic!("{shown}: [target.*.{}] is a table", k.get())));
							}
						}
					},
				k if KINDS.contains(&k) => tables.push(item.as_table_like_mut().unwrap_or_else(|| panic!("{shown}: [{k}] is a table"))),
				_ => {}
			}
		}
		for deps in tables {
			for (key, dep) in deps.iter_mut() {
				let (name, req): (String, &mut Value) = match dep.as_table_like_mut() {
					Some(t) => {
						if ["workspace", "path", "git", "registry"].iter().any(|s| t.contains_key(s)) {
							continue;
						}
						let name = t
							.get("package")
							.map_or(key.get(), |p| p.as_str().unwrap_or_else(|| panic!("{shown}: `{key}.package` is a string")))
							.to_owned();
						let Some(req) = t.get_mut("version") else {
							panic!("{shown}: `{key}` names no version, path or git")
						};
						(name, req.as_value_mut().unwrap_or_else(|| panic!("{shown}: `{key}.version` is a string")))
					}
					None => (key.get().to_owned(), dep.as_value_mut().unwrap_or_else(|| panic!("{shown}: `{key}` is a requirement or a table"))),
				};
				let Some(&pin) = pins.get(name.as_str()) else { continue };
				let old = req.as_str().unwrap_or_else(|| panic!("{shown}: `{key}` requirement is a string")).to_owned();
				if old != pin {
					let decor = req.decor().clone();
					*req = pin.into();
					*req.decor_mut() = decor;
					eprintln!("v_flakes pins: {shown} {name} {old} → {pin}");
				}
			}
		}
		let out = doc.to_string();
		if out != src {
			std::fs::write(&path, out).unwrap_or_else(|e| panic!("writing {}: {e}", path.display()));
		}
	}
}
