{ pkgs
, rootDir
, pname
, lastSupportedVersion
, gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb"
, logo ? ""
, branch ? "main"
,
}:
let
  # Owner/repo can't be known at eval time (the flake source has no `.git`), so the
  # CI badges carry a sentinel that readme_fw's shellHook resolves from `origin`.
  repo = "@@REPO_SLUG@@";
  gistBadge = alt: key: ''![${alt}](https://img.shields.io/endpoint?url=https://gist.githubusercontent.com/valeratrades/${gistId}/raw/${pname}-${key}.json)'';
  badges = {
    msrv = ''![Minimum Supported Rust Version](https://img.shields.io/badge/${lastSupportedVersion}+-ab6000.svg)'';

    crates_io = ''[<img alt="crates.io" src="https://img.shields.io/crates/v/${pname}.svg?color=fc8d62&logo=rust" height="20" style=flat-square>](https://crates.io/crates/${pname})'';

    docs_rs = ''[<img alt="docs.rs" src="https://img.shields.io/badge/docs.rs-66c2a5?style=for-the-badge&labelColor=555555&logo=docs.rs&style=flat-square" height="20">](https://docs.rs/${pname})'';

    # gist files written by CI: `loc` by loc-badge, `build`/`test` by the `report` job on the default branch (rust-tests' prepare and run seconds), `size` by cachix on x86_64-linux, else the x86_64-unknown-linux-gnu release
    loc = gistBadge "Lines Of Code" "loc";
    build_time = gistBadge "Build time" "build";
    test_time = gistBadge "Test time" "test";
    size = gistBadge "Release binary size" "size";

    # gist files written by errors.yml / warnings.yml's `report` job on the default branch: they render for private repos too
    ci = ''      <br>
      [${gistBadge "errors" "errors"}](https://github.com/${repo}/actions/workflows/errors.yml?query=branch%3A${branch})
      [${gistBadge "warnings" "warnings"}](https://github.com/${repo}/actions/workflows/warnings.yml?query=branch%3A${branch})'';
  };
  combineBadges = names:
    let
      logoSuffix = if logo != "" then " ${logo}" else "";
      header = "# ${pname}${logoSuffix}";
      mainBadges = builtins.concatStringsSep "\n" (map (name: badges.${name}) names);
    in
    pkgs.runCommand "" { } ''
            cat > $out <<'EOF'
      ${header}
      ${mainBadges}
      EOF'';
in
{
  inherit combineBadges;
}
