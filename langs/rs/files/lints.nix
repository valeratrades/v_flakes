{ pkgs, extend ? { } }:
let
  core = import ../../../utils/core.nix;

  # `extend` applies to `rust` only.
  base = {
    "unused_features" = "allow";
  };

  # Top-level keys are tool names, placed under either [lints] or [workspace.lints].
  tools = {
    rust = core.mergeConfig base extend;
    cargo = {
      "non_kebab_case_bins" = "allow";
    };
  };
in
(pkgs.formats.toml { }).generate "cargo-lints.toml" tools
