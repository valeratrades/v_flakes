use std::{
	io::Write,
	process::{Command, Stdio},
};

const AWK: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../langs/rs/cargo-patch.awk");
const MERGE: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../langs/rs/cargo-config-merge.rs");

const GENERATED: &str = r#"[build]
rustc-wrapper = "sccache"

[profile.rust]
codegen-backend = "cranelift"

[target.x86_64-unknown-linux-gnu]
rustflags = ["--cfg", "tokio_unstable"]
"#;

fn clean_filter(input: &str) -> String {
	let mut child = Command::new("awk").args(["-f", AWK]).stdin(Stdio::piped()).stdout(Stdio::piped()).spawn().unwrap();
	child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
	let out = child.wait_with_output().unwrap();
	assert!(out.status.success());
	String::from_utf8(out.stdout).unwrap()
}

/// Shell entry over `on_disk`, when `previous` is what the last entry generated. Returns (disk, index).
fn regen(on_disk: Option<&str>, previous: Option<&str>, generated: &str) -> (String, String) {
	let dir = std::env::temp_dir().join(format!("vf_cargo_config_{}_{:?}", std::process::id(), std::thread::current().id()));
	std::fs::create_dir(&dir).unwrap();
	let config = dir.join("config.toml");
	let generated_path = dir.join("generated.toml");
	let previous_path = dir.join("previous.toml");
	if let Some(s) = on_disk {
		std::fs::write(&config, s).unwrap();
	}
	std::fs::write(&generated_path, generated).unwrap();
	let mut cmd = Command::new("cargo");
	cmd.args(["-Zscript", "-q", MERGE]).arg(&config).arg(&generated_path);
	if let Some(p) = previous {
		std::fs::write(&previous_path, p).unwrap();
		cmd.arg(&previous_path);
	}
	let out = cmd.output().unwrap();
	assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
	let disk = std::fs::read_to_string(&config).unwrap();
	std::fs::remove_dir_all(&dir).unwrap();
	let index = clean_filter(&disk);
	(disk, index)
}

#[track_caller]
fn check(on_disk: Option<&str>, previous: Option<&str>, generated: &str) -> String {
	let (disk, index) = regen(on_disk, previous, generated);
	format!("{disk}----- index -----\n{index}")
}

#[test]
fn fresh_checkout_gets_generated() {
	insta::assert_snapshot!(check(None, None, GENERATED), @r#"
	[build]
	rustc-wrapper = "sccache"

	[profile.rust]
	codegen-backend = "cranelift"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]
	----- index -----
	[build]
	rustc-wrapper = "sccache"

	[profile.rust]
	codegen-backend = "cranelift"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]
	"#);
}

#[test]
fn foreign_sections_and_keys_survive() {
	let on_disk = r#"# my aliases
[alias]
xx = "build"

[build]
rustc-wrapper = "edited-by-hand"
jobs = 4

[patch.crates-io]
exec_viz = { path = "../exec_viz/exec_viz" }

[patch."https://github.com/x/y"]
# pinned
b = { path = "../b" }

[env]
FOO = "1"
"#;
	insta::assert_snapshot!(check(Some(on_disk), Some(GENERATED), GENERATED), @r#"
	# my aliases
	[alias]
	xx = "build"

	[build]
	rustc-wrapper = "sccache"
	jobs = 4

	[patch.crates-io]
	exec_viz = { path = "../exec_viz/exec_viz" }

	[patch."https://github.com/x/y"]
	# pinned
	b = { path = "../b" }

	[env]
	FOO = "1"

	[profile.rust]
	codegen-backend = "cranelift"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]
	----- index -----
	# my aliases
	[alias]
	xx = "build"

	[build]
	rustc-wrapper = "sccache"
	jobs = 4
	[env]
	FOO = "1"

	[profile.rust]
	codegen-backend = "cranelift"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]
	"#);
}

#[test]
fn keys_dropped_from_generated_are_removed() {
	let generated = r#"[build]
rustc-wrapper = "sccache"

[target.x86_64-unknown-linux-gnu]
rustflags = ["--cfg", "tokio_unstable"]
"#;
	let on_disk = format!("{GENERATED}\n[profile.dev]\nopt-level = 1\n\n[patch.crates-io]\na = {{ path = \"../a\" }}\n");
	insta::assert_snapshot!(check(Some(&on_disk), Some(GENERATED), generated), @r#"
	[build]
	rustc-wrapper = "sccache"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]

	[profile.dev]
	opt-level = 1

	[patch.crates-io]
	a = { path = "../a" }
	----- index -----
	[build]
	rustc-wrapper = "sccache"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]

	[profile.dev]
	opt-level = 1
	"#);
}

#[test]
fn bare_patch_table_stays_out_of_git() {
	let on_disk = format!("{GENERATED}\n[patch]\ncrates-io.a = {{ path = \"../a\" }}\n");
	insta::assert_snapshot!(check(Some(&on_disk), Some(GENERATED), GENERATED), @r#"
	[build]
	rustc-wrapper = "sccache"

	[profile.rust]
	codegen-backend = "cranelift"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]

	[patch]
	crates-io.a = { path = "../a" }
	----- index -----
	[build]
	rustc-wrapper = "sccache"

	[profile.rust]
	codegen-backend = "cranelift"

	[target.x86_64-unknown-linux-gnu]
	rustflags = ["--cfg", "tokio_unstable"]
	"#);
}
