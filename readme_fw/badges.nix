{
  pkgs,
  rootDir,
  pname,
  lastSupportedVersion,
  gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb",
  logo ? "",
  branch ? "main",
}: let
  # Owner/repo can't be known at eval time (the flake source has no `.git`), so the
  # CI badges carry a sentinel that readme_fw's shellHook resolves from `origin`.
  repo = "@@REPO_SLUG@@";
  badges = {
    msrv = ''![Minimum Supported Rust Version](https://img.shields.io/badge/${lastSupportedVersion}+-ab6000.svg)'';

    crates_io = ''[<img alt="crates.io" src="https://img.shields.io/crates/v/${pname}.svg?color=fc8d62&logo=rust" height="20" style=flat-square>](https://crates.io/crates/${pname})'';

    docs_rs = ''[<img alt="docs.rs" src="https://img.shields.io/badge/docs.rs-66c2a5?style=for-the-badge&labelColor=555555&logo=docs.rs&style=flat-square" height="20">](https://docs.rs/${pname})'';

    # Dynamic LOC badge - fetches from GitHub gist updated by workflow
    # Each project gets its own file in the shared gist: ${pname}-loc.json
    loc = ''![Lines Of Code](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/valeratrades/${gistId}/raw/${pname}-loc.json)'';

    # note that it is possible to remove all references to the default branch and have it automatically use the current branch. But that would require running them on `on.push.branches: [**]`.
    ci = ''      <br>
      [<img alt="ci errors" src="https://img.shields.io/github/actions/workflow/status/${repo}/errors.yml?branch=${branch}&style=for-the-badge&style=flat-square&label=errors&labelColor=420d09" height="20">](https://github.com/${repo}/actions?query=branch%3A${branch}) <!--NB: Won't find it if repo is private-->
      [<img alt="ci warnings" src="https://img.shields.io/github/actions/workflow/status/${repo}/warnings.yml?branch=${branch}&style=for-the-badge&style=flat-square&label=warnings&labelColor=d16002" height="20">](https://github.com/${repo}/actions?query=branch%3A${branch}) <!--NB: Won't find it if repo is private-->'';
  };
  combineBadges = names: let
    logoSuffix = if logo != "" then " ${logo}" else "";
    header = "# ${pname}${logoSuffix}";
    mainBadges = builtins.concatStringsSep "\n" (map (name: badges.${name}) names);
  in
    pkgs.runCommand "" {} ''
            cat > $out <<'EOF'
      ${header}
      ${mainBadges}
      EOF'';
in {
  inherit combineBadges;
}
