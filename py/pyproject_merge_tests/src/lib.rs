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
