{
  pkgs,
  cranelift ? true,
  extend ? {},
}:
let
  core = import ../../utils/core.nix;

  base = {
    target = {
      "x86_64-unknown-linux-gnu".rustflags = [
        "-C" "link-arg=-fuse-ld=mold"
        "--cfg" "tokio_unstable"
        "-Z" "threads=8"
        "-Z" "track-diagnostics"
        "--cfg" "web_sys_unstable_apis"
        #"--cfg" "procmacro2_semver_exempt"
      ];
    };
  } // (if cranelift then {
    profile = {
      rust = {
        codegen-backend = "cranelift";
      };
    };
  } else {});

  merged = core.mergeConfig base extend;
in
(pkgs.formats.toml { }).generate "config.toml" merged
