use std::{
	collections::HashSet,
	path::{Component, Path, PathBuf},
	process::Command,
};

use toml_edit::{DocumentMut, Item, Value};

#[derive(clap::Args)]
pub struct Args {
	pub path: PathBuf,
}

pub fn run(args: Args) {
	let cargo_files = git_tracked_cargo_tomls(&args.path).expect("discovering Cargo.toml files");
	let mut modified_any = false;
	for rel in cargo_files {
		let path = args.path.join(&rel);
		let content = std::fs::read_to_string(&path).expect("reading Cargo.toml");
		let updated = process(&content, rel.parent().expect("a file path has a parent"));
		if updated != content {
			std::fs::write(&path, &updated).expect("writing Cargo.toml");
			println!("Modified: {}", path.display());
			modified_any = true;
		}
	}
	if !modified_any {
		println!("No Cargo.toml files were modified");
	}
}

enum GaAction {
	/// `#ga: comment` / `#ga: comment out` — remove the dep entirely
	Comment,
	/// `#ga: sub path` / `#ga: substitute path` — replace dep with `version = "*"`
	SubPath,
	/// `#ga: rm path` / `#ga: remove path` — strip the `path` attr from the inline table
	RmPath,
}

impl GaAction {
	fn from_comment(s: &str) -> Option<Self> {
		if s.contains("ga: comment") {
			Some(Self::Comment)
		} else if s.contains("ga: sub path") || s.contains("ga: substitute path") {
			Some(Self::SubPath)
		} else if s.contains("ga: rm path") || s.contains("ga: remove path") {
			Some(Self::RmPath)
		} else {
			None
		}
	}
}

fn ga_action(item: &Item) -> Option<GaAction> {
	let suffix = item.as_value()?.decor().suffix()?.as_str()?;
	let comment = suffix.trim().strip_prefix('#')?.trim();
	GaAction::from_comment(comment)
}

/// `manifest_dir` is relative to the repo root.
fn process(content: &str, manifest_dir: &Path) -> String {
	let mut doc = content.parse::<DocumentMut>().expect("valid TOML");

	// CI checks out this repo alone: a patch into a sibling checkout has nothing to point at, one into this repo still does
	if let Some(patch) = doc.get_mut("patch").and_then(|i| i.as_table_mut()) {
		for (_, source) in patch.iter_mut() {
			let source = source.as_table_like_mut().expect("[patch.<source>] is a table");
			let escaping: Vec<String> = source
				.iter()
				.filter(|(_, dep)| !dep.get("path").and_then(|p| p.as_str()).is_some_and(|p| stays_in_repo(manifest_dir, Path::new(p))))
				.map(|(k, _)| k.to_owned())
				.collect();
			for k in &escaping {
				source.remove(k);
			}
		}
		patch.retain(|_, source| !source.as_table_like().expect("[patch.<source>] is a table").is_empty());
	}
	if doc.get("patch").and_then(|i| i.as_table_like()).is_some_and(|t| t.is_empty()) {
		doc.remove("patch");
	}

	let dep_section_names: Vec<String> = doc.iter().filter(|(k, _)| k.ends_with("dependencies")).map(|(k, _)| k.to_owned()).collect();

	for section in dep_section_names {
		let table = match doc.get_mut(&section).and_then(|i| i.as_table_mut()) {
			Some(t) => t,
			None => continue,
		};

		let keys_to_remove: Vec<String> = table.iter().filter(|(_, v)| matches!(ga_action(v), Some(GaAction::Comment))).map(|(k, _)| k.to_owned()).collect();

		for key in &keys_to_remove {
			table.remove(key);
		}

		for (_, item) in table.iter_mut() {
			match ga_action(item) {
				Some(GaAction::SubPath) => *item = Item::Value(Value::from("*")),
				Some(GaAction::RmPath) =>
					if let Some(inline) = item.as_inline_table_mut() {
						inline.remove("path");
					},
				Some(GaAction::Comment) | None => {}
			}
		}
	}

	doc.to_string()
}

fn git_tracked_cargo_tomls(root: &Path) -> std::io::Result<Vec<PathBuf>> {
	let output = Command::new("git").arg("ls-files").current_dir(root).output()?;
	let tracked: HashSet<PathBuf> = if output.status.success() {
		String::from_utf8_lossy(&output.stdout).lines().map(PathBuf::from).collect()
	} else {
		HashSet::new()
	};
	Ok(tracked.into_iter().filter(|p| p.file_name().map(|n| n == "Cargo.toml").unwrap_or(false)).collect())
}

fn stays_in_repo(manifest_dir: &Path, path: &Path) -> bool {
	let mut depth: usize = 0;
	for c in manifest_dir.join(path).components() {
		match c {
			Component::Normal(_) => depth += 1,
			Component::CurDir => {}
			Component::ParentDir => match depth.checked_sub(1) {
				Some(d) => depth = d,
				None => return false,
			},
			Component::RootDir | Component::Prefix(_) => return false,
		}
	}
	true
}

#[cfg(test)]
mod tests {
	use std::path::Path;

	use super::process;

	#[test]
	fn rm_path_removes_path_attr() {
		insta::assert_snapshot!(process(
			r#"[dependencies]
v_utils = { version = "^2.9.9", path = "../v_utils" } #ga: rm path
serde = { version = "1" }
"#,
			Path::new("")
		), @r#"
		[dependencies]
		v_utils = { version = "^2.9.9"} #ga: rm path
		serde = { version = "1" }
		"#);
	}

	#[test]
	fn sub_path_replaces_with_version_wildcard() {
		insta::assert_snapshot!(process(
			r#"[dependencies]
my_lib = { path = "../my_lib" } #ga: sub path
"#,
			Path::new("")
		), @r#"
		[dependencies]
		my_lib = "*"
		"#);
	}

	#[test]
	fn comment_removes_dep_entirely() {
		insta::assert_snapshot!(process(
			r#"[dependencies]
internal = { path = "../internal" } #ga: comment
serde = { version = "1" }
"#,
			Path::new("")
		), @r#"
		[dependencies]
		serde = { version = "1" }
		"#);
	}

	#[test]
	fn patch_crates_io_removed() {
		insta::assert_snapshot!(process(
			r#"[dependencies]
serde = { version = "1" }

[patch.crates-io]
v_utils = { path = "../v_utils/v_utils" }
v_utils_macros = { path = "../v_utils/v_utils_macros" }
"#,
			Path::new("")
		), @r#"
		[dependencies]
		serde = { version = "1" }
		"#);
	}

	#[test]
	fn patch_into_own_repo_kept() {
		insta::assert_snapshot!(process(
			r#"[dependencies]
serde = { version = "1" }

[patch.crates-io]
own_core = { path = "own_core" }
v_utils = { path = "../v_utils/v_utils" }
"#,
			Path::new("")
		), @r#"
		[dependencies]
		serde = { version = "1" }

		[patch.crates-io]
		own_core = { path = "own_core" }
		"#);
	}

	#[test]
	fn patch_escaping_through_member_dir_removed() {
		insta::assert_snapshot!(process(
			r#"[patch.crates-io]
sibling = { path = "../sibling" }
neighbour = { path = "../../neighbour" }
"#,
			Path::new("member")
		), @r#"
		[patch.crates-io]
		sibling = { path = "../sibling" }
		"#);
	}

	#[test]
	fn unannoted_deps_untouched() {
		let input = "[dependencies]\nserde = { version = \"1\" }\n";
		assert_eq!(process(input, Path::new("")), input);
	}
}
