use std::{path::Path, process::Command};

const SCRIPT: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../langs/rs/cargo-pins.rs");

const PINS: &str = r#"
[workspace]

[workspace.dependencies]
axum = "0.8.9"
clap = "4.6.8"
insta = "1.48.0"
local = "9"
regex = "1.13.2"
serde = "1.0.229"
tokio = "1.54.1"
"#;

const ROOT: &str = r#"
[workspace]
members = ["member"]
resolver = "3"

[workspace.dependencies]
serde = { version = "1", features = ["derive"] } # kept
tokio = "1"
"#;

const MEMBER: &str = r#"
[package]
name = "member"
version = "0.1.0"
edition = "2024"

[dependencies]
tokio = { workspace = true, features = ["rt"] }
clap = { version = "4.0", default-features = false, features = ["derive"] } # why clap
web = { package = "axum", version = "0.7", optional = true }
local = { path = "../local", version = "0.1" }
gitdep = { git = "https://example.invalid/gitdep" }
anyhow = "1"

[dependencies.regex]
version = "1"
features = ["unicode"]

[target.'cfg(unix)'.dependencies]
regex = "1.5"

[dev-dependencies]
insta = "1"
"#;

#[derive(Debug)]
struct Run {
	root: String,
	member: String,
	stderr: String,
}

/// Shell entry's pin pass over a two-crate workspace.
fn pin(root: &str, member: &str, pins: &str, exclude: &[&str]) -> Result<Run, String> {
	let dir = std::env::temp_dir().join(format!("vf_cargo_pins_{}_{:?}", std::process::id(), std::thread::current().id()));
	let _ = std::fs::remove_dir_all(&dir); // a previous run's leftovers, absent normally
	for (path, content) in [
		("Cargo.toml", root),
		("member/Cargo.toml", member),
		("member/src/lib.rs", ""),
		("local/Cargo.toml", "[package]\nname = \"local\"\nversion = \"0.1.0\"\nedition = \"2024\"\n"),
		("local/src/lib.rs", ""),
		("pins.toml", pins),
	] {
		let path = dir.join(path);
		std::fs::create_dir_all(path.parent().unwrap()).unwrap();
		std::fs::write(path, content).unwrap();
	}
	let out = Command::new("cargo")
		.args(["-Zscript", "-q", SCRIPT])
		.arg(dir.join("Cargo.toml"))
		.arg(dir.join("pins.toml"))
		.args(exclude.iter().flat_map(|n| ["--exclude", n]))
		.output()
		.unwrap();
	let read = |p: &str| std::fs::read_to_string(Path::new(&dir).join(p)).unwrap();
	let run = Run {
		root: read("Cargo.toml"),
		member: read("member/Cargo.toml"),
		stderr: String::from_utf8(out.stderr).unwrap(),
	};
	std::fs::remove_dir_all(&dir).unwrap();
	if out.status.success() { Ok(run) } else { Err(run.stderr) }
}

#[test]
fn pins_registry_deps_only() {
	let run = pin(ROOT, MEMBER, PINS, &[]).unwrap();
	assert_eq!(
		run.root,
		r#"
[workspace]
members = ["member"]
resolver = "3"

[workspace.dependencies]
serde = { version = "1.0.229", features = ["derive"] } # kept
tokio = "1.54.1"
"#
	);
	assert_eq!(
		run.member,
		r#"
[package]
name = "member"
version = "0.1.0"
edition = "2024"

[dependencies]
tokio = { workspace = true, features = ["rt"] }
clap = { version = "4.6.8", default-features = false, features = ["derive"] } # why clap
web = { package = "axum", version = "0.8.9", optional = true }
local = { path = "../local", version = "0.1" }
gitdep = { git = "https://example.invalid/gitdep" }
anyhow = "1"

[dependencies.regex]
version = "1.13.2"
features = ["unicode"]

[target.'cfg(unix)'.dependencies]
regex = "1.13.2"

[dev-dependencies]
insta = "1.48.0"
"#
	);
	assert_eq!(
		run.stderr,
		"v_flakes pins: Cargo.toml serde 1 → 1.0.229
v_flakes pins: Cargo.toml tokio 1 → 1.54.1
v_flakes pins: member/Cargo.toml clap 4.0 → 4.6.8
v_flakes pins: member/Cargo.toml axum 0.7 → 0.8.9
v_flakes pins: member/Cargo.toml regex 1 → 1.13.2
v_flakes pins: member/Cargo.toml regex 1.5 → 1.13.2
v_flakes pins: member/Cargo.toml insta 1 → 1.48.0
"
	);
}

#[test]
fn second_pass_is_silent() {
	let first = pin(ROOT, MEMBER, PINS, &[]).unwrap();
	let second = pin(&first.root, &first.member, PINS, &[]).unwrap();
	assert_eq!((second.root, second.member, second.stderr.as_str()), (first.root, first.member, ""));
}

#[test]
fn table_pin_is_rejected() {
	let pins = "[workspace]\n\n[workspace.dependencies]\ntokio = { version = \"1\", features = [\"full\"] }\n";
	let err = pin(ROOT, MEMBER, pins, &[]).unwrap_err();
	assert!(err.contains("tokio"), "{err}");
}

#[test]
fn excluded_crate_keeps_its_requirement() {
	let run = pin(ROOT, MEMBER, PINS, &["tokio", "regex"]).unwrap();
	assert!(run.root.contains("tokio = \"1\"\n"), "{}", run.root);
	assert!(run.member.contains("version = \"1\"\nfeatures = [\"unicode\"]"), "{}", run.member);
	assert!(run.member.contains("regex = \"1.5\""), "{}", run.member);
	assert!(!run.stderr.contains("tokio"), "{}", run.stderr);
	assert!(!run.stderr.contains("regex"), "{}", run.stderr);
}

#[test]
fn excluding_an_unpinned_crate_is_rejected() {
	let err = pin(ROOT, MEMBER, PINS, &["anyhow"]).unwrap_err();
	assert!(err.contains("anyhow"), "{err}");
}
