#![cfg(feature = "cli")]

use std::{fs, os::unix::fs::PermissionsExt, path::Path, process::Command};

/// Runs `v_flakes org sync acme` against a stub `gh` serving `remote` as the schema; returns (stdout, PATCH body).
fn sync(test: &str, remote: &str) -> (String, Option<String>) {
	let dir = Path::new(env!("CARGO_TARGET_TMPDIR")).join(format!("org_sync_{test}"));
	let _ = fs::remove_dir_all(&dir); // leftover from an aborted run
	fs::create_dir_all(&dir).unwrap();
	fs::write(dir.join("schema.json"), remote).unwrap();
	let stub = dir.join("gh");
	fs::write(
		&stub,
		format!(
			"#!/bin/sh\ncase \"$*\" in\n  *PATCH*) cat > {d}/patch.json ;;\n  'api /orgs/acme/properties/schema') cat {d}/schema.json ;;\n  *) echo \"unexpected: $*\" >&2; exit 1 ;;\nesac\n",
			d = dir.display()
		),
	)
	.unwrap();
	fs::set_permissions(&stub, fs::Permissions::from_mode(0o755)).unwrap();

	let out = Command::new(env!("CARGO_BIN_EXE_v_flakes"))
		.args(["org", "sync", "acme"])
		.env("PATH", format!("{}:{}", dir.display(), std::env::var("PATH").unwrap()))
		.output()
		.unwrap();
	assert!(out.status.success(), "{}", String::from_utf8_lossy(&out.stderr));
	let patch = fs::read_to_string(dir.join("patch.json")).ok(); // absent = no PATCH was sent
	fs::remove_dir_all(&dir).unwrap();
	(String::from_utf8(out.stdout).unwrap(), patch)
}

fn spec() -> String {
	include_str!("../github/org_properties.json").to_owned()
}

#[test]
fn creates_missing() {
	insta::assert_debug_snapshot!(sync("creates_missing", "[]"), @r#"
	(
	    "+ pr_auto_review\nacme: updated 1 property\n",
	    Some(
	        "{\"properties\":[{\"default_value\":null,\"description\":\"Claude reviews every PR (v_flakes claude-code-review.yml)\",\"property_name\":\"pr_auto_review\",\"required\":false,\"value_type\":\"true_false\",\"values_editable_by\":\"org_and_repo_actors\"}]}",
	    ),
	)
	"#);
}

#[test]
fn patches_only_differing() {
	let remote = spec().replace("\"org_and_repo_actors\"", "\"org_actors\"");
	insta::assert_debug_snapshot!(sync("patches_only_differing", &remote), @r#"
	(
	    "~ pr_auto_review.values_editable_by: \"org_actors\" -> \"org_and_repo_actors\"\nacme: updated 1 property\n",
	    Some(
	        "{\"properties\":[{\"default_value\":null,\"description\":\"Claude reviews every PR (v_flakes claude-code-review.yml)\",\"property_name\":\"pr_auto_review\",\"required\":false,\"value_type\":\"true_false\",\"values_editable_by\":\"org_and_repo_actors\"}]}",
	    ),
	)
	"#);
}

#[test]
fn foreign_warns_without_patch() {
	let mut remote: Vec<serde_json::Value> = serde_json::from_str(&spec()).unwrap();
	remote.push(serde_json::json!({ "property_name": "team", "value_type": "string" }));
	insta::assert_debug_snapshot!(sync("foreign_warns_without_patch", &serde_json::to_string(&remote).unwrap()), @r#"
	(
	    "warn: acme defines `team`, which v_flakes does not own\nacme: up to date\n",
	    None,
	)
	"#);
}

#[test]
fn converged_is_noop() {
	insta::assert_debug_snapshot!(sync("converged_is_noop", &spec()), @r#"
	(
	    "acme: up to date\n",
	    None,
	)
	"#);
}
