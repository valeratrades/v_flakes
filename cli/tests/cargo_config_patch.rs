use std::{
	io::Write,
	process::{Command, Stdio},
};

const AWK: &str = concat!(env!("CARGO_MANIFEST_DIR"), "/../langs/rs/cargo-patch.awk");

fn awk(keep: bool, input: &str) -> String {
	let mut child = Command::new("awk")
		.args(["-v", &format!("keep={}", keep as u8), "-f", AWK])
		.stdin(Stdio::piped())
		.stdout(Stdio::piped())
		.spawn()
		.unwrap();
	child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
	let out = child.wait_with_output().unwrap();
	assert!(out.status.success());
	String::from_utf8(out.stdout).unwrap()
}

/// `generated ++ patch` is what shell entry leaves on disk: git must see `generated`, regen must keep `patch`.
#[track_caller]
fn check(generated: &str, patch: &str) {
	let working = format!("{generated}{patch}");
	assert_eq!(awk(false, &working), generated, "clean filter");
	assert_eq!(awk(true, &working), patch, "regen");
}

#[test]
fn local_patch_survives_regen_and_stays_out_of_git() {
	let generated = "[build]\nrustc-wrapper = \"sccache\"\n\n[target.x86_64-unknown-linux-gnu]\nrustflags = [\"--cfg\", \"tokio_unstable\"]\n";
	check(generated, "");
	check(generated, "\n[patch.crates-io]\nexec_viz = { path = \"../exec_viz/exec_viz\" }\n");
	check(
		generated,
		"\n# local dev\n[patch.crates-io]\na = { path = \"../a\" }\n\n[patch.\"https://github.com/x/y\"]\n# pinned\nb = { path = \"../b\" }\n",
	);
}
