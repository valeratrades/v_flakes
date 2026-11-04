{ pkgs, extend ? { } }:
let
  core = import ../../../utils/core.nix;

  # `extend` applies to `rust` only.
  base = {
    "unused_features" = "allow";
    "stable_features" = "allow"; # a newer toolchain stabilizes what the pinned one still gates; code quality over feature-gate churn
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
