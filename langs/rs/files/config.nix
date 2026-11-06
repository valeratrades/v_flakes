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
  # nixpkgs' rustPlatform writes `target.<host triple>.rustflags` as an array into the sandbox's
  # `/build/.cargo/config.toml`, above the source; a string on that same key fails to merge, a cfg key is joined.
  tripleCfg = {
    "x86_64-unknown-linux-gnu" = ''cfg(all(target_arch = "x86_64", target_os = "linux", target_env = "gnu"))'';
    "wasm32-unknown-unknown" = ''cfg(all(target_arch = "wasm32", target_os = "unknown"))'';
  };
  cfgKey = triple: tripleCfg.${triple} or (throw "rs config: rustflags for `${triple}` need its cfg() in tripleCfg (langs/rs/files/config.nix)");
  merged = core.mergeConfig base extend;
  rustflagsByCfg = pkgs.lib.mapAttrs' (triple: t: { name = cfgKey triple; value.rustflags = joinFlags t.rustflags; })
    (pkgs.lib.filterAttrs (_: t: t ? rustflags) merged.target);
  stringified = merged
    // pkgs.lib.optionalAttrs (merged ? target) {
    target = pkgs.lib.filterAttrs (_: t: t != { }) (builtins.mapAttrs (_: t: removeAttrs t [ "rustflags" ]) merged.target) // rustflagsByCfg;
  }
    // pkgs.lib.optionalAttrs (merged.build or { } ? rustflags) { build = merged.build // { rustflags = joinFlags merged.build.rustflags; }; };
in
(pkgs.formats.toml { }).generate "config.toml" stringified
