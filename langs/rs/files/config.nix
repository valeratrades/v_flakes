{ pkgs
, cranelift ? true
, webUnstable ? false
, kache ? true
, extend ? { }
,
}:
let
  core = import ../../../utils/core.nix;
  # A `--cfg` is the building crate's choice, never its dependents': a library built with it
  # compiles against a web-sys API its crates.io users don't get.
  webCfg = if webUnstable then [ "--cfg" "web_sys_unstable_apis" ] else [ ];

  base = {
    build.rustc-wrapper = if kache then "kache" else ""; # "" also turns off the global wrapper ~/.cargo/config.toml sets
    target = {
      "x86_64-unknown-linux-gnu".rustflags = [
        "-C"
        "link-arg=-fuse-ld=mold"
        "--cfg"
        "tokio_unstable"
        "-Z"
        "threads=8"
        "-Z"
        "track-diagnostics"
        #"--cfg" "procmacro2_semver_exempt"
      ] ++ webCfg;
    } // (if webUnstable then { "wasm32-unknown-unknown".rustflags = webCfg; } else { });
  } // (if cranelift then {
    profile = {
      rust = {
        codegen-backend = "cranelift";
      };
    };
  } else { });

  # A worktree in `.claude/worktrees/` is nested in main's checkout, and cargo concatenates arrays
  # across every config.toml up the tree: worktrees would build with each flag twice, hashing apart
  # from main. A string is taken from the closest file only.
  joinFlags = flags:
    assert pkgs.lib.assertMsg (builtins.all (f: builtins.match ".*[[:space:]].*" f == null) flags)
      "rs config: rustflags are written as one string cargo splits on whitespace, so no flag may contain it: ${builtins.toJSON flags}";
    builtins.concatStringsSep " " flags;
  merged = core.mergeConfig base extend;
  stringified = merged
    // pkgs.lib.optionalAttrs (merged ? target) { target = builtins.mapAttrs (_: t: t // pkgs.lib.optionalAttrs (t ? rustflags) { rustflags = joinFlags t.rustflags; }) merged.target; }
    // pkgs.lib.optionalAttrs (merged.build or { } ? rustflags) { build = merged.build // { rustflags = joinFlags merged.build.rustflags; }; };
in
(pkgs.formats.toml { }).generate "config.toml" stringified
