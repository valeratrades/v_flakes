use std::process::Command;

const SCRIPT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../langs/rs/cargo-merge.rs");

const LINTS: &str = r#"
[rust]
unused_features = "allow"
"#;

const REPO: &str = "https://github.com/acme/foo";

/// Shell entry's merge of `lints` (and the `origin`-derived `repository`, if any) into `cargo`.
fn merge_with(cargo: &str, lints: &str, repository: Option<&str>) -> String {
	let dir = std::env::temp_dir().join(format!("vf_cargo_merge_{}_{:?}", std::process::id(), std::thread::current().id()));
	std::fs::create_dir(&dir).unwrap();
	let (manifest, lints_path) = (dir.join("Cargo.toml"), dir.join("lints.toml"));
	std::fs::write(&manifest, cargo).unwrap();
	std::fs::write(&lints_path, lints).unwrap();
	let mut cmd = Command::new("cargo");
	cmd.args(["-Zscript", "-q", SCRIPT]).arg(&manifest).arg(&lints_path);
	if let Some(r) = repository {
		cmd.args(["--repository", r]);
	}
	let out = cmd.output().unwrap();
	assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
	let merged = std::fs::read_to_string(&manifest).unwrap();
	std::fs::remove_dir_all(&dir).unwrap();
	merged
}

fn merge(cargo: &str, lints: &str) -> String {
	merge_with(cargo, lints, None)
}

#[test]
fn writes_to_lints_rust_for_package() {
	let cargo = r#"
[package]
name = "foo"
version = "0.1.0"

[dependencies]
serde = "1"
"#;

	let result = merge(cargo, LINTS);
	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["lints"]["rust"]["unused_features"].as_str().unwrap(), "allow");
	assert!(doc.get("workspace").is_none(), "must not introduce a [workspace] for a plain package");
}

#[test]
fn writes_to_workspace_lints_rust_for_workspace() {
	let cargo = r#"
[workspace]
members = ["crates/*"]
resolver = "2"
"#;

	let result = merge(cargo, LINTS);
	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["workspace"]["lints"]["rust"]["unused_features"].as_str().unwrap(), "allow");
	assert!(doc.get("lints").is_none(), "must not write top-level [lints] when a workspace exists");
}

#[test]
fn workspace_takes_precedence_when_both_workspace_and_package_present() {
	// A virtual-manifest-less workspace root with a package is valid Cargo; the user said workspace lints
	// always win for inheritance, so we always target [workspace.lints.*] when [workspace] is present.
	let cargo = r#"
[workspace]
members = []

[package]
name = "root"
version = "0.1.0"
"#;

	let result = merge(cargo, LINTS);
	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["workspace"]["lints"]["rust"]["unused_features"].as_str().unwrap(), "allow");
	assert!(doc.get("lints").is_none());
}

#[test]
fn preserves_other_sections() {
	let cargo = r#"
[package]
name = "foo"
version = "0.1.0"

[lints.clippy]
float_cmp = "allow"

[dependencies]
serde = "1"
"#;

	let result = merge(cargo, LINTS);
	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["lints"]["clippy"]["float_cmp"].as_str().unwrap(), "allow");
	assert_eq!(doc["lints"]["rust"]["unused_features"].as_str().unwrap(), "allow");
	assert!(doc.get("dependencies").is_some());
	assert_eq!(doc["package"]["name"].as_str().unwrap(), "foo");
}

#[test]
fn overwrites_stale_controlled_values() {
	let cargo = r#"
[package]
name = "foo"
version = "0.1.0"

[lints.rust]
unused_features = "warn"
some_old_key = "deny"
"#;

	let result = merge(cargo, LINTS);
	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["lints"]["rust"]["unused_features"].as_str().unwrap(), "allow");
	// Fully managed: stale entries get dropped.
	assert!(doc["lints"]["rust"].get("some_old_key").is_none());
}

#[test]
fn idempotent() {
	let cargo = r#"
[package]
name = "foo"
version = "0.1.0"

[dependencies]
serde = "1"
"#;
	let first = merge(cargo, LINTS);
	let second = merge(&first, LINTS);
	assert_eq!(first, second);
}

#[test]
fn idempotent_workspace() {
	let cargo = r#"
[workspace]
members = ["a", "b"]
resolver = "2"
"#;
	let first = merge(cargo, LINTS);
	let second = merge(&first, LINTS);
	assert_eq!(first, second);
}

#[test]
fn extra_lints_from_extend_propagate() {
	let lints = r#"
[rust]
unused_features = "allow"
unused_imports = "warn"
"#;
	let cargo = r#"
[package]
name = "foo"
version = "0.1.0"
"#;
	let result = merge(cargo, lints);
	let doc: toml_edit::DocumentMut = result.parse().unwrap();
	assert_eq!(doc["lints"]["rust"]["unused_features"].as_str().unwrap(), "allow");
	assert_eq!(doc["lints"]["rust"]["unused_imports"].as_str().unwrap(), "warn");
}

#[test]
fn repository_from_origin_for_package() {
	let cargo = r#"
[package]
name = "foo"
version = "0.1.0"
"#;
	let doc: toml_edit::DocumentMut = merge_with(cargo, LINTS, Some(REPO)).parse().unwrap();
	assert_eq!(doc["package"]["repository"].as_str().unwrap(), REPO);
}

#[test]
fn repository_from_origin_for_workspace() {
	let cargo = r#"
[workspace]
members = ["crates/*"]

[workspace.package]
edition = "2024"
"#;
	let doc: toml_edit::DocumentMut = merge_with(cargo, LINTS, Some(REPO)).parse().unwrap();
	assert_eq!(doc["workspace"]["package"]["repository"].as_str().unwrap(), REPO);
	assert_eq!(doc["workspace"]["package"]["edition"].as_str().unwrap(), "2024");
	assert!(doc.get("package").is_none(), "must not introduce a root [package]");
}

#[test]
fn repository_overwrites_stale_but_keeps_workspace_inheritance() {
	let stale = r#"
[package]
name = "foo"
version = "0.1.0"
repository = "https://github.com/old-owner/foo"
"#;
	let doc: toml_edit::DocumentMut = merge_with(stale, LINTS, Some(REPO)).parse().unwrap();
	assert_eq!(doc["package"]["repository"].as_str().unwrap(), REPO);

	let inherits = r#"
[workspace]
members = []

[package]
name = "root"
version = "0.1.0"
repository.workspace = true
"#;
	let doc: toml_edit::DocumentMut = merge_with(inherits, LINTS, Some(REPO)).parse().unwrap();
	assert_eq!(doc["workspace"]["package"]["repository"].as_str().unwrap(), REPO);
	assert!(doc["package"]["repository"]["workspace"].as_bool().unwrap());
}

#[test]
fn repository_untouched_without_origin() {
	let cargo = r#"
[package]
name = "foo"
version = "0.1.0"
repository = "https://github.com/hand/written"
"#;
	let doc: toml_edit::DocumentMut = merge_with(cargo, LINTS, None).parse().unwrap();
	assert_eq!(doc["package"]["repository"].as_str().unwrap(), "https://github.com/hand/written");
}
