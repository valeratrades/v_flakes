use v_fixtures::Fixture;
use v_flakes::pyproject_merge::merge;

fn run(fixture_str: &str) -> String {
	let fixture = Fixture::parse(fixture_str);
	let temp = fixture.write_to_tempdir();
	let path = temp.path("/pyproject.toml");
	let original = std::fs::read_to_string(&path).unwrap();
	let result = merge(&original, ".devenv/state/venv", "py_src");
	result
}

#[test]
fn preserves_non_controlled_sections() {
	let result = run(r#"
		//- /pyproject.toml
		[build-system]
		requires = ["maturin>=1.7"]
		build-backend = "maturin"

		[tool.maturin]
		python-source = "py_src"

		[project]
		name = "my-project"
		version = "0.1.0"

		[dependency-groups]
		dev = ["pytest>=8.0"]
	"#);

	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert!(doc.get("build-system").is_some());
	assert!(doc["tool"].get("maturin").is_some());
	assert!(doc.get("project").is_some());
	assert!(doc.get("dependency-groups").is_some());
}

#[test]
fn inserts_controlled_sections_when_absent() {
	let result = run(r#"
		//- /pyproject.toml
		[build-system]
		requires = ["setuptools>=75.0"]
		build-backend = "setuptools.backends._legacy:_Backend"
	"#);

	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["tool"]["pytest"]["ini_options"]["typeguard-packages"].as_str().unwrap(), "py_src");
	assert_eq!(doc["tool"]["ty"]["environment"]["python"].as_str().unwrap(), ".devenv/state/venv");
	assert_eq!(doc["tool"]["ty"]["environment"]["extra-paths"][0].as_str().unwrap(), "py_src");
	assert_eq!(doc["tool"]["inline-snapshot"]["format-command"].as_str().unwrap(), "ruff format --stdin-filename {filename}");
}

#[test]
fn overwrites_stale_controlled_values() {
	let result = run(r#"
		//- /pyproject.toml
		[tool.pytest.ini_options]
		typeguard-packages = "old_src"

		[tool.ty.environment]
		python = "/old/venv"
		extra-paths = ["old_src"]

		[tool.inline-snapshot]
		format-command = "black {filename}"
	"#);

	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["tool"]["pytest"]["ini_options"]["typeguard-packages"].as_str().unwrap(), "py_src");
	assert_eq!(doc["tool"]["ty"]["environment"]["python"].as_str().unwrap(), ".devenv/state/venv");
	assert_eq!(doc["tool"]["inline-snapshot"]["format-command"].as_str().unwrap(), "ruff format --stdin-filename {filename}");
}

#[test]
fn idempotent() {
	let fixture_str = r#"
		//- /pyproject.toml
		[build-system]
		requires = ["maturin>=1.7"]
		build-backend = "maturin"

		[tool.maturin]
		python-source = "py_src"

		[project]
		name = "robot-master-py"
		dependencies = ["typeguard>=4.4"]

		[dependency-groups]
		dev = ["pytest>=8.0", "inline-snapshot>=0.19", "ruff>=0.9"]
		train = ["torch>=2.0", "numpy"]

		[tool.inline-snapshot]
		format-command = "ruff format --stdin-filename {filename}"

		[tool.pytest.ini_options]
		typeguard-packages = "py_src"

		[tool.ty.environment]
		extra-paths = ["py_src"]
		python = ".devenv/state/venv"
	"#;

	let first = run(fixture_str);
	let second = merge(&first, ".devenv/state/venv", "py_src");
	assert_eq!(first, second, "merge is not idempotent");
}

#[test]
fn sections_and_keys_sorted_alphabetically() {
	let result = run(r#"
		//- /pyproject.toml
		[tool.pytest.ini_options]
		typeguard-packages = "py_src"

		[build-system]
		requires = ["maturin>=1.7"]
		build-backend = "maturin"

		[tool.maturin]
		python-source = "py_src"
		manifest-path = "robot_master/Cargo.toml"

		[project]
		name = "foo"

		[dependency-groups]
		dev = ["pytest"]
	"#);

	let sections: Vec<&str> = result.lines().filter(|l| l.starts_with('[')).collect();
	let mut expected = sections.clone();
	expected.sort();
	assert_eq!(sections, expected, "sections not in alphabetical order:\n{result}");
}

#[test]
fn no_write_when_unchanged() {
	let input = merge("", ".devenv/state/venv", "py_src");
	insta::assert_snapshot!(merge(&input, ".devenv/state/venv", "py_src"), @r#"
	[tool]

	[tool.inline-snapshot]
	format-command = "ruff format --stdin-filename {filename}"

	[tool.pytest.ini_options]
	testpaths = ["py_src"]
	typeguard-packages = "py_src"

	[tool.ty.environment]
	extra-paths = ["py_src"]
	python = ".devenv/state/venv"
	"#);
}
