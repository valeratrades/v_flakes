#!/usr/bin/env -S cargo -Zscript -q
---cargo
[package]
edition = "2024"

[dependencies]
clap = { version = "4", features = ["derive"] }
toml_edit = "0.25"
---

use std::path::PathBuf;

use clap::Parser;
use toml_edit::{DocumentMut, Item, Table};

#[derive(Parser)]
struct Cli {
	cargo_path: PathBuf,
	lints_path: PathBuf,
}

fn main() {
	let args = Cli::parse();
	if !args.cargo_path.exists() {
		// Nothing to merge into — leave the project alone.
		return;
	}
	let existing = std::fs::read_to_string(&args.cargo_path).expect("reading Cargo.toml");
	let lints_src = std::fs::read_to_string(&args.lints_path).expect("reading lints input");
	let merged = merge(&existing, &lints_src);
	if merged != existing {
		std::fs::write(&args.cargo_path, &merged).expect("writing Cargo.toml");
	}
}

fn merge(cargo: &str, lints_src: &str) -> String {
	let mut doc = cargo.parse::<DocumentMut>().expect("valid Cargo.toml");
	let lints_doc = lints_src.parse::<DocumentMut>().expect("valid lints TOML");

	let mut rust_lints = Table::new();
	if let Some(rust) = lints_doc.get("rust").and_then(|i| i.as_table()) {
		for (k, v) in rust.iter() {
			rust_lints.insert(k, v.clone());
		}
	}
	rust_lints.sort_values();

	let is_workspace = doc.get("workspace").is_some();

	let lints_table: &mut Table = if is_workspace {
		let workspace = doc.entry("workspace").or_insert_with(|| Item::Table(Table::new())).as_table_mut().expect("inserted above");
		workspace
			.entry("lints")
			.or_insert_with(|| {
				let mut t = Table::new();
				t.set_implicit(true);
				Item::Table(t)
			})
			.as_table_mut()
			.expect("inserted above")
	} else {
		doc.entry("lints")
			.or_insert_with(|| {
				let mut t = Table::new();
				t.set_implicit(true);
				Item::Table(t)
			})
			.as_table_mut()
			.expect("inserted above")
	};

	lints_table.insert("rust", Item::Table(rust_lints));

	doc.to_string()
}
