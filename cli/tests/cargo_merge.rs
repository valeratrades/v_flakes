#![cfg(feature = "toml")]

use v_flakes::cargo_merge::merge;

const LINTS: &str = r#"
[rust]
unused_features = "allow"
"#;

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
