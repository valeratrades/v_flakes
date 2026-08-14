# nixpkgs is on 1.3.0, which sees exactly one manifest — the nearest one. 1.4.0 is what learned to
# walk a workspace, and it selects the same default members `cargo release` publishes.
#DEPRECATE: drop once nixpkgs carries >=1.4.0
#
# Self-pinned (not taking the consumer's pkgs) for the same reason as rs/machete: one store path
# for the whole fleet, so nix dedups it across repos.
system:
let
  pkgs = import (import ../default_nixpkgs.nix) { inherit system; };
in
pkgs.cargo-diet.overrideAttrs (o: rec {
  version = "1.4.0";
  src = pkgs.fetchFromGitHub {
    owner = "the-lean-crate";
    repo = "cargo-diet";
    rev = "v${version}";
    hash = "sha256-3fH4x83uSRuLwjTatBNicUODCb37HGuLBdTR34yXV8k=";
  };
  cargoDeps = pkgs.rustPlatform.fetchCargoVendor {
    inherit src;
    hash = "sha256-3oz+q8Hxa/ZzmvlJzt/8xGlFWgWArbHAEVr7chNgl5M=";
  };
})
