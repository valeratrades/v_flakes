#!/home/v/nix/home/scripts/nix-run-cached
---cargo

[package]
edition = "2024"

[dependencies]
clap = { version = "4", features = ["derive"] }
dirs = "6"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
---

use std::{
	collections::{HashMap, HashSet},
	fs,
	io::{self, BufRead, IsTerminal, Write as _},
	path::PathBuf,
	process::{Command, Stdio},
};

use clap::{Parser, Subcommand};
use serde::Deserialize;

#[derive(Debug, Parser)]
#[command(name = "vgit")]
#[command(about = "GitHub repository management utilities")]
struct Args {
	#[command(subcommand)]
	command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
	/// Sync repository labels with local configuration
	SyncLabels {
		/// JSON array of {name, color, description?} (leading # in color optional)
		#[arg(long)]
		labels_json: String,

		/// Check for duplicate or too-similar colors
		#[arg(long)]
		check_duplicate_colors: bool,
	},
	/// Copy convention files from the owner's profile repo (github.com/<owner>/<owner>)
	/// or org defaults repo (github.com/<owner>/.github); a file must live in only one
	SyncConventions {
		/// Opaque key tying the cache to the v_flakes version (any change re-pulls)
		#[arg(long)]
		version_key: String,

		/// File path inside the source repo to copy into the working repo (repeatable)
		#[arg(long, value_name = "PATH")]
		file: Vec<String>,
	},
	/// Rewrite every reachable commit message, dropping the Claude Code trailers the
	/// commit-msg hook strips from new commits. All hashes change from the oldest
	/// match onward, so it needs a force-push and a re-clone by everyone else.
	StripHistory {
		/// Rewrite without the interactive confirmation
		#[arg(long)]
		yes: bool,
	},
	/// Provision a read-only SSH deploy key so this repo's CI can fetch a private
	/// `git+ssh` flake input: public half → deploy key on TARGET, private half →
	/// the DEPLOY_KEY Actions secret on this repo.
	InitDeployKey {
		/// The private dependency repo to grant read access to, as OWNER/REPO
		#[arg(value_name = "OWNER/REPO")]
		target: String,
	},
}

#[derive(Clone, Debug, Deserialize)]
struct LabelSpec {
	name: String,
	color: String,
	description: Option<String>,
}

fn parse_labels_json(s: &str) -> Result<Vec<LabelSpec>, String> {
	let mut labels: Vec<LabelSpec> = serde_json::from_str(s).map_err(|e| format!("Invalid labels JSON: {}", e))?;
	for l in &mut labels {
		l.color = l.color.trim_start_matches('#').to_string();
		if l.color.len() != 6 || !l.color.chars().all(|c| c.is_ascii_hexdigit()) {
			return Err(format!("Invalid color '{}' for label '{}', expected 6-digit hex", l.color, l.name));
		}
		l.description = l.description.take().filter(|d| !d.is_empty());
	}
	Ok(labels)
}

/// Compute a stable, deterministic fingerprint of the label configuration.
/// Produces a simple canonical string that won't change across Rust versions.
fn compute_labels_fingerprint(labels: &[LabelSpec]) -> String {
	let mut sorted: Vec<_> = labels.iter().collect();
	sorted.sort_by(|a, b| a.name.cmp(&b.name));
	let mut out = String::new();
	for label in sorted {
		out.push_str(&label.name);
		out.push('\0');
		out.push_str(&label.color);
		out.push('\0');
		out.push_str(label.description.as_deref().unwrap_or(""));
		out.push('\n');
	}
	out
}

/// Per-repo state file: ~/.local/state/git_ops/<bucket>/<hex-encoded-repo-path>
fn state_file_for_repo(bucket: &str, repo_root: &str) -> PathBuf {
	let state_dir = dirs::state_dir().expect("XDG_STATE_HOME not available").join("git_ops").join(bucket);
	// Simple hex encoding of repo path to get a safe filename
	let hex: String = repo_root.bytes().map(|b| format!("{:02x}", b)).collect();
	state_dir.join(hex)
}

fn load_saved_fingerprint(bucket: &str, repo_root: &str) -> Option<String> {
	fs::read_to_string(state_file_for_repo(bucket, repo_root)).ok()
}

fn save_fingerprint(bucket: &str, repo_root: &str, fingerprint: &str) {
	let path = state_file_for_repo(bucket, repo_root);
	if let Some(parent) = path.parent() {
		fs::create_dir_all(parent).expect("failed to create state directory");
	}
	fs::write(&path, fingerprint).expect("failed to write state file");
}

fn get_repo_root() -> Option<String> {
	let output = Command::new("git").args(["rev-parse", "--show-toplevel"]).output().ok()?;
	if output.status.success() {
		Some(String::from_utf8_lossy(&output.stdout).trim().to_string())
	} else {
		None
	}
}

#[derive(Debug, Deserialize)]
struct GhLabel {
	name: String,
	color: String,
	description: Option<String>,
}

fn run_gh(args: &[&str]) -> io::Result<std::process::Output> {
	// gh must never prompt from within the tool (often backgrounded with a tty stdin)
	Command::new("gh").args(args).stdin(Stdio::null()).output()
}

fn run_gh_success(args: &[&str]) -> bool {
	run_gh(args).map(|o| o.status.success()).unwrap_or(false)
}

fn get_remote_labels() -> Result<Vec<GhLabel>, String> {
	let output = run_gh(&["label", "list", "--json", "name,color,description", "--limit", "1000"]).map_err(|e| format!("Failed to run gh: {}", e))?;

	if !output.status.success() {
		return Err(format!("gh label list failed: {}", String::from_utf8_lossy(&output.stderr)));
	}

	let labels: Vec<GhLabel> = serde_json::from_slice(&output.stdout).map_err(|e| format!("Failed to parse labels: {}", e))?;

	Ok(labels)
}

fn create_label(name: &str, color: &str, description: Option<&str>) -> bool {
	match description {
		Some(desc) => run_gh_success(&["label", "create", name, "--color", color, "--description", desc, "--force"]),
		None => run_gh_success(&["label", "create", name, "--color", color, "--force"]),
	}
}

fn update_label(name: &str, color: &str, description: Option<&str>) -> bool {
	match description {
		Some(desc) => run_gh_success(&["label", "edit", name, "--color", color, "--description", desc]),
		None => run_gh_success(&["label", "edit", name, "--color", color]),
	}
}

fn delete_label(name: &str) -> bool {
	run_gh_success(&["label", "delete", name, "--yes"])
}

fn prompt_yes_no(question: &str) -> bool {
	print!("{} [y/N]: ", question);
	io::stdout().flush().unwrap();

	let stdin = io::stdin();
	let mut line = String::new();
	if stdin.lock().read_line(&mut line).is_err() {
		return false;
	}

	matches!(line.trim().to_lowercase().as_str(), "y" | "yes")
}

fn hex_to_rgb(hex: &str) -> (u8, u8, u8) {
	let hex = hex.trim_start_matches('#');
	let r = u8::from_str_radix(&hex[0..2], 16).unwrap_or(0);
	let g = u8::from_str_radix(&hex[2..4], 16).unwrap_or(0);
	let b = u8::from_str_radix(&hex[4..6], 16).unwrap_or(0);
	(r, g, b)
}

fn rgb_to_hsl(r: u8, g: u8, b: u8) -> (f64, f64, f64) {
	let r = r as f64 / 255.0;
	let g = g as f64 / 255.0;
	let b = b as f64 / 255.0;

	let max = r.max(g).max(b);
	let min = r.min(g).min(b);
	let l = (max + min) / 2.0;

	if (max - min).abs() < f64::EPSILON {
		return (0.0, 0.0, l * 100.0);
	}

	let d = max - min;
	let s = if l > 0.5 { d / (2.0 - max - min) } else { d / (max + min) };

	let h = if (max - r).abs() < f64::EPSILON {
		let mut h = (g - b) / d;
		if g < b {
			h += 6.0;
		}
		h
	} else if (max - g).abs() < f64::EPSILON {
		(b - r) / d + 2.0
	} else {
		(r - g) / d + 4.0
	};

	(h * 60.0, s * 100.0, l * 100.0)
}

fn check_duplicate_colors(labels: &[LabelSpec]) -> Result<(), String> {
	// Check exact duplicates
	let mut color_to_name: HashMap<String, &str> = HashMap::new();
	for label in labels {
		let color_lower = label.color.to_lowercase();
		if let Some(existing) = color_to_name.get(&color_lower) {
			return Err(format!("Duplicate color #{}: '{}' and '{}'", label.color, existing, label.name));
		}
		color_to_name.insert(color_lower, &label.name);
	}

	// Convert to HSL and sort by hue
	let mut hsl_labels: Vec<(&str, &str, f64, f64, f64)> = labels
		.iter()
		.map(|label| {
			let (r, g, b) = hex_to_rgb(&label.color);
			let (h, s, l) = rgb_to_hsl(r, g, b);
			(label.name.as_str(), label.color.as_str(), h, s, l)
		})
		.collect();

	hsl_labels.sort_by(|a, b| a.2.partial_cmp(&b.2).unwrap());

	// Check adjacent colors (including wrap-around from last to first)
	for i in 0..hsl_labels.len() {
		let (name1, color1, h1, s1, l1) = hsl_labels[i];
		let (name2, color2, h2, s2, l2) = hsl_labels[(i + 1) % hsl_labels.len()];

		// Calculate hue difference (accounting for wrap-around at 360)
		let h_diff = if i + 1 == hsl_labels.len() {
			// Wrap-around case
			(360.0 - h1 + h2).min(h1 - h2 + 360.0).abs()
		} else {
			(h2 - h1).abs()
		};

		if h_diff < 16.0 {
			let s_diff = (s2 - s1).abs();
			let l_diff = (l2 - l1).abs();
			let total_diff = h_diff + s_diff + l_diff;

			if total_diff < 32.0 {
				return Err(format!("Colors too similar (diff={:.1}): '{}' #{} and '{}' #{}", total_diff, name1, color1, name2, color2));
			}
		}
	}

	Ok(())
}

fn report_mismatches(local_map: &HashMap<String, (String, Option<String>)>, remote_map: &HashMap<String, (String, Option<String>)>) {
	let mut lines = Vec::new();

	// Labels we want but remote doesn't have
	for (name, (color, desc)) in local_map {
		if !remote_map.contains_key(name) {
			lines.push(format!("  + {} (#{}, {:?}) — not on remote", name, color, desc.as_deref().unwrap_or("")));
		}
	}

	// Labels where remote differs from what we want
	for (name, (color, description)) in local_map {
		if let Some((remote_color, remote_desc)) = remote_map.get(name) {
			let color_differs = remote_color.to_lowercase() != color.to_lowercase();
			let rd = remote_desc.as_deref().filter(|s| !s.is_empty());
			let ld = description.as_deref().filter(|s| !s.is_empty());
			let desc_differs = rd != ld;
			if color_differs || desc_differs {
				let mut diffs = Vec::new();
				if color_differs {
					diffs.push(format!("color: #{} -> #{}", remote_color, color));
				}
				if desc_differs {
					diffs.push(format!("desc: {:?} -> {:?}", rd.unwrap_or(""), ld.unwrap_or("")));
				}
				lines.push(format!("  ~ {} ({})", name, diffs.join(", ")));
			}
		}
	}

	// Labels on remote that we don't manage
	for name in remote_map.keys() {
		if !local_map.contains_key(name) {
			lines.push(format!("  ? {} — on remote but not in config", name));
		}
	}

	if !lines.is_empty() {
		lines.sort();
		eprintln!("label-sync: config drift detected:");
		for line in &lines {
			eprintln!("{}", line);
		}
	}
}

#[derive(Debug, Deserialize)]
struct GhIssue {
	number: u64,
	title: String,
	labels: Vec<GhLabel>,
}

/// Lint open issues against label conventions. Operates on live remote state,
/// so unlike label sync it cannot be fingerprint-gated.
fn lint_issues() {
	let output = match run_gh(&["issue", "list", "--json", "number,title,labels", "--limit", "1000"]) {
		Ok(o) if o.status.success() => o,
		// issues may be disabled on this repo — that shouldn't fail label sync
		Ok(o) => {
			eprintln!("issue-lint: skipped: {}", String::from_utf8_lossy(&o.stderr).trim());
			return;
		}
		Err(e) => {
			eprintln!("issue-lint: skipped: {}", e);
			return;
		}
	};
	let issues: Vec<GhIssue> = match serde_json::from_slice(&output.stdout) {
		Ok(i) => i,
		Err(e) => {
			eprintln!("issue-lint: failed to parse issues: {}", e);
			std::process::exit(1);
		}
	};

	// Each check maps an issue to Some(warning); extend as more rules land.
	let exactly_one = |i: &GhIssue, series: &str| {
		let n = i.labels.iter().filter(|l| l.name.starts_with(series)).count();
		(n != 1).then(|| format!("#{} '{}' has {} {}* labels, expected exactly one", i.number, i.title, n, series))
	};
	let checks: &[&dyn Fn(&GhIssue) -> Option<String>] = &[&|i| exactly_one(i, "t:"), &|i| exactly_one(i, "i:")];
	for issue in &issues {
		for check in checks {
			if let Some(warning) = check(issue) {
				eprintln!("issue-lint: {}", warning);
			}
		}
	}
}

// Built from parts so this file's own literals never match the scan.
const TODO_NEEDLE: &str = concat!("TO", "DO");
const TODO_MARKER: &str = concat!("<!-- ", "todo-id: ");
// Stamped on issues our close pass closes. Its absence on a closed issue whose
// comment is still in code means a human closed it — a verdict we mirror by
// deleting the comment.
const AUTO_CLOSE_MARKER: &str = "<!-- todo-sync: auto-closed -->";

/// Fixture trees are data, not code: a needle inside one is content to keep verbatim, and
/// the close pass would otherwise edit it out of the file. Default pathspec magic, so `*`
/// crosses `/` and every entry matches at any depth (workspace member, nested crate).
const FIXTURE_PATHSPECS: [&str; 6] = [
	":(exclude)*tests/corpus*",
	":(exclude)*tests/data/*",
	":(exclude)*fixtures/*",
	":(exclude)*testdata/*",
	":(exclude)*snapshots/*",
	":(exclude)*.snap",
];

/// Walk past bare needle mentions to the `<needle>!*:` occurrence grep matched.
/// Returns (needle position, bang count, content after the colon).
fn split_todo(line: &str) -> Option<(usize, usize, &str)> {
	let mut base = 0;
	while let Some(pos) = line[base..].find(TODO_NEEDLE) {
		let start = base + pos;
		let after = &line[start + TODO_NEEDLE.len()..];
		let bangs = after.bytes().take_while(|&b| b == b'!').count();
		if let Some(content) = after[bangs..].strip_prefix(':') {
			return Some((start, bangs, content));
		}
		base = start + TODO_NEEDLE.len();
	}
	None
}

/// Identity of a logical comment across machines/contributors: (bang count, raw content),
/// never file/line. Lives on the issue itself as an invisible body marker.
fn todo_id(bangs: usize, content: &str) -> String {
	let mut h: u64 = 0xcbf29ce484222325;
	for b in format!("{bangs}:{content}").bytes() {
		h ^= b as u64;
		h = h.wrapping_mul(0x100000001b3);
	}
	format!("{h:016x}")
}

#[derive(Debug)]
struct Todo {
	id: String,
	importance: usize,
	title: String,
	description: String,
	occurrences: Vec<(String, usize)>,
}

/// A comment is read from the needle to end of line, so it must fit on one line —
/// a wrapped continuation is invisible here and gets left behind by the close pass.
fn scan_todos(repo_root: &str) -> Vec<Todo> {
	let pattern = format!("{TODO_NEEDLE}!*:");
	let output = Command::new("git")
		.args(["grep", "-In", "-E", &pattern, "--"].into_iter().chain(FIXTURE_PATHSPECS))
		.current_dir(repo_root)
		.output()
		.unwrap_or_else(|e| {
			eprintln!("todo-sync: failed to run git grep: {e}");
			std::process::exit(1);
		});
	match output.status.code() {
		Some(0) => {}
		// exit 1 + empty stderr = legitimately zero matches; anything else must be loud —
		// misreading a grep failure as "no TODOs" would mass-close every generated issue
		Some(1) if output.stderr.is_empty() => return Vec::new(),
		_ => {
			eprintln!("todo-sync: git grep failed: {}", String::from_utf8_lossy(&output.stderr));
			std::process::exit(1);
		}
	}

	let mut seen: HashMap<(usize, String), Vec<(String, usize)>> = HashMap::new();
	for line in String::from_utf8_lossy(&output.stdout).lines() {
		let mut parts = line.splitn(3, ':');
		let (Some(file), Some(lineno), Some(rest)) = (parts.next(), parts.next(), parts.next()) else {
			continue;
		};
		if let Some((_, bangs, content)) = split_todo(rest) {
			let lineno = lineno.parse().expect("git grep -n emits numeric line numbers");
			seen.entry((bangs, content.trim().to_string())).or_default().push((file.to_string(), lineno));
		}
	}

	let mut todos = Vec::new();
	for ((bangs, content), mut occurrences) in seen {
		occurrences.sort();
		let at = format!("{}:{}", occurrences[0].0, occurrences[0].1);
		if content.is_empty() {
			eprintln!("todo-sync: skipping contentless {TODO_NEEDLE} at {at} — the whole comment must fit on that one line");
			continue;
		}
		let (title, description) = match content.split_once(". ") {
			Some((t, d)) => (t.to_string(), d.trim().to_string()),
			None => (content.strip_suffix('.').unwrap_or(&content).to_string(), String::new()),
		};
		if title.len() > 256 {
			eprintln!("todo-sync: skipping (title > 256 chars, gh would reject) at {at}");
			continue;
		}
		todos.push(Todo {
			id: todo_id(bangs, &content),
			importance: bangs.min(9),
			title,
			description,
			occurrences,
		});
	}
	todos.sort_by(|a, b| a.occurrences[0].cmp(&b.occurrences[0]));
	todos
}

#[derive(Debug, Deserialize)]
#[serde(rename_all = "camelCase")]
struct GhTodoIssue {
	number: u64,
	state: String,
	state_reason: Option<String>,
	body: String,
}

fn extract_todo_id(body: &str) -> Option<&str> {
	let rest = &body[body.find(TODO_MARKER)? + TODO_MARKER.len()..];
	Some(rest[..rest.find(" -->")?].trim())
}

/// Reconcile generated issues against the working tree, converging toward
/// code-as-source-of-truth from any remote state. Runs every invocation like
/// lint — remote state can't be fingerprint-gated.
fn sync_todos(repo_root: &str) {
	let todos = scan_todos(repo_root);

	let output = match run_gh(&[
		"issue",
		"list",
		"--state",
		"all",
		"--label",
		"ext:from_todo",
		"--json",
		"number,state,stateReason,body",
		"--limit",
		"1000",
	]) {
		Ok(o) if o.status.success() => o,
		// issues may be disabled on this repo — same policy as lint_issues
		Ok(o) => {
			eprintln!("todo-sync: skipped: {}", String::from_utf8_lossy(&o.stderr).trim());
			return;
		}
		Err(e) => {
			eprintln!("todo-sync: skipped: {}", e);
			return;
		}
	};
	let issues: Vec<GhTodoIssue> = match serde_json::from_slice(&output.stdout) {
		Ok(i) => i,
		Err(e) => {
			eprintln!("todo-sync: failed to parse issues: {}", e);
			std::process::exit(1);
		}
	};
	if issues.len() == 1000 {
		eprintln!("todo-sync: fetch cap hit — reconciling against a truncated view could duplicate issues");
		std::process::exit(1);
	}

	let mut by_id: HashMap<&str, &GhTodoIssue> = HashMap::new();
	for issue in &issues {
		match extract_todo_id(&issue.body) {
			Some(id) => {
				// should never happen, but if an id is duplicated prefer the open issue
				// so we don't reopen a second copy next to it
				let slot = by_id.entry(id).or_insert(issue);
				if issue.state == "OPEN" {
					*slot = issue;
				}
			}
			None if issue.state == "OPEN" => {
				eprintln!("todo-sync: #{} has ext:from_todo but no id marker — leaving it alone", issue.number)
			}
			None => {}
		}
	}

	let mut removals: Vec<(&Todo, u64)> = Vec::new();
	for todo in &todos {
		match by_id.get(todo.id.as_str()) {
			None => {
				let (file, line) = &todo.occurrences[0];
				let mut body = String::new();
				if !todo.description.is_empty() {
					body.push_str(&todo.description);
					body.push_str("\n\n");
				}
				body.push_str(&format!("_From `{file}:{line}` at generation time._\n\n{}{} -->", TODO_MARKER, todo.id));
				// t:chore keeps the exactly-one-t:* lint green; user retags freely — identity is the marker
				let labels = format!("ext:from_todo,i:{},t:chore", todo.importance);
				if !run_gh_success(&["issue", "create", "--title", &todo.title, "--body", &body, "--label", &labels]) {
					eprintln!("todo-sync: failed to create issue for '{}'", todo.title);
				}
			}
			// auto-close marker + not-planned = we closed it when the comment was hidden
			// (branch switch, edit churn) — reopen the same issue, never create a duplicate.
			// Reopen before stripping the marker: a stale marker mis-reopens later at worst,
			// while a stripped marker on a still-closed issue would read as a human close
			// and delete the comment.
			Some(i) if i.state != "OPEN" && i.state_reason.as_deref() == Some("NOT_PLANNED") && i.body.contains(AUTO_CLOSE_MARKER) => {
				let n = i.number.to_string();
				if run_gh_success(&["issue", "reopen", &n]) {
					let stripped = i.body.replace(&format!("\n\n{AUTO_CLOSE_MARKER}"), "").replace(AUTO_CLOSE_MARKER, "");
					if !run_gh_success(&["issue", "edit", &n, "--body", &stripped]) {
						eprintln!("todo-sync: failed to strip auto-close marker from #{n}");
					}
				} else {
					eprintln!("todo-sync: failed to reopen #{n}");
				}
			}
			// any other close (completed, or not-planned without our marker) is a human
			// verdict on a comment still in code — mirror it by deleting the comment
			Some(i) if i.state != "OPEN" => removals.push((todo, i.number)),
			Some(_) => {}
		}
	}
	remove_todo_comments(repo_root, &removals);

	let scanned: HashSet<&str> = todos.iter().map(|t| t.id.as_str()).collect();
	for issue in &issues {
		if issue.state != "OPEN" {
			continue;
		}
		let Some(id) = extract_todo_id(&issue.body) else { continue };
		if scanned.contains(id) {
			continue;
		}
		let n = issue.number.to_string();
		// stamp before closing: an unmarked sync-close would later read as a human
		// verdict and get the reappeared comment deleted — so no stamp, no close
		if !issue.body.contains(AUTO_CLOSE_MARKER) {
			let marked = format!("{}\n\n{AUTO_CLOSE_MARKER}", issue.body);
			if !run_gh_success(&["issue", "edit", &n, "--body", &marked]) {
				eprintln!("todo-sync: failed to stamp #{n} before close — skipping close");
				continue;
			}
		}
		let comment = format!("{TODO_NEEDLE} comment no longer in code — closed by sync.");
		if !run_gh_success(&["issue", "close", &n, "--reason", "not planned", "--comment", &comment]) {
			eprintln!("todo-sync: failed to close #{n}");
		}
	}
}

/// A human closed the issue while its comment is still in code: delete the comment.
/// Comment-only lines are dropped whole; a trailing comment is cut off its code line.
fn remove_todo_comments(repo_root: &str, removals: &[(&Todo, u64)]) {
	let mut by_file: HashMap<&str, Vec<(usize, &Todo, u64)>> = HashMap::new();
	for (todo, number) in removals {
		for (file, line) in &todo.occurrences {
			by_file.entry(file).or_default().push((*line, todo, *number));
		}
	}
	for (file, edits) in by_file {
		let path = PathBuf::from(repo_root).join(file);
		let text = match fs::read_to_string(&path) {
			Ok(t) => t,
			Err(e) => {
				eprintln!("todo-sync: can't read {file}: {e}");
				continue;
			}
		};
		// split('\n') keeps \r on CRLF lines and a "" tail for the trailing newline,
		// so join('\n') reproduces the file byte-for-byte around our edits
		let mut lines: Vec<Option<String>> = text.split('\n').map(|l| Some(l.to_string())).collect();
		for (lineno, todo, number) in edits {
			let Some(slot) = lines.get_mut(lineno - 1) else {
				eprintln!("todo-sync: {file}:{lineno} vanished since scan — not removing");
				continue;
			};
			let replacement = {
				let line = slot.as_deref().expect("each scanned line is edited at most once");
				// re-verify identity at the exact line before touching it: scan and edit
				// are milliseconds apart, but deleting the wrong code is unrecoverable
				let verified = split_todo(line).filter(|(_, bangs, content)| todo_id(*bangs, content.trim()) == todo.id);
				let Some((pos, ..)) = verified else {
					eprintln!("todo-sync: {file}:{lineno} changed since scan — not removing");
					continue;
				};
				let mut prefix = line[..pos].trim_end();
				// ponytail: one trailing comment-leader heuristic instead of per-language
				// syntax; upgrade to real comment parsing if a language defeats it
				for lead in ["<!--", "/*", "//", "--", "#", "*", ";", "%"] {
					if let Some(s) = prefix.strip_suffix(lead) {
						prefix = s.trim_end();
						break;
					}
				}
				eprintln!("todo-sync: #{number} closed by human — removing comment at {file}:{lineno}");
				(!prefix.is_empty()).then(|| prefix.to_string())
			};
			*slot = replacement;
		}
		let kept: Vec<&str> = lines.iter().flatten().map(String::as_str).collect();
		if let Err(e) = fs::write(&path, kept.join("\n")) {
			eprintln!("todo-sync: can't write {file}: {e}");
		}
	}
}

fn sync_labels(local_labels: Vec<LabelSpec>, check_colors: bool) {
	let repo_root = get_repo_root().expect("not in a git repository");

	// Concurrent shell-start runs must not race: `gh issue create` is not
	// idempotent (unlike label create --force). Held lock → someone else is on it.
	let lock_path = state_file_for_repo("lock", &repo_root);
	fs::create_dir_all(lock_path.parent().expect("state path always has a parent")).expect("failed to create state directory");
	let lock = fs::File::create(&lock_path).expect("failed to open lock file");
	match lock.try_lock() {
		Ok(()) => {}
		Err(e) if matches!(e, fs::TryLockError::WouldBlock) => return,
		Err(e) => {
			eprintln!("ERROR: lock {}: {}", lock_path.display(), e);
			std::process::exit(1);
		}
	}

	if check_colors {
		if let Err(e) = check_duplicate_colors(&local_labels) {
			eprintln!("ERROR: {}", e);
			std::process::exit(1);
		}
		println!("Color check passed.");
	}

	// Fingerprint gates only the label block (not an early return): on a fresh repo
	// labels must exist before `gh issue create --label ...` below can succeed.
	let fingerprint = compute_labels_fingerprint(&local_labels);
	if load_saved_fingerprint("labels", &repo_root).as_ref() != Some(&fingerprint) {
		sync_labels_remote(local_labels);
		save_fingerprint("labels", &repo_root, &fingerprint);
	}

	lint_issues();
	sync_todos(&repo_root);
}

fn sync_labels_remote(local_labels: Vec<LabelSpec>) {
	let remote_labels = match get_remote_labels() {
		Ok(labels) => labels,
		Err(e) => {
			eprintln!("ERROR: {}", e);
			std::process::exit(1);
		}
	};

	let local_map: HashMap<String, (String, Option<String>)> = local_labels.into_iter().map(|l| (l.name, (l.color, l.description))).collect();
	let remote_map: HashMap<String, (String, Option<String>)> = remote_labels.into_iter().map(|l| (l.name, (l.color, l.description))).collect();

	report_mismatches(&local_map, &remote_map);

	let mut created = 0;
	let mut updated = 0;
	let mut deleted = 0;

	// Create or update labels
	for (name, (color, description)) in &local_map {
		match remote_map.get(name) {
			None =>
				if create_label(name, color, description.as_deref()) {
					created += 1;
				} else {
					eprintln!("  Failed to create label '{}'", name);
				},
			Some((remote_color, remote_desc)) => {
				let color_differs = remote_color.to_lowercase() != color.to_lowercase();
				// Normalize: treat Some("") same as None
				let rd = remote_desc.as_deref().filter(|s| !s.is_empty());
				let ld = description.as_deref().filter(|s| !s.is_empty());
				let desc_differs = rd != ld;
				if color_differs || desc_differs {
					if update_label(name, color, description.as_deref()) {
						updated += 1;
					} else {
						eprintln!("  Failed to update label '{}'", name);
					}
				}
			}
		}
	}

	// Find labels to delete (only prompt in interactive mode)
	let to_delete: Vec<&String> = remote_map.keys().filter(|name| !local_map.contains_key(*name)).collect();

	if !to_delete.is_empty() && io::stdin().is_terminal() {
		println!("\nRemote labels not in local config:");
		for name in &to_delete {
			println!("  - {}", name);
		}

		if prompt_yes_no("\nDelete these labels?") {
			for name in to_delete {
				if delete_label(name) {
					deleted += 1;
				} else {
					eprintln!("  Failed to delete label '{}'", name);
				}
			}
		}
	}

	// Only print summary if there were actual changes
	if created > 0 || updated > 0 || deleted > 0 {
		println!("Labels synced: {} created, {} updated, {} deleted", created, updated, deleted);
	}
}

fn compute_conventions_fingerprint(version_key: &str, owner: &str, files: &[String]) -> String {
	let mut sorted: Vec<&String> = files.iter().collect();
	sorted.sort();
	let mut out = String::new();
	out.push_str("v=");
	out.push_str(version_key);
	out.push('\n');
	out.push_str("owner=");
	out.push_str(owner);
	out.push('\n');
	for f in sorted {
		out.push_str(f);
		out.push('\n');
	}
	out
}

/// Parse the GitHub owner from `remote.origin.url` — purely local, no network.
fn get_repo_owner() -> Result<String, String> {
	let output = Command::new("git")
		.args(["config", "--get", "remote.origin.url"])
		.output()
		.map_err(|e| format!("Failed to run git: {e}"))?;
	if !output.status.success() {
		return Err("no remote.origin.url".into());
	}
	let url = String::from_utf8_lossy(&output.stdout).trim().to_string();

	// Accepts: https://github.com/OWNER/REPO[.git], git@github.com:OWNER/REPO[.git],
	//          ssh://git@github.com/OWNER/REPO[.git]
	let after_host = url
		.split_once("github.com")
		.map(|(_, rest)| rest.trim_start_matches([':', '/']))
		.ok_or_else(|| format!("not a github.com remote: {url}"))?;
	let owner = after_host
		.split('/')
		.next()
		.filter(|s| !s.is_empty())
		.ok_or_else(|| format!("couldn't parse owner from: {url}"))?;
	Ok(owner.to_string())
}

fn fetch_raw_file(owner: &str, repo: &str, path: &str) -> Result<Vec<u8>, String> {
	let api_path = format!("/repos/{owner}/{repo}/contents/{path}");
	let output = run_gh(&["api", "-H", "Accept: application/vnd.github.raw", &api_path]).map_err(|e| format!("gh api failed: {e}"))?;
	if !output.status.success() {
		return Err(format!("gh api failed for {path}: {}", String::from_utf8_lossy(&output.stderr)));
	}
	Ok(output.stdout)
}

fn sync_conventions(version_key: String, files: Vec<String>) {
	let repo_root = get_repo_root().expect("not in a git repository");

	let owner = match get_repo_owner() {
		Ok(o) => o,
		Err(e) => {
			eprintln!("conventions: {e}");
			return;
		}
	};

	let fingerprint = compute_conventions_fingerprint(&version_key, &owner, &files);
	if load_saved_fingerprint("conventions", &repo_root).as_ref() == Some(&fingerprint) {
		return;
	}

	let repo_path = PathBuf::from(&repo_root);
	// Convention files may live in the owner's profile repo (`OWNER/OWNER`) or in
	// their org-wide defaults repo (`OWNER/.github`). A given file must exist in at
	// most one of them — finding it in both is ambiguous, so we error out.
	let repos = [owner.as_str(), ".github"];
	let mut wrote = 0;
	for f in &files {
		let found: Vec<(&str, Vec<u8>)> = repos.iter().filter_map(|repo| fetch_raw_file(&owner, repo, f).ok().map(|bytes| (*repo, bytes))).collect();
		match found.as_slice() {
			[] => eprintln!("conventions: skip {f}: not found in {owner}/{owner} or {owner}/.github"),
			[(_, bytes)] => {
				let dest = repo_path.join(f);
				if let Some(parent) = dest.parent() {
					fs::create_dir_all(parent).expect("failed to create dir for convention file");
				}
				fs::write(&dest, bytes).expect("failed to write convention file");
				wrote += 1;
			}
			_ => {
				eprintln!(
					"conventions: {f} found in both {owner}/{owner} and {owner}/.github — \
                     keep it in exactly one source"
				);
				std::process::exit(1);
			}
		}
	}

	save_fingerprint("conventions", &repo_root, &fingerprint);
	if wrote > 0 {
		println!("conventions: synced {wrote} file(s) from {owner}/{{{owner},.github}}");
	}
}

// ERE, shared by `git log --grep -E` (which commits match) and `sed -E` (what to cut).
// Same two shapes files/strip_claude_signature.nix applies to new commit messages.
const CLAUDE_TRAILERS: [&str; 2] = ["^[[:space:]]*Co-authored-by:.*(Claude|noreply@anthropic\\.com)", "Generated with \\[?Claude Code"];

fn strip_history(yes: bool) {
	let repo_root = get_repo_root().expect("not in a git repository");

	let mut args = vec!["log", "--branches", "--tags", "--format=%h %s", "-E", "-i"];
	for pat in CLAUDE_TRAILERS {
		args.extend(["--grep", pat]);
	}
	let listed = Command::new("git").args(&args).current_dir(&repo_root).output().expect("failed to run git log");
	if !listed.status.success() {
		eprintln!("strip-history: git log failed: {}", String::from_utf8_lossy(&listed.stderr));
		std::process::exit(1);
	}
	let matched = String::from_utf8_lossy(&listed.stdout);
	let matched: Vec<&str> = matched.lines().collect();
	if matched.is_empty() {
		println!("strip-history: no Claude trailers in branches or tags");
		return;
	}

	println!("strip-history: {} commit(s) carry a Claude trailer:", matched.len());
	for line in &matched {
		println!("  {line}");
	}
	if !yes {
		if !io::stdin().is_terminal() {
			eprintln!("strip-history: refusing to rewrite non-interactively — pass --yes");
			std::process::exit(1);
		}
		if !prompt_yes_no("\nRewrite history? Every hash from the oldest match onward changes") {
			return;
		}
	}

	// patterns are embedded in a single-quoted shell word
	assert!(CLAUDE_TRAILERS.iter().all(|p| !p.contains('\'')), "trailer patterns must be shell-quotable");
	// stripspace drops the blank lines the deletions leave behind; on messages `git commit`
	// already cleaned up (all of them, in practice) it is a no-op
	let msg_filter = format!("sed -E -e '/{}/Id' -e '/{}/Id' | git stripspace", CLAUDE_TRAILERS[0], CLAUDE_TRAILERS[1]);
	// refs/remotes stay out of scope: rewriting a remote-tracking ref would claim a
	// rewrite the remote has not seen. Local branches and tags only, then force-push.
	let status = Command::new("git")
		.args(["filter-branch", "--force", "--msg-filter", &msg_filter, "--", "--branches", "--tags"])
		.current_dir(&repo_root)
		.env("FILTER_BRANCH_SQUELCH_WARNING", "1")
		.status()
		.expect("failed to run git filter-branch");
	if !status.success() {
		eprintln!("strip-history: git filter-branch failed");
		std::process::exit(1);
	}

	println!(
		"strip-history: rewritten. Originals kept in refs/original/ — verify, then \
         `git push --force-with-lease --all` (and `--tags`).\n\
         Drop the backup with: git for-each-ref --format='%(refname)' refs/original | xargs -n1 git update-ref -d"
	);
}

fn gh_capture(args: &[&str]) -> Option<String> {
	let o = run_gh(args).ok()?;
	o.status.success().then(|| String::from_utf8_lossy(&o.stdout).trim().to_string())
}

/// Secret name for a repo's deploy key. Per-repo so a single runner can hold keys for
/// several private repos at once (one id file each, disambiguated by ssh host alias).
fn deploy_secret_name(basename: &str) -> String {
	let sanitized: String = basename.chars().map(|c| if c.is_ascii_alphanumeric() { c.to_ascii_uppercase() } else { '_' }).collect();
	format!("DEPLOY_KEY_{sanitized}")
}

/// Generate a fresh ed25519 keypair, register the public half as a read-only deploy key
/// on `target`, and store the private half as this repo's DEPLOY_KEY_<REPO> secret. The
/// key is CI-only: local builds use the dev's own ssh key against plain github.com, so
/// we never touch local ssh config. The keypair only ever lives in a temp dir we delete.
fn init_deploy_key(target: String) {
	let current = gh_capture(&["repo", "view", "--json", "nameWithOwner", "-q", ".nameWithOwner"]).unwrap_or_else(|| {
		eprintln!("init-deploy-key: run inside a GitHub repo (gh repo view failed)");
		std::process::exit(1);
	});
	let basename = target.rsplit('/').next().filter(|s| !s.is_empty()).unwrap_or_else(|| {
		eprintln!("init-deploy-key: target must be OWNER/REPO (got '{target}')");
		std::process::exit(1);
	});
	let secret = deploy_secret_name(basename);

	let dir = std::env::temp_dir().join(format!("git_ops_deploy_{}", std::process::id()));
	fs::create_dir_all(&dir).expect("create temp dir");
	let key = dir.join("id_ed25519");
	let cleanup = || {
		let _ = fs::remove_dir_all(&dir);
	}; // best-effort: temp dir, removed even on the error paths below

	let keygen = Command::new("ssh-keygen")
		.args(["-t", "ed25519", "-N", "", "-C", &format!("{current} CI -> {target}"), "-f"])
		.arg(&key)
		.status()
		.map(|s| s.success())
		.unwrap_or(false);
	if !keygen {
		cleanup();
		eprintln!("init-deploy-key: ssh-keygen failed");
		std::process::exit(1);
	}

	let add = Command::new("gh")
		.args(["repo", "deploy-key", "add"])
		.arg(key.with_extension("pub"))
		.args(["--repo", &target, "--title", &format!("{current} CI (ro)")])
		.status()
		.map(|s| s.success())
		.unwrap_or(false);
	if !add {
		cleanup();
		eprintln!("init-deploy-key: `gh repo deploy-key add` failed (need admin on {target})");
		std::process::exit(1);
	}

	// gh secret set reads the value from stdin when --body is omitted.
	let priv_key = fs::read(&key).expect("read generated private key");
	let mut child = Command::new("gh")
		.args(["secret", "set", &secret])
		.stdin(std::process::Stdio::piped())
		.spawn()
		.expect("spawn gh secret set");
	child.stdin.take().unwrap().write_all(&priv_key).expect("pipe key to gh");
	let set = child.wait().map(|s| s.success()).unwrap_or(false);

	cleanup();
	if !set {
		eprintln!("init-deploy-key: `gh secret set {secret}` failed");
		std::process::exit(1);
	}
	println!("init-deploy-key: read-only deploy key on {target}; {secret} set on {current} (CI-only — local uses your own ssh key)");
}

fn main() {
	let args = Args::parse();

	match args.command {
		Commands::SyncLabels {
			labels_json,
			check_duplicate_colors,
		} => {
			let labels = match parse_labels_json(&labels_json) {
				Ok(l) if !l.is_empty() => l,
				Ok(_) => {
					eprintln!("ERROR: No labels specified. Pass --labels-json '[{{\"name\":..,\"color\":..}}]'.");
					std::process::exit(1);
				}
				Err(e) => {
					eprintln!("ERROR: {}", e);
					std::process::exit(1);
				}
			};
			sync_labels(labels, check_duplicate_colors);
		}
		Commands::SyncConventions { version_key, file } => {
			if file.is_empty() {
				eprintln!("ERROR: No convention files specified. Use --file PATH to specify files.");
				std::process::exit(1);
			}
			sync_conventions(version_key, file);
		}
		Commands::StripHistory { yes } => strip_history(yes),
		Commands::InitDeployKey { target } => init_deploy_key(target),
	}
}
