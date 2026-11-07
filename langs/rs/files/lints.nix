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
    # opt-in clippy lints the org style wants; seeded, a key the consumer already sets wins
    clippy = {
      "integer_division" = "warn"; # show intent: `div_floor` / `div_ceil` / `checked_div`, or allow at the site
      "if_not_else" = "warn"; # state conditions positively
    };
  };
in
(pkgs.formats.toml { }).generate "cargo-lints.toml" tools
