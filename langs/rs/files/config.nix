{ pkgs
, cranelift ? true
, webUnstable ? false
, extend ? { }
,
}:
let
  core = import ../../../utils/core.nix;
  # A `--cfg` is the building crate's choice, never its dependents': a library built with it
  # compiles against a web-sys API its crates.io users don't get.
  webCfg = if webUnstable then [ "--cfg" "web_sys_unstable_apis" ] else [ ];

  base = {
    build.rustc-wrapper = "sccache";
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

  merged = core.mergeConfig base extend;
in
(pkgs.formats.toml { }).generate "config.toml" merged
