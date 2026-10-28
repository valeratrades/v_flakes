use std::{
	collections::BTreeMap,
	io::BufRead,
	path::{Path, PathBuf},
	process::{Command, Stdio},
};

use serde_json::{Value, json};

use crate::gh;

const PLACEHOLDER: &str = "<!-- v_flakes clean-up-gitlfs-dangerous placeholder -->";

struct Ctx<'a> {
	owner: &'a str,
	name: &'a str,
	bak: String,
	clean: String,
	dir: PathBuf,
}

/// The source's history, fetched into `Ctx::dir` and rewritten without the dropped LFS pointers.
struct Prepared {
	/// oid → size, over branch tips
	kept: BTreeMap<String, u64>,
	/// oid → size, over all of history
	all: BTreeMap<String, u64>,
	rewritten: usize,
}

pub(crate) fn run(repo: &str) -> Result<(), String> {
	let (owner, name) = repo
		.split_once('/')
		.filter(|(o, n)| !o.is_empty() && !n.is_empty() && !n.contains('/'))
		.ok_or_else(|| format!("expected OWNER/REPO, got `{repo}`"))?;
	for (tool, args) in [
		("gh", &["--version"][..]),
		("git", &["--version"]),
		("git", &["lfs", "version"]),
		("git", &["filter-repo", "--version"]),
	] {
		let ok = Command::new(tool).args(args).output().is_ok_and(|o| o.status.success());
		if !ok {
			return Err(format!("`{tool} {}` must work (nixpkgs: gh, git, git-lfs, git-filter-repo)", args.join(" ")));
		}
	}
	let c = Ctx {
		owner,
		name,
		bak: format!("{name}.bak"),
		clean: format!("{name}-lfs-clean"),
		dir: std::env::temp_dir().join(format!("v_flakes-lfs-clean-{owner}-{name}")),
	};

	match (get(owner, name)?, get(owner, &c.clean)?, get(owner, &c.bak)?) {
		(Some(src), clean, None) => migrate(&c, &src, clean.is_some())?,
		(None, Some(_), Some(_)) => {
			println!("resuming: {name} was already renamed to {}", c.bak);
			rename(owner, &c.clean, name)?;
		}
		(Some(_), None, Some(b)) if b["archived"] == true =>
			return Err(format!(
				"already done: https://github.com/{owner}/{} is archived; delete it once every LFS file you care about checks out from {owner}/{name}",
				c.bak
			)),
		(Some(n), None, Some(b)) => {
			// tips never hold a dropped object, so the rewrite leaves their trees alone
			let tree = |r: &str, v: &Value| -> Result<String, String> {
				let branch = v["default_branch"].as_str().expect("repo has a default_branch");
				Ok(api(&[&format!("repos/{owner}/{r}/commits/{branch}")])?["commit"]["tree"]["sha"]
					.as_str()
					.expect("commit has a tree")
					.to_owned())
			};
			if tree(&c.bak, &b)? != tree(name, &n)? {
				return Err(format!(
					"{owner}/{} and {owner}/{name} have different default-branch trees: either {owner}/{} isn't a leftover of this command, or something was pushed after the renames",
					c.bak, c.bak
				));
			}
			println!("resuming: both renames are done");
		}
		(src, clean, bak) => {
			let s = |v: &Option<Value>| if v.is_some() { "exists" } else { "absent" };
			return Err(format!("unexpected state: {name} {}, {} {}, {} {}", s(&src), c.clean, s(&clean), c.bak, s(&bak)));
		}
	}
	finalize(&c)
}

fn migrate(c: &Ctx, src: &Value, resuming: bool) -> Result<(), String> {
	let (o, name) = (c.owner, c.name);
	if src["archived"] == true {
		return Err(format!("{o}/{name} is archived"));
	}
	let discussions = api(&[
		"graphql",
		"-f",
		"query=query($o:String!,$n:String!){repository(owner:$o,name:$n){discussions(first:100){totalCount nodes{url}}}}",
		"-f",
		&format!("o={o}"),
		"-f",
		&format!("n={name}"),
	])?;
	let d = &discussions["data"]["repository"]["discussions"];
	if d["totalCount"].as_u64().expect("totalCount is a number") > 0 {
		let urls: Vec<_> = d["nodes"]
			.as_array()
			.expect("nodes is an array")
			.iter()
			.map(|n| n["url"].as_str().expect("url is a string"))
			.collect();
		return Err(format!("discussions can only be moved in the UI; move or delete them first:\n  {}", urls.join("\n  ")));
	}

	let p = prepare(c, name)?;
	let gb = |keep: bool| p.all.iter().filter(|(oid, _)| p.kept.contains_key(*oid) == keep).map(|(_, s)| *s).sum::<u64>() as f64 / 1e9;
	let items = issue_numbers(o, name)?;
	println!("\n{o}/{name} → new repo with the same history minus dropped LFS objects; those stay behind in {o}/{}", c.bak);
	println!("  LFS kept (∪ branch tips): {} objects, {:.2} GB", p.kept.len(), gb(true));
	println!("  LFS dropped:              {} objects, {:.2} GB", p.all.len() - p.kept.len(), gb(false));
	println!("  commits getting a new SHA: {}", p.rewritten);
	let done = if resuming { issue_numbers(o, &c.clean)?.keys().max().copied().unwrap_or(0) } else { 0 };
	let max = items.keys().max().copied().unwrap_or(0).max(done);
	println!("  numbers 1..={max}:");
	let kind = |n: u64| match items.get(&n) {
		_ if n <= done => "already moved",
		Some(i) if i.get("pull_request").is_none() => "transfer",
		Some(_) => "placeholder (PR)",
		None => "placeholder (gap)",
	};
	let mut start = 1;
	for n in 1..=max {
		if n == max || kind(n + 1) != kind(n) {
			println!("    {start}..={n}: {}", kind(n));
			start = n + 1;
		}
	}
	println!("  then by hand:");
	for m in manual_steps(o, name, src, p.rewritten)? {
		println!("    - {m}");
	}
	println!("\ntype `{o}/{name}` to continue:");
	let mut line = String::new();
	std::io::stdin().lock().read_line(&mut line).map_err(|e| format!("reading stdin: {e}"))?;
	if line.trim() != format!("{o}/{name}") {
		return Err("not confirmed".into());
	}

	let to = c.clean.as_str();
	if resuming {
		println!("{o}/{to} exists, resuming into it");
	} else {
		let visibility = src["visibility"].as_str().expect("repo has a visibility");
		gh(&["repo", "create", &format!("{o}/{to}"), &format!("--{visibility}")], None)?;
	}
	send("PUT", &format!("repos/{o}/{to}/actions/permissions"), &json!({ "enabled": false }))?;
	push(c, to, &p)?;

	let mut keys = vec![
		"description",
		"homepage",
		"has_projects",
		"has_wiki",
		"has_discussions",
		"allow_merge_commit",
		"allow_squash_merge",
		"allow_rebase_merge",
		"allow_auto_merge",
		"delete_branch_on_merge",
		"allow_update_branch",
		"squash_merge_commit_title",
		"squash_merge_commit_message",
		"merge_commit_title",
		"merge_commit_message",
		"web_commit_signoff_required",
		"is_template",
		"default_branch",
	];
	if src["visibility"] != "public" {
		keys.push("allow_forking");
	}
	let mut settings = fields(src, &keys);
	settings["has_issues"] = json!(true); // transfers need it; finalize sets the real value
	send("PATCH", &format!("repos/{o}/{to}"), &settings)?;
	send("PUT", &format!("repos/{o}/{to}/topics"), &json!({ "names": src["topics"] }))?;
	if src["owner"]["type"] == "Organization" {
		let props: Vec<_> = api(&[&format!("repos/{o}/{name}/properties/values")])?
			.as_array()
			.expect("array")
			.iter()
			.filter(|p| !p["value"].is_null())
			.cloned()
			.collect();
		send("PATCH", &format!("repos/{o}/{to}/properties/values"), &json!({ "properties": props }))?;
		for t in list(&format!("repos/{o}/{name}/teams"), None)? {
			send(
				"PUT",
				&format!("orgs/{o}/teams/{}/repos/{o}/{to}", t["slug"].as_str().expect("slug")),
				&fields(&t, &["permission"]),
			)?;
		}
	}
	let me = api(&["user"])?["login"].as_str().expect("login").to_owned();
	for u in list(&format!("repos/{o}/{name}/collaborators?affiliation=direct"), None)? {
		let login = u["login"].as_str().expect("login");
		if login == me {
			continue;
		}
		let permission = match u["role_name"].as_str().expect("role_name") {
			"read" => "pull",
			"write" => "push",
			r => r,
		};
		send("PUT", &format!("repos/{o}/{to}/collaborators/{login}"), &json!({ "permission": permission }))?;
	}

	let have: Vec<Value> = list(&format!("repos/{o}/{to}/labels"), None)?;
	let want: Vec<Value> = list(&format!("repos/{o}/{name}/labels"), None)?;
	let lower = |l: &Value| l["name"].as_str().expect("label name").to_lowercase();
	for h in &have {
		if !want.iter().any(|w| lower(w) == lower(h)) {
			send("DELETE", &format!("repos/{o}/{to}/labels/{}", enc(h["name"].as_str().expect("label name"))), &Value::Null)?;
		}
	}
	for w in &want {
		let body = fields(w, &["name", "color", "description"]);
		match have.iter().find(|h| lower(h) == lower(w)) {
			None => send("POST", &format!("repos/{o}/{to}/labels"), &body)?,
			Some(h) if fields(h, &["name", "color", "description"]) != body => {
				let mut b = body.clone();
				b["new_name"] = b["name"].take();
				send("PATCH", &format!("repos/{o}/{to}/labels/{}", enc(h["name"].as_str().expect("label name"))), &b)?
			}
			Some(_) => Value::Null,
		};
	}

	let have = list(&format!("repos/{o}/{to}/milestones?state=all"), None)?;
	for m in list(&format!("repos/{o}/{name}/milestones?state=all"), None)? {
		let mut body = fields(&m, &["title", "state", "description", "due_on"]);
		if let Some(due) = m["due_on"].as_str() {
			body["due_on"] = json!(format!("{}T12:00:00Z", &due[..10])); // POST stores midnight UTC as the previous day; the transfer matches milestones on title + due date
		}
		match have.iter().find(|h| h["title"] == m["title"]) {
			Some(h) => send("PATCH", &format!("repos/{o}/{to}/milestones/{}", h["number"]), &body)?,
			None => send("POST", &format!("repos/{o}/{to}/milestones"), &body)?,
		};
	}

	let have = list(&format!("repos/{o}/{to}/releases"), None)?;
	for r in list(&format!("repos/{o}/{name}/releases"), None)?.into_iter().rev() {
		let new = match have.iter().find(|h| h["tag_name"] == r["tag_name"]) {
			Some(h) => h.clone(),
			// no target_commitish: it may name a pre-rewrite SHA, and the pushed tag decides the commit anyway
			None => send("POST", &format!("repos/{o}/{to}/releases"), &fields(&r, &["tag_name", "name", "body", "draft", "prerelease"]))?,
		};
		let dir = c.dir.join("assets").join(r["id"].to_string());
		std::fs::create_dir_all(&dir).map_err(|e| format!("creating {}: {e}", dir.display()))?;
		for a in r["assets"].as_array().expect("assets is an array") {
			let asset = a["name"].as_str().expect("asset name");
			if new["assets"].as_array().expect("assets is an array").iter().any(|h| h["name"] == asset) {
				continue;
			}
			let path = dir.join(asset);
			let bytes = gh(&["api", &format!("repos/{o}/{name}/releases/assets/{}", a["id"]), "-H", "Accept: application/octet-stream"], None)?;
			std::fs::write(&path, bytes).map_err(|e| format!("writing {}: {e}", path.display()))?;
			let upload = new["upload_url"].as_str().expect("upload_url").split('{').next().expect("split yields one part");
			gh(
				&[
					"api",
					"-X",
					"POST",
					&format!("{upload}?name={}", enc(asset)),
					"--input",
					path.to_str().expect("tmp path is utf-8"),
					"-H",
					"Content-Type: application/octet-stream",
				],
				None,
			)?;
		}
	}

	for v in list(&format!("repos/{o}/{name}/actions/variables"), Some("variables"))? {
		gh(
			&[
				"variable",
				"set",
				v["name"].as_str().expect("name"),
				"--body",
				v["value"].as_str().expect("value"),
				"-R",
				&format!("{o}/{to}"),
			],
			None,
		)?;
	}

	walk(c, name, to)?;
	rename(o, name, &c.bak)?;
	rename(o, to, name)
}

/// Everything that has to happen once the new repo answers to the old name: the old one is `.bak` and gets frozen.
fn finalize(c: &Ctx) -> Result<(), String> {
	let (o, name, bak) = (c.owner, c.name, c.bak.as_str());
	let src = get(o, bak)?.expect("finalize runs after the first rename");
	let p = prepare(c, bak)?;
	push(c, name, &p)?;
	walk(c, bak, name)?;
	let mut manual = manual_steps(o, bak, &src, p.rewritten)?;

	let dst_prs = list(&format!("repos/{o}/{name}/pulls?state=all"), None)?;
	for pr in list(&format!("repos/{o}/{bak}/pulls?state=open"), None)? {
		let n = pr["number"].as_u64().expect("number");
		let origin = format!("https://github.com/{o}/{bak}/pull/{n}");
		if pr["head"]["repo"]["full_name"] != format!("{o}/{bak}") {
			manual.push(format!("{origin}: head is on a fork, re-open it by hand"));
			continue;
		}
		let new = match dst_prs.iter().find(|p| p["body"].as_str().is_some_and(|b| b.contains(&origin))) {
			Some(p) => p.clone(),
			None => {
				let body = format!("Re-created from {origin}\n\n{}", pr["body"].as_str().unwrap_or("")); // null body: the PR has no description
				let new = send(
					"POST",
					&format!("repos/{o}/{name}/pulls"),
					&json!({ "title": pr["title"], "head": pr["head"]["ref"], "base": pr["base"]["ref"], "draft": pr["draft"], "body": body }),
				)?;
				let names = |k: &str, f: &str| pr[k].as_array().expect("array").iter().map(|x| x[f].clone()).collect::<Vec<_>>();
				send(
					"PATCH",
					&format!("repos/{o}/{name}/issues/{}", new["number"]),
					&json!({ "labels": names("labels", "name"), "assignees": names("assignees", "login") }),
				)?;
				new
			}
		};
		let body = format!(
			"{PLACEHOLDER}\nPull request, kept read-only at {origin}; continued at {}",
			new["html_url"].as_str().expect("html_url")
		);
		send("PATCH", &format!("repos/{o}/{name}/issues/{n}"), &json!({ "body": body }))?;
	}

	send("PATCH", &format!("repos/{o}/{name}"), &fields(&src, &["has_issues"]))?;

	let have = list(&format!("repos/{o}/{name}/rulesets?includes_parents=false"), None)?;
	for r in list(&format!("repos/{o}/{bak}/rulesets?includes_parents=false"), None)? {
		let full = api(&[&format!("repos/{o}/{bak}/rulesets/{}", r["id"])])?;
		let body = fields(&full, &["name", "target", "enforcement", "bypass_actors", "conditions", "rules"]);
		match have.iter().find(|h| h["name"] == r["name"]) {
			Some(h) => send("PUT", &format!("repos/{o}/{name}/rulesets/{}", h["id"]), &body)?,
			None => send("POST", &format!("repos/{o}/{name}/rulesets"), &body)?,
		};
	}

	// a deploy key can be attached to one repo at a time
	for k in list(&format!("repos/{o}/{bak}/keys"), None)? {
		let lost = format!(
			"deploy key `{}` (read_only: {}) is off {o}/{bak} but not on {o}/{name}; add it by hand: {}",
			k["title"], k["read_only"], k["key"]
		);
		send("DELETE", &format!("repos/{o}/{bak}/keys/{}", k["id"]), &Value::Null)?;
		send("POST", &format!("repos/{o}/{name}/keys"), &fields(&k, &["title", "key", "read_only"])).map_err(|e| format!("{e}\n{lost}"))?;
	}

	if src["has_wiki"] == true {
		let from = format!("https://github.com/{o}/{bak}.wiki.git");
		let probe = Command::new("git")
			.args(CRED)
			.args(["ls-remote", &from])
			.env("GIT_TERMINAL_PROMPT", "0")
			.output()
			.map_err(|e| format!("spawning git: {e}"))?;
		let stderr = String::from_utf8_lossy(&probe.stderr);
		if probe.status.success() {
			let wiki = c.dir.join("wiki.git");
			if !wiki.exists() {
				git(&c.dir, &["clone", "--mirror", &from, "wiki.git"], None)?;
			}
			git(&wiki, &["fetch", "--prune", &from, "+refs/*:refs/*"], None)?;
			if let Err(e) = git(&wiki, &["push", "--mirror", &format!("https://github.com/{o}/{name}.wiki.git")], None) {
				manual.push(format!(
					"wiki: {e}. GitHub only accepts a wiki push once the first page exists: create one in the UI, then `git -C {} push --mirror https://github.com/{o}/{name}.wiki.git`",
					wiki.display()
				));
			}
		} else if !stderr.contains("not found") {
			// GitHub creates <repo>.wiki.git with the first page, so a wiki-enabled repo without pages answers "not found"
			return Err(format!("git ls-remote {from}: {}", stderr.trim()));
		}
	}

	let perms = api(&[&format!("repos/{o}/{bak}/actions/permissions")])?;
	send("PUT", &format!("repos/{o}/{name}/actions/permissions"), &fields(&perms, &["enabled", "allowed_actions"]))?;
	if perms["enabled"] == true {
		if perms["allowed_actions"] == "selected" {
			let s = api(&[&format!("repos/{o}/{bak}/actions/permissions/selected-actions")])?;
			send("PUT", &format!("repos/{o}/{name}/actions/permissions/selected-actions"), &s)?;
		}
		let w = api(&[&format!("repos/{o}/{bak}/actions/permissions/workflow")])?;
		send("PUT", &format!("repos/{o}/{name}/actions/permissions/workflow"), &w)?;
	}

	send("PATCH", &format!("repos/{o}/{bak}"), &json!({ "archived": true }))?;
	std::fs::remove_dir_all(&c.dir).map_err(|e| format!("removing {}: {e}", c.dir.display()))?;

	println!("\ndone. {o}/{name} has the history minus dropped LFS objects, and every issue at its old number.");
	println!("archived: https://github.com/{o}/{bak}");
	println!("  delete it once every LFS file you care about checks out from {o}/{name}; that is what frees the storage");
	println!("by hand:");
	for m in manual {
		println!("  - {m}");
	}
	Ok(())
}

/// Moves issues across at their own numbers, filling PRs and gaps with closed placeholders, so `issues/N` links keep resolving.
fn walk(c: &Ctx, from: &str, to: &str) -> Result<(), String> {
	let o = c.owner;
	let src = issue_numbers(o, from)?;
	let dst = issue_numbers(o, to)?;
	for (n, d) in &dst {
		match src.get(n) {
			Some(s) if s.get("pull_request").is_none() => return Err(format!("{o}/{to}#{n} is taken, yet {o}/{from}#{n} is still an issue there")),
			Some(_) if !d["body"].as_str().is_some_and(|b| b.contains(PLACEHOLDER)) => return Err(format!("{o}/{from}#{n} is a PR, but {o}/{to}#{n} isn't its placeholder")),
			_ => {}
		}
	}
	let to_id = get(o, to)?.expect("target exists")["node_id"].as_str().expect("node_id").to_owned();
	let done = dst.keys().max().copied().unwrap_or(0);
	for n in done + 1..=src.keys().max().copied().unwrap_or(0) {
		let got = match src.get(&n) {
			Some(i) if i.get("pull_request").is_none() => {
				let r = api(&[
					"graphql",
					"-f",
					"query=mutation($i:ID!,$r:ID!){transferIssue(input:{issueId:$i,repositoryId:$r,createLabelsIfMissing:true}){issue{number}}}",
					"-f",
					&format!("i={}", i["node_id"].as_str().expect("node_id")),
					"-f",
					&format!("r={to_id}"),
				])?;
				r["data"]["transferIssue"]["issue"]["number"]
					.as_u64()
					.ok_or_else(|| format!("transferring {o}/{from}#{n}: {r}"))?
			}
			pr => {
				let (title, what) = match pr {
					Some(pr) => (
						format!("PR #{n}: {}", pr["title"].as_str().expect("title")),
						format!("Pull request, kept read-only at https://github.com/{o}/{}/pull/{n}", c.bak),
					),
					None => (
						format!("#{n}: placeholder"),
						format!("#{n} was deleted (or a discussion) in https://github.com/{o}/{}; this keeps later numbers in place", c.bak),
					),
				};
				let issue = send("POST", &format!("repos/{o}/{to}/issues"), &json!({ "title": title, "body": format!("{PLACEHOLDER}\n{what}") }))?;
				let got = issue["number"].as_u64().expect("number");
				send("PATCH", &format!("repos/{o}/{to}/issues/{got}"), &json!({ "state": "closed", "state_reason": "not_planned" }))?;
				got
			}
		};
		if got != n {
			return Err(format!("{o}/{from}#{n} landed as {o}/{to}#{got}: something else took a number in {o}/{to} meanwhile"));
		}
		println!("#{n}");
	}
	Ok(())
}

/// GitHub refuses a push whose history points at an LFS object it doesn't have (GH008), so the pointers to dropped objects leave the history.
fn prepare(c: &Ctx, from: &str) -> Result<Prepared, String> {
	if !c.dir.exists() {
		std::fs::create_dir_all(&c.dir).map_err(|e| format!("creating {}: {e}", c.dir.display()))?;
		git(&c.dir, &["init", "--bare", "--quiet"], None)?;
	}
	git(&c.dir, &["config", "remote.from.url", &format!("https://github.com/{}/{from}.git", c.owner)], None)?;
	git(&c.dir, &["fetch", "--prune", "from", "+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"], None)?;
	let kept = lfs_oids(&c.dir, &heads(&c.dir)?)?;
	let all = lfs_oids(&c.dir, &["--all".to_owned()])?;

	let mut ids = String::new();
	for (oid, size) in all.iter().filter(|(oid, _)| !kept.contains_key(*oid)) {
		let pointer = format!("version https://git-lfs.github.com/spec/v1\noid sha256:{oid}\nsize {size}\n");
		let id = git(&c.dir, &["hash-object", "--stdin"], Some(&pointer))?;
		git(&c.dir, &["cat-file", "-e", id.trim()], None).map_err(|e| format!("{e}: the pointer to {oid} isn't in canonical form, so its blob can't be found"))?;
		ids += &id;
	}
	if ids.is_empty() {
		return Ok(Prepared { kept, all, rewritten: 0 });
	}
	let list = c.dir.join("dropped-blobs");
	std::fs::write(&list, ids).map_err(|e| format!("writing {}: {e}", list.display()))?;
	let list = list.to_str().expect("tmp path is utf-8");
	git(
		&c.dir,
		&[
			"filter-repo",
			"--force",
			"--quiet",
			"--prune-empty",
			"never",
			"--prune-degenerate",
			"never",
			"--strip-blobs-with-ids",
			list,
		],
		None,
	)?;
	let map = std::fs::read_to_string(c.dir.join("filter-repo/commit-map")).map_err(|e| format!("reading filter-repo's commit-map: {e}"))?;
	let rewritten = map.lines().skip(1).filter(|l| l.split_once(' ').is_some_and(|(old, new)| old != new)).count();
	Ok(Prepared { kept, all, rewritten })
}

/// LFS objects first: with them in place the push passes GH008.
fn push(c: &Ctx, to: &str, p: &Prepared) -> Result<(), String> {
	git(&c.dir, &["config", "remote.to.url", &format!("https://github.com/{}/{to}.git", c.owner)], None)?;
	let mut args = vec!["lfs", "fetch", "from"];
	let heads = heads(&c.dir)?;
	args.extend(heads.iter().map(String::as_str));
	git(&c.dir, &args, None)?;
	let oids: String = p.kept.keys().map(|k| format!("{k}\n")).collect();
	git(&c.dir, &["lfs", "push", "--object-id", "--stdin", "to"], Some(&oids))?;
	git(
		&c.dir,
		&["push", "--no-verify", "--force", "--prune", "to", "refs/heads/*:refs/heads/*", "refs/tags/*:refs/tags/*"],
		None,
	)?;
	Ok(())
}

fn heads(dir: &Path) -> Result<Vec<String>, String> {
	Ok(git(dir, &["for-each-ref", "--format=%(refname)", "refs/heads"], None)?.lines().map(str::to_owned).collect())
}

/// oid → size of the LFS pointers in `refs`' trees (`--all`: in all of history)
fn lfs_oids(dir: &Path, refs: &[String]) -> Result<BTreeMap<String, u64>, String> {
	let mut out = BTreeMap::new();
	for r in refs {
		let json = git(dir, &["lfs", "ls-files", "--json", r], None)?;
		let v: Value = serde_json::from_str(&json).map_err(|e| format!("parsing `git lfs ls-files --json {r}`: {e}"))?;
		for f in v["files"].as_array().expect("files is an array") {
			out.insert(f["oid"].as_str().expect("oid").to_owned(), f["size"].as_u64().expect("size"));
		}
	}
	Ok(out)
}

fn issue_numbers(o: &str, repo: &str) -> Result<BTreeMap<u64, Value>, String> {
	Ok(list(&format!("repos/{o}/{repo}/issues?state=all"), None)?
		.into_iter()
		.map(|i| (i["number"].as_u64().expect("number"), i))
		.collect())
}

fn manual_steps(o: &str, repo: &str, src: &Value, rewritten: usize) -> Result<Vec<String>, String> {
	let names = |v: Vec<Value>| v.iter().map(|x| x["name"].as_str().expect("name").to_owned()).collect::<Vec<_>>().join(", ");
	let mut out = Vec::new();
	if rewritten > 0 {
		out.push(format!(
			"{rewritten} commits get new SHAs: every clone re-clones (or `git fetch && git reset --hard origin/<branch>`), every pinned rev (flake.lock) gets updated, and links to old SHAs only resolve in the .bak until it is deleted"
		));
	}
	for (kind, endpoint) in [("Actions", "actions/secrets"), ("Dependabot", "dependabot/secrets")] {
		let s = list(&format!("repos/{o}/{repo}/{endpoint}"), Some("secrets"))?;
		if !s.is_empty() {
			out.push(format!("{kind} secrets (values aren't readable): {}", names(s)));
		}
	}
	let envs = api(&[&format!("repos/{o}/{repo}/environments")])?["environments"]
		.as_array()
		.expect("environments is an array")
		.clone();
	if !envs.is_empty() {
		out.push(format!("environments: {}", names(envs)));
	}
	for h in list(&format!("repos/{o}/{repo}/hooks"), None)? {
		out.push(format!("webhook {} on {}, with its secret", h["config"]["url"], h["events"]));
	}
	let protected = list(&format!("repos/{o}/{repo}/branches?protected=true"), None)?;
	if !protected.is_empty() {
		out.push(format!("classic branch protection: {}", names(protected)));
	}
	if src["has_pages"] == true {
		out.push("GitHub Pages".into());
	}
	out.push("ghcr packages that grant Actions access to this repo: grant it again, the repo id changed".into());
	Ok(out)
}

fn rename(o: &str, from: &str, to: &str) -> Result<(), String> {
	send("PATCH", &format!("repos/{o}/{from}"), &json!({ "name": to }))?;
	println!("renamed {o}/{from} → {o}/{to}");
	Ok(())
}

/// `None` when absent. A renamed repo's old name redirects to it, hence the name check.
fn get(o: &str, name: &str) -> Result<Option<Value>, String> {
	match api(&[&format!("repos/{o}/{name}")]) {
		Ok(v) => Ok((v["name"] == name).then_some(v)),
		Err(e) if e.contains("HTTP 404") => Ok(None),
		Err(e) => Err(e),
	}
}

fn api(args: &[&str]) -> Result<Value, String> {
	parse(&gh(&[&["api"], args].concat(), None)?, args)
}

fn send(method: &str, endpoint: &str, body: &Value) -> Result<Value, String> {
	let args = ["-X", method, endpoint, "--input", "-"];
	parse(&gh(&[&["api"], &args[..]].concat(), Some(&body.to_string()))?, &args)
}

fn parse(out: &[u8], args: &[&str]) -> Result<Value, String> {
	if out.is_empty() {
		return Ok(Value::Null); // 204
	}
	serde_json::from_slice(out).map_err(|e| format!("parsing gh api {}: {e}", args.join(" ")))
}

/// All pages of a list endpoint; `key` names the array when pages are objects.
fn list(endpoint: &str, key: Option<&str>) -> Result<Vec<Value>, String> {
	let sep = if endpoint.contains('?') { '&' } else { '?' };
	let pages = api(&["--paginate", "--slurp", &format!("{endpoint}{sep}per_page=100")])?;
	Ok(pages
		.as_array()
		.expect("--slurp yields an array of pages")
		.iter()
		.flat_map(|p| match key {
			Some(k) => p[k].as_array().expect("keyed page holds an array").clone(),
			None => p.as_array().expect("page is an array").clone(),
		})
		.collect())
}

fn fields(v: &Value, keys: &[&str]) -> Value {
	Value::Object(keys.iter().filter(|k| !v[**k].is_null()).map(|k| (k.to_string(), v[*k].clone())).collect())
}

fn enc(s: &str) -> String {
	s.bytes()
		.map(|b| {
			if b.is_ascii_alphanumeric() || b"-_.~".contains(&b) {
				(b as char).to_string()
			} else {
				format!("%{b:02X}")
			}
		})
		.collect()
}

/// gh as the credential helper, so git and git-lfs authenticate with gh's token
const CRED: [&str; 4] = ["-c", "credential.helper=", "-c", "credential.helper=!gh auth git-credential"];

/// stderr is inherited, so long fetches and pushes show progress
fn git(dir: &Path, args: &[&str], stdin: Option<&str>) -> Result<String, String> {
	let mut child = Command::new("git")
		.args(CRED)
		.arg("-C")
		.arg(dir)
		.args(args)
		.env("GIT_TERMINAL_PROMPT", "0")
		.stdin(if stdin.is_some() { Stdio::piped() } else { Stdio::null() })
		.stdout(Stdio::piped())
		.spawn()
		.map_err(|e| format!("spawning git: {e}"))?;
	if let Some(input) = stdin {
		use std::io::Write;
		child.stdin.take().expect("piped above").write_all(input.as_bytes()).map_err(|e| format!("writing to git: {e}"))?;
	}
	let out = child.wait_with_output().map_err(|e| format!("waiting on git: {e}"))?;
	if !out.status.success() {
		return Err(format!("git {} failed ({})", args.join(" "), out.status));
	}
	String::from_utf8(out.stdout).map_err(|e| format!("git {} printed non-utf-8: {e}", args.join(" ")))
}
