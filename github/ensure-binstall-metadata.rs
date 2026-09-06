#!/usr/bin/env nix
---cargo
#! nix shell --impure --expr ``
#! nix let rust_flake = builtins.getFlake ''github:oxalica/rust-overlay'';
#! nix     nixpkgs_flake = builtins.getFlake ''nixpkgs'';
#! nix     pkgs = import nixpkgs_flake {
#! nix       system = builtins.currentSystem;
#! nix       overlays = [rust_flake.overlays.default];
#! nix     };
#! nix     toolchain = pkgs.rust-bin.nightly."2025-10-10".default.override {
#! nix       extensions = ["rust-src"];
#! nix     };
#! nix
#! nix in toolchain
#! nix ``
#! nix --command sh -c ``cargo -Zscript -q "$0" "$@"``

[package]
edition = "2024"

[dependencies]
toml_edit = "0.22"
---
//TODO: join with `toml` command of `v_flakes` crate, - could probably DRY some stuff
//! Ensures [package.metadata.binstall] section exists in Cargo.toml
//! Usage: ensure-binstall-metadata.rs [Cargo.toml path]

use std::{env, fs, path::Path};

use toml_edit::{DocumentMut, Item, Table};

/// `cargo publish` resolves `repository.workspace = true`, so binstall's `{ repo }` works either way; here we just need to confirm it resolves to something.
fn resolve_repository(doc: &DocumentMut, cargo_toml_path: &Path) -> Option<String> {
	let repo = doc.get("package")?.get("repository")?;
	if let Some(s) = repo.as_str() {
		return Some(s.to_string());
	}
	if repo.get("workspace").and_then(|w| w.as_bool()) != Some(true) {
		return None;
	}
	let mut dir = cargo_toml_path.canonicalize().ok()?.parent()?.parent().map(Path::to_path_buf);
	while let Some(d) = dir {
		let candidate = d.join("Cargo.toml");
		if candidate.exists() {
			let ws_doc = fs::read_to_string(&candidate).ok()?.parse::<DocumentMut>().ok()?;
			if let Some(ws) = ws_doc.get("workspace") {
				return ws.get("package")?.get("repository")?.as_str().map(str::to_string);
			}
		}
		dir = d.parent().map(Path::to_path_buf);
	}
	None
}

fn ensure_binstall_metadata(cargo_toml_path: &Path) -> Result<bool, Box<dyn std::error::Error>> {
	let content = fs::read_to_string(cargo_toml_path)?;
	let mut doc = content.parse::<DocumentMut>()?;

	// Check if [package.metadata.binstall] already exists
	if let Some(package) = doc.get("package") {
		if let Some(metadata) = package.get("metadata") {
			if metadata.get("binstall").is_some() {
				return Ok(false); // Already exists
			}
		}
	}

	// Verify repository URL exists in [package] (required for binstall)
	resolve_repository(&doc, cargo_toml_path).ok_or("No repository field in [package] - required for binstall")?;

	// Ensure [package.metadata] exists
	let package = doc["package"].as_table_mut().ok_or("No [package] table")?;
	if !package.contains_key("metadata") {
		package.insert("metadata", Item::Table(Table::new()));
	}
	let metadata = package["metadata"].as_table_mut().ok_or("metadata is not a table")?;

	// Create binstall table
	let mut binstall = Table::new();

	// Use { } template syntax for binstall
	binstall.insert("pkg-url", toml_edit::value(format!("{{ repo }}/releases/download/v{{ version }}/{{ name }}-{{ target }}.tar.gz")));
	binstall.insert("bin-dir", toml_edit::value("{ bin }{ binary-ext }"));
	binstall.insert("pkg-fmt", toml_edit::value("tgz"));

	metadata.insert("binstall", Item::Table(binstall));

	fs::write(cargo_toml_path, doc.to_string())?;
	Ok(true)
}

fn main() {
	let args: Vec<String> = env::args().collect();
	let cargo_toml_path = if args.len() > 1 {
		Path::new(&args[1]).to_path_buf()
	} else {
		Path::new("Cargo.toml").to_path_buf()
	};

	if !cargo_toml_path.exists() {
		eprintln!("Cargo.toml not found at {:?}", cargo_toml_path);
		std::process::exit(1);
	}

	match ensure_binstall_metadata(&cargo_toml_path) {
		Ok(true) => println!("Added [package.metadata.binstall] to {:?}", cargo_toml_path),
		Ok(false) => {} // Already exists, silent
		Err(e) => {
			eprintln!("Error: {}", e);
			std::process::exit(1);
		}
	}
}
