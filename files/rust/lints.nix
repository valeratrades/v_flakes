{ pkgs, extend ? {} }:
let
  core = import ../../utils/core.nix;

  # Keys here become entries under [lints.rust] (or [workspace.lints.rust]) in Cargo.toml.
  base = {
    "unused_features" = "allow";
  };

  merged = core.mergeConfig base extend;

  # Wrapped under `rust` so the consumer can place it under either [lints] or [workspace.lints].
  wrapped = { rust = merged; };
in
(pkgs.formats.toml { }).generate "cargo-lints.toml" wrapped
