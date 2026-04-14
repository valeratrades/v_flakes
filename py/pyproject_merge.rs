#!/home/v/nix/home/scripts/nix-run-cached
---cargo
[package]
edition = "2024"

[dependencies]
toml_edit = "0.22"
---

use std::path::Path;
use toml_edit::{DocumentMut, Item, Table, value};

pub fn merge(content: &str, venv_path: &str, src_path: &str) -> String {
	let mut doc = content.parse::<DocumentMut>().expect("valid TOML");

	if let Some(tool) = doc.get_mut("tool").and_then(|t| t.as_table_mut()) {
		tool.remove("pytest");
		tool.remove("ty");
		tool.remove("inline-snapshot");
	}

	let tool = doc.entry("tool").or_insert_with(|| Item::Table(Table::new())).as_table_mut().expect("inserted above");

	{
		let mut pytest = Table::new();
		pytest.set_implicit(true);
		let mut ini = Table::new();
		ini.insert("typeguard-packages", value(src_path));
		pytest.insert("ini_options", Item::Table(ini));
		tool.insert("pytest", Item::Table(pytest));
	}
	{
		let mut ty = Table::new();
		ty.set_implicit(true);
		let mut env = Table::new();
		env.insert("python", value(venv_path));
		let mut extra_paths = toml_edit::Array::new();
		extra_paths.push(src_path);
		env.insert("extra-paths", value(extra_paths));
		ty.insert("environment", Item::Table(env));
		tool.insert("ty", Item::Table(ty));
	}
	{
		let mut snap = Table::new();
		snap.insert("format-command", value("ruff format --stdin-filename {filename}"));
		tool.insert("inline-snapshot", Item::Table(snap));
	}

	doc.to_string()
}

fn main() {
	let args: Vec<String> = std::env::args().collect();
	if args.len() != 4 {
		eprintln!("Usage: {} <pyproject.toml> <venv_path> <src_path>", args[0]);
		std::process::exit(1);
	}
	let path = Path::new(&args[1]);
	let venv_path = &args[2];
	let src_path = &args[3];

	let existing = if path.exists() {
		std::fs::read_to_string(path).expect("reading pyproject.toml")
	} else {
		format!(
			"[build-system]\nrequires = [\"setuptools>=75.0\"]\nbuild-backend = \"setuptools.backends._legacy:_Backend\"\n\n[tool.setuptools.packages.find]\nwhere = [\"{src_path}\"]\n"
		)
	};

	let merged = merge(&existing, venv_path, src_path);

	if merged != existing {
		std::fs::write(path, &merged).expect("writing pyproject.toml");
	}
}
