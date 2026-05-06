use std::path::PathBuf;

use toml_edit::{DocumentMut, Item, Table};

#[derive(clap::Args)]
pub struct Cli {
	pub cargo_path: PathBuf,
	pub lints_path: PathBuf,
}

pub fn run(args: Cli) {
	let existing = std::fs::read_to_string(&args.cargo_path).expect("reading Cargo.toml");
	let lints_src = std::fs::read_to_string(&args.lints_path).expect("reading lints input");
	let merged = merge(&existing, &lints_src);
	if merged != existing {
		std::fs::write(&args.cargo_path, &merged).expect("writing Cargo.toml");
	}
}

/// `lints_src` is a TOML document with a top-level `[rust]` table whose contents
/// become the body of `[lints.rust]` (or `[workspace.lints.rust]`).
///
/// If the Cargo.toml has a `[workspace]` table, lints are written under
/// `[workspace.lints.rust]` (workspace members are expected to inherit via
/// `[lints] workspace = true`); otherwise under `[lints.rust]`.
pub fn merge(cargo: &str, lints_src: &str) -> String {
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
		let workspace = doc
			.entry("workspace")
			.or_insert_with(|| Item::Table(Table::new()))
			.as_table_mut()
			.expect("inserted above");
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
