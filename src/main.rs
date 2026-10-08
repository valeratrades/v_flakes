use std::{
	io::Write,
	process::{Command, ExitCode, Stdio},
};

use clap::{Parser, Subcommand};
use serde_json::{Map, Value};

const SPEC: &str = include_str!("../github/org_properties.json");

#[derive(Parser)]
#[command(version = concat!(env!("CARGO_PKG_VERSION"), " (", env!("GIT_HASH"), ")"))]
struct Cli {
	#[command(subcommand)]
	command: Commands,
}

#[derive(Subcommand)]
enum Commands {
	#[command(subcommand)]
	Org(OrgCommands),
}

#[derive(Subcommand)]
enum OrgCommands {
	/// Converge the org's custom property definitions to the set v_flakes defines
	Sync { org: String },
}

fn main() -> ExitCode {
	match Cli::parse().command {
		Commands::Org(OrgCommands::Sync { org }) => match org_sync(&org) {
			Ok(()) => ExitCode::SUCCESS,
			Err(e) => {
				eprintln!("error: {e}");
				ExitCode::FAILURE
			}
		},
	}
}

fn org_sync(org: &str) -> Result<(), String> {
	let spec: Vec<Map<String, Value>> = serde_json::from_str(SPEC).expect("embedded spec is checked by tests/org_sync.rs");
	let endpoint = format!("/orgs/{org}/properties/schema");
	let remote: Vec<Map<String, Value>> = serde_json::from_slice(&gh(&["api", &endpoint], None)?).map_err(|e| format!("parsing {endpoint}: {e}"))?;

	let name = |p: &Map<String, Value>| p["property_name"].as_str().expect("property_name is a string").to_owned();
	let mut upserts = Vec::new();
	for want in &spec {
		let n = name(want);
		match remote.iter().find(|r| name(r) == n) {
			None => {
				println!("+ {n}");
				upserts.push(want);
			}
			Some(have) => {
				let diffs: Vec<_> = want.iter().filter(|(k, v)| have.get(*k).unwrap_or(&Value::Null) != *v).collect();
				for (k, v) in &diffs {
					println!("~ {n}.{k}: {} -> {v}", have.get(*k).unwrap_or(&Value::Null));
				}
				if !diffs.is_empty() {
					upserts.push(want);
				}
			}
		}
	}
	for r in &remote {
		let n = name(r);
		if !spec.iter().any(|s| name(s) == n) {
			println!("warn: {org} defines `{n}`, which v_flakes does not own");
		}
	}

	if upserts.is_empty() {
		println!("{org}: up to date");
		return Ok(());
	}
	let body = serde_json::json!({ "properties": upserts }).to_string();
	gh(&["api", "-X", "PATCH", &endpoint, "--input", "-"], Some(&body))?;
	println!("{org}: updated {} propert{}", upserts.len(), if upserts.len() == 1 { "y" } else { "ies" });
	Ok(())
}

fn gh(args: &[&str], stdin: Option<&str>) -> Result<Vec<u8>, String> {
	// gh must never prompt (see github/git-ops.rs)
	let mut child = Command::new("gh")
		.args(args)
		.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
		.stdout(Stdio::piped())
		.stderr(Stdio::piped())
		.spawn()
		.map_err(|e| format!("spawning gh: {e}"))?;
	if let Some(input) = stdin {
		child.stdin.take().expect("piped above").write_all(input.as_bytes()).map_err(|e| format!("writing to gh: {e}"))?;
	}
	let out = child.wait_with_output().map_err(|e| format!("waiting on gh: {e}"))?;
	if !out.status.success() {
		return Err(format!("gh {} failed: {}", args.join(" "), String::from_utf8_lossy(&out.stderr).trim()));
	}
	Ok(out.stdout)
}
