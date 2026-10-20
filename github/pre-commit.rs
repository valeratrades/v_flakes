#!/usr/bin/env -S cargo -Zscript -q
---cargo
[package]
edition = "2024"
---

//! Body of `.git/hooks/custom.sh`. Steps run in phases; steps of one phase run concurrently,
//! each one's output held until the phase ends so groups don't interleave.

use std::{
	env, fs,
	os::unix::process::CommandExt as _,
	path::{Path, PathBuf},
	process::{Command, ExitCode, Stdio},
	thread,
};

#[derive(Clone, Copy, Debug)]
enum Style {
	/// auto-fix, unfixable violations don't fail
	Format,
	/// auto-fix, unfixable violations fail
	FormatStrict,
	Assert,
}

#[derive(Debug)]
struct Config {
	pname: String,
	semver_checks: bool,
	tracey_check: bool,
	style: Option<Style>,
	module_flags: Vec<String>,
	exclude_dirs: Vec<String>,
	js_visual: bool,
	git_ops: Option<String>,
	codestyle_install: Option<String>,
}

impl Config {
	fn from_args() -> Self {
		let mut pname = None;
		let (mut semver_checks, mut tracey_check, mut js_visual) = (false, false, false);
		let (mut style_format, mut style_assert) = (false, false);
		let (mut module_flags, mut exclude_dirs) = (Vec::new(), Vec::new());
		let (mut git_ops, mut codestyle_install) = (None, None);
		let mut args = env::args().skip(1);
		while let Some(arg) = args.next() {
			let mut value = || args.next().unwrap_or_else(|| panic!("{arg} takes a value"));
			match arg.as_str() {
				"--pname" => pname = Some(value()),
				"--semver-checks" => semver_checks = true,
				"--tracey-check" => tracey_check = true,
				"--style-format" => style_format = true,
				"--style-assert" => style_assert = true,
				"--module-flags" => module_flags = value().split_whitespace().map(String::from).collect(),
				"--exclude-dir" => exclude_dirs.push(value()),
				"--js-visual" => js_visual = true,
				"--git-ops" => git_ops = Some(value()),
				"--codestyle-install" => codestyle_install = Some(value()),
				_ => panic!("unknown argument: {arg}"),
			}
		}
		let style = match (style_format, style_assert) {
			(true, true) => Some(Style::FormatStrict),
			(true, false) => Some(Style::Format),
			(false, true) => Some(Style::Assert),
			(false, false) => None,
		};
		Self {
			pname: pname.expect("--pname is always passed by pre_commit.nix"),
			semver_checks,
			tracey_check,
			style,
			module_flags,
			exclude_dirs,
			js_visual,
			git_ops,
			codestyle_install,
		}
	}

	fn is_excluded(&self, path: &Path) -> bool {
		self.exclude_dirs.iter().any(|d| path.starts_with(Path::new(".").join(d)))
	}
}

/// Output of one step, printed whole when its phase ends.
#[derive(Debug, Default)]
struct Log(String);

impl Log {
	fn line(&mut self, s: impl AsRef<str>) {
		self.0.push_str(s.as_ref());
		self.0.push('\n');
	}

	/// Runs to completion, capturing stdout and stderr.
	fn run(&mut self, cmd: &mut Command) -> bool {
		let out = cmd.output().unwrap_or_else(|e| panic!("spawn {cmd:?}: {e}"));
		self.0.push_str(&String::from_utf8_lossy(&out.stdout));
		self.0.push_str(&String::from_utf8_lossy(&out.stderr));
		out.status.success()
	}

	/// Optional tools warn loudly (not silently no-op) when absent, so a missing
	/// `cargo install` isn't mistaken for a clean sort.
	fn require_tool(&mut self, name: &str, install: &str) -> bool {
		let found = env::var_os("PATH").is_some_and(|p| env::split_paths(&p).any(|d| d.join(name).is_file()));
		if !found {
			self.line(format!("⚠ pre-commit: {name} not installed — skipping its step (install: {install})"));
		}
		found
	}
}

type Step<'a> = Box<dyn FnOnce(&mut Log) -> bool + Send + 'a>;

/// Runs `steps` concurrently. Exits the hook if any failed, after printing all of them.
fn phase(steps: Vec<Step<'_>>) {
	let results: Vec<(Log, bool)> = thread::scope(|s| {
		let handles: Vec<_> = steps
			.into_iter()
			.map(|step| {
				s.spawn(|| {
					let mut log = Log::default();
					let ok = step(&mut log);
					(log, ok)
				})
			})
			.collect();
		handles.into_iter().map(|h| h.join().expect("steps don't panic")).collect()
	});
	let mut failed = false;
	for (log, ok) in results {
		print!("{}", log.0);
		failed |= !ok;
	}
	if failed {
		std::process::exit(1);
	}
}

fn walk(dir: &Path, cfg: &Config, out: &mut Vec<PathBuf>, keep: &dyn Fn(&Path) -> bool) {
	for entry in fs::read_dir(dir).unwrap_or_else(|e| panic!("read_dir {}: {e}", dir.display())) {
		let path = entry.expect("dir entry readable").path();
		if cfg.is_excluded(&path) {
			continue;
		}
		if path.is_dir() {
			walk(&path, cfg, out, keep);
		} else if keep(&path) {
			out.push(path);
		}
	}
}

fn copy_config(cfg: &Config, log: &mut Log) -> bool {
	let config = home().join(".config");
	let nix = config.join(format!("{}.nix", cfg.pname));
	let toml = config.join(format!("{}.toml", cfg.pname));
	let dir = config.join(&cfg.pname);
	// .nix takes priority over .toml
	if nix.is_file() {
		log.line("Copying project's nix config to examples/");
		fs::create_dir_all("examples").expect("create examples/");
		fs::copy(&nix, "examples/config.nix").expect("copy nix config");
	} else if toml.is_file() || dir.is_dir() {
		log.line("Copying project's toml config to examples/");
		fs::create_dir_all("examples").expect("create examples/");
		if toml.is_file() {
			fs::copy(&toml, "examples/config.toml").expect("copy toml config");
		} else if !Path::new("examples/config").is_dir() && !log.run(Command::new("cp").arg("-r").arg(&dir).arg("examples/config")) {
			return false;
		}
	} else {
		return true;
	}
	if !log.run(Command::new("git").args(["add", "examples/"])) {
		log.line("Failed to copy project's config to examples");
		return false;
	}
	true
}

fn home() -> PathBuf {
	PathBuf::from(env::var_os("HOME").expect("HOME is set in a git hook"))
}

fn sort_manifests(log: &mut Log) -> bool {
	if log.require_tool("cargo-sort", "cargo install cargo-sort") {
		let mut sort_log = Log::default();
		if !sort_log.run(Command::new("cargo").args(["sort", "--workspace", "--grouped"])) {
			log.0.push_str(&sort_log.0);
			return false;
		}
		let rewritten: Vec<&str> = sort_log
			.0
			.lines()
			.filter_map(|l| l.split_once("Cargo.toml for ")?.1.split_once(" has been rewritten").map(|(name, _)| name.trim_matches('"')))
			.collect();
		if !rewritten.is_empty() {
			log.line("# cargo-sorted:");
			for name in rewritten {
				log.line(format!("\trewrote Cargo.toml for \"{name}\""));
			}
		}
	}
	let workspace = fs::read_to_string("Cargo.toml")
		.expect("guarded by Cargo.toml existing")
		.lines()
		.any(|l| l.starts_with("[workspace]"));
	if workspace && log.require_tool("cargo-autoinherit", "cargo install cargo-autoinherit") {
		return log.run(Command::new("cargo").arg("autoinherit"));
	}
	true
}

fn sort_derives(cfg: &Config, log: &mut Log) -> bool {
	if !log.require_tool("cargo-sort-derives", "nix profile install github:valeratrades/v_flakes#cargo-sort-derives") {
		return true;
	}
	// Upstream's cargo-sort-derives ignores unknown config keys, so an unpatched binary would
	// sort qualified derives mid-list, silently, while CI (which runs the patched build)
	// rejects it. Fail here instead, where the fix is obvious.
	if fs::read_to_string(".sort-derives.toml").is_ok_and(|s| s.contains("qualified_last")) {
		let help = Command::new("cargo").args(["sort-derives", "--help"]).output().expect("spawn cargo sort-derives --help");
		if !String::from_utf8_lossy(&help.stdout).contains("--qualified-last") {
			log.line("pre-commit: .sort-derives.toml sets qualified_last but cargo-sort-derives on PATH does not support it");
			log.line("  install the patched build: nix profile install github:valeratrades/v_flakes#cargo-sort-derives");
			return false;
		}
	}
	if cfg.exclude_dirs.is_empty() {
		return log.run(Command::new("cargo").arg("sort-derives"));
	}
	// sort-derives has no native --exclude flag
	let mut files = Vec::new();
	walk(Path::new("."), cfg, &mut files, &|p| p.extension().is_some_and(|e| e == "rs"));
	files.iter().all(|f| log.run(Command::new("cargo").args(["sort-derives", "--path"]).arg(f)))
}

fn patched_manifests(cfg: &Config) {
	let mut manifests = Vec::new();
	walk(Path::new("."), cfg, &mut manifests, &|p| {
		p.file_name().is_some_and(|n| n == "Cargo.toml") && !p.starts_with("./target") && fs::read_to_string(p).is_ok_and(|s| s.lines().any(|l| l.starts_with("[patch.crates-io]")))
	});
	if !manifests.is_empty() {
		println!("WARNING: [patch.crates-io] section present in:");
		for m in manifests {
			println!("\t{}", m.strip_prefix("./").expect("walked from .").display());
		}
	}
}

fn codestyle(cfg: &Config, style: Style, path: &std::ffi::OsStr) -> bool {
	let action = match style {
		Style::Format | Style::FormatStrict => "format",
		Style::Assert => "assert",
	};
	let mut cmd = Command::new("codestyle");
	cmd.env("PATH", path);
	for d in &cfg.exclude_dirs {
		cmd.args(["--exclude", d]); // a top-level arg, so before the `rust` subcommand
	}
	cmd.arg("rust").args(&cfg.module_flags).args([action, "./"]);
	let target = match cfg.exclude_dirs.is_empty() {
		true => "./".to_string(),
		false => format!("./ (excluding: {})", cfg.exclude_dirs.join(", ")),
	};
	println!("Running: codestyle {action} {target}");
	let ok = cmd.status().expect("spawn codestyle").success();
	match style {
		Style::Format => true,
		Style::FormatStrict | Style::Assert if !ok => {
			println!("codestyle: unfixable violations found");
			false
		}
		_ => true,
	}
}

fn js_visual(log: &mut Log) -> bool {
	let Some(dir) = [".", "frontend"]
		.into_iter()
		.find(|d| fs::read_to_string(Path::new(d).join("package.json")).is_ok_and(|s| s.contains("\"test:visual\"")))
	else {
		log.line("js.preCommit.visual: no package.json with a \"test:visual\" script found (looked in ./ and ./frontend)");
		return false;
	};
	log.line(format!("Running: pnpm test:visual ({dir})"));
	if !log.run(Command::new("pnpm").arg("test:visual").current_dir(dir)) {
		log.line("pnpm test:visual failed");
		return false;
	}
	true
}

fn main() -> ExitCode {
	let cfg = Config::from_args();

	if let Some(git_ops) = &cfg.git_ops {
		// detached: network-bound and unrelated to what is being committed. Own process group,
		// so ^C on the commit doesn't take it down; null stdin, as a background job reading the
		// tty hangs on SIGTTIN. stderr is its only channel.
		Command::new(git_ops)
			.arg("sync-labels")
			.stdin(Stdio::null())
			.stdout(Stdio::null())
			.process_group(0)
			.spawn()
			.expect("spawn label sync");
	}

	// codestyle_install puts ~/.cargo/bin on its own PATH; codestyle is then run from there
	let mut path = env::var_os("PATH").expect("PATH is set in a git hook");
	if cfg.codestyle_install.is_some() {
		let mut dirs: Vec<PathBuf> = env::split_paths(&path).collect();
		let cargo_bin = home().join(".cargo/bin");
		if !dirs.contains(&cargo_bin) {
			dirs.push(cargo_bin);
		}
		path = env::join_paths(dirs).expect("PATH entries came from PATH");
	}

	let rust = Path::new("Cargo.toml").is_file();
	let mut staged = Vec::new();
	let mut steps: Vec<Step> = vec![Box::new(|log| copy_config(&cfg, log))];
	if rust {
		patched_manifests(&cfg);
		let out = Command::new("git")
			.args(["diff", "--name-only", "--cached", "--diff-filter=ACMR"])
			.output()
			.expect("spawn git diff");
		assert!(out.status.success(), "git diff --cached: {}", String::from_utf8_lossy(&out.stderr));
		staged = String::from_utf8(out.stdout).expect("git paths are utf-8").lines().map(String::from).collect();
		// mutators split by the files they write, so no two steps touch the same file
		steps.push(Box::new(sort_manifests));
		steps.push(Box::new(|log| sort_derives(&cfg, log)));
		if let (Some(_), Some(install)) = (cfg.style, &cfg.codestyle_install) {
			steps.push(Box::new(|log| log.run(Command::new("bash").args(["-c", install]))));
		}
	}
	phase(steps);

	let mut steps: Vec<Step> = Vec::new();
	if rust {
		// idea is: if all these functions are ran on every commit, then the only files impacted will be those with changes yet to be committed; hence if tool affects something outside of staged, it was outside of the scope meant to be committed anyways.
		if !staged.is_empty() {
			assert!(Command::new("git").arg("add").args(&staged).status().expect("spawn git add").success(), "re-staging staged files");
		}
		// alone: it rewrites *.rs, which the checks below read
		if let Some(style) = cfg.style
			&& !codestyle(&cfg, style, &path)
		{
			return ExitCode::FAILURE;
		}
		if cfg.semver_checks {
			steps.push(Box::new(|log| {
				!log.require_tool("cargo-semver-checks", "cargo install cargo-semver-checks") || log.run(Command::new("cargo").arg("semver-checks"))
			}));
		}
		if cfg.tracey_check {
			steps.push(Box::new(|log| {
				!Path::new(".config/tracey/config.kdl").is_file() || log.run(Command::new("tracey").arg("--check"))
			}));
		}
	}
	if cfg.js_visual {
		steps.push(Box::new(js_visual));
	}
	phase(steps);
	// snapshot diffs the visual run produced are re-staged, mirroring the rust steps' staged-only contract
	if cfg.js_visual {
		assert!(Command::new("git").args(["add", "-u"]).status().expect("spawn git add").success(), "staging visual snapshots");
	}

	// commit message text file, if one was left
	if let Err(e) = fs::remove_file("commit")
		&& e.kind() != std::io::ErrorKind::NotFound
	{
		panic!("rm commit: {e}");
	}
	println!("Ran custom pre-commit hooks");
	ExitCode::SUCCESS
}
