use std::path::PathBuf;

use toml_edit::{DocumentMut, Item, Table, value};

#[derive(clap::Args)]
pub struct Cli {
	pub path: PathBuf,
	pub venv_path: String,
	pub src_path: String,
}

pub fn run(args: Cli) {
	let existing = if args.path.exists() {
		std::fs::read_to_string(&args.path).expect("reading pyproject.toml")
	} else {
		format!(
			"[build-system]\nrequires = [\"setuptools>=75.0\"]\nbuild-backend = \"setuptools.backends._legacy:_Backend\"\n\n[tool.setuptools.packages.find]\nwhere = [\"{src_path}\"]\n",
			src_path = args.src_path
		)
	};

	let merged = merge(&existing, &args.venv_path, &args.src_path);

	if merged != existing {
		std::fs::write(&args.path, &merged).expect("writing pyproject.toml");
	}
}

fn sort_table(table: &mut Table) {
	table.sort_values();
	for (_, v) in table.iter_mut() {
		if let Some(t) = v.as_table_mut() {
			sort_table(t);
		}
	}
}

fn reassign_positions(table: &mut Table, counter: &mut isize) {
	table.set_position(Some(*counter));
	*counter += 1;
	for (_, v) in table.iter_mut() {
		if let Some(t) = v.as_table_mut() {
			reassign_positions(t, counter);
		}
	}
}

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
		{
			let mut arr = toml_edit::Array::new();
			arr.push(src_path);
			ini.insert("testpaths", value(arr));
		}
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

	sort_table(doc.as_table_mut());
	reassign_positions(doc.as_table_mut(), &mut 0isize);

	doc.to_string()
}
