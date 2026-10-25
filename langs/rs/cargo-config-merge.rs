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
use toml_edit::{DocumentMut, Item, Table, TableLike};

/// Owns exactly the leaves of `generated` in `config`; everything else in it is left as found.
#[derive(Parser)]
struct Cli {
	config: PathBuf,
	generated: PathBuf,
	/// what the previous run generated: its leaves that `generated` no longer has get removed
	previous: Option<PathBuf>,
}

fn main() {
	let args = Cli::parse();
	let existing = if args.config.exists() {
		std::fs::read_to_string(&args.config).expect("reading cargo config")
	} else {
		String::new()
	};
	let parse = |p: &PathBuf| {
		std::fs::read_to_string(p)
			.expect("reading generated cargo config")
			.parse::<DocumentMut>()
			.expect("generated cargo config is valid TOML")
	};
	let generated = leaves(&parse(&args.generated));
	let previous = args.previous.as_ref().map(|p| leaves(&parse(p))).unwrap_or_default(); // no previous run: nothing of ours to retract

	let mut doc = existing.parse::<DocumentMut>().unwrap_or_else(|e| panic!("{} is not valid TOML: {e}", args.config.display()));
	for (path, _) in previous.iter().filter(|(p, _)| !generated.iter().any(|(g, _)| g == p)) {
		remove(doc.as_table_mut(), path);
	}
	for (path, item) in generated {
		set(doc.as_table_mut(), &path, item);
	}

	let merged = doc.to_string();
	if merged != existing {
		std::fs::create_dir_all(args.config.parent().expect("config path has a parent")).expect("creating .cargo/");
		std::fs::write(&args.config, merged).expect("writing cargo config");
	}
}

fn leaves(doc: &DocumentMut) -> Vec<(Vec<String>, Item)> {
	fn walk(table: &dyn TableLike, prefix: &mut Vec<String>, out: &mut Vec<(Vec<String>, Item)>) {
		for (k, item) in table.iter() {
			prefix.push(k.to_owned());
			match item.as_table_like() {
				Some(t) => walk(t, prefix, out),
				None => out.push((prefix.clone(), item.clone())),
			}
			prefix.pop();
		}
	}
	let mut out = Vec::new();
	walk(doc.as_table(), &mut Vec::new(), &mut out);
	out
}

fn set(table: &mut dyn TableLike, path: &[String], item: Item) {
	let (last, parents) = path.split_last().expect("leaf paths are non-empty");
	let mut table = table;
	for k in parents {
		table = table
			.entry(k)
			.or_insert_with(|| {
				let mut t = Table::new();
				t.set_implicit(true);
				Item::Table(t)
			})
			.as_table_like_mut()
			.unwrap_or_else(|| panic!("`{k}` in cargo config is not a table, but v_flakes sets keys under it"));
	}
	match table.get_mut(last) {
		Some(existing) if existing.as_value().is_some() && item.as_value().is_some() => {
			let decor = existing.as_value().expect("checked above").decor().clone();
			*existing = item;
			*existing.as_value_mut().expect("checked above").decor_mut() = decor; // keep the user's spacing and trailing comment
		}
		_ => _ = table.insert(last, item), // the displaced value, if any, is the stale one being overwritten
	}
}

/// Drops tables the removal leaves empty, so a retracted section disappears whole.
fn remove(table: &mut dyn TableLike, path: &[String]) {
	let (first, rest) = path.split_first().expect("leaf paths are non-empty");
	if rest.is_empty() {
		table.remove(first);
		return;
	}
	let Some(child) = table.get_mut(first).and_then(Item::as_table_like_mut) else {
		return; // already gone by hand
	};
	remove(child, rest);
	if child.is_empty() {
		table.remove(first);
	}
}
