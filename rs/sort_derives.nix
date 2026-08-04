# cargo-sort-derives keys on the last `::` segment, so `derive_more::Deref` lands between
# `Debug` and `Eq`. The patch adds an opt-in `qualified_last` (`.sort-derives.toml` key or
# --qualified-last); without it the binary matches upstream byte for byte, so an unpatched
# CI still agrees on repos that don't set it.
# Drop once https://github.com/lusingander/cargo-sort-derives/issues/25 lands.
#
# Self-pinned (not taking the consumer's pkgs) because the patch is cut against a specific
# upstream tree — a consumer whose nixpkgs predates it fails at build time with a hunk
# reject. The assert turns that into an eval-time error when this pin moves instead.
system:
let
  pkgs = import (import ../default_nixpkgs.nix) { inherit system; };
in
assert pkgs.cargo-sort-derives.version == "0.13.0";
pkgs.cargo-sort-derives.overrideAttrs (o: {
  patches = (o.patches or [ ]) ++ [ ./sort_derives_qualified_last.patch ];
})
