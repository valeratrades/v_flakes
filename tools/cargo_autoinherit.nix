# cargo-autoinherit merges a member's `default-features = false` into a workspace entry that
# keeps the defaults, then rewrites the member to `workspace = true`, which cannot turn them
# off: the member silently gains them. The patch never merges specs that differ in
# `default-features`, so such a dep stays as the member wrote it.
# Upstream: https://github.com/mainmatter/cargo-autoinherit/issues/40 (unmaintained since 0.1.6).
#
# Self-pinned for the same reason as sort_derives.nix: the patch is cut against v0.1.6.
system:
let
  pkgs = import (import ../pins/nixpkgs.nix) { inherit system; };
in
assert pkgs.cargo-autoinherit.version == "0.1.6";
pkgs.cargo-autoinherit.overrideAttrs (o: {
  patches = (o.patches or [ ]) ++ [ ./cargo_autoinherit_default_features.patch ];
})
