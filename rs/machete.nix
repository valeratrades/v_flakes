# Upstream's unit of analysis is a package: it greps that package's sources for each of its
# dependencies. An entry in `[workspace.dependencies]` belongs to no package and has no sources
# to grep — its readers are other manifests — so an orphan there is reported by nothing, not by
# machete and not by cargo, which never puts an uninherited entry in the graph.
#
# This build is our fork, which adds that cross-manifest join.
#DEPRECATE: switch `owner`/`rev` back to bnjbvr once https://github.com/bnjbvr/cargo-machete/pull/274 merges
#
# Self-pinned (not taking the consumer's pkgs) for the same reason as rs/sort_derives: one store
# path for the whole fleet, so nix dedups it across repos.
system:
let
  pkgs = import (import ../default_nixpkgs.nix) { inherit system; };
in
pkgs.rustPlatform.buildRustPackage (finalAttrs: {
  pname = "cargo-machete";
  version = "0.9.2-workspace-deps";

  src = pkgs.fetchFromGitHub {
    owner = "valeratrades";
    repo = "cargo-machete";
    rev = "046fa76b15154726013f0c7c564fdb898eb2a852";
    hash = "sha256-B9aOIJXZfzwsM10Om5XIghRnu0H9mJAyEVKvltlcl48=";
  };

  cargoHash = "sha256-qXPZhsDrt+jjOpTZScJhaOCYzX58zjjkM80MkOFLzb4=";

  # tests require internet access
  doCheck = false;

  meta = {
    description = "Cargo tool that detects unused dependencies in Rust projects";
    mainProgram = "cargo-machete";
    homepage = "https://github.com/valeratrades/cargo-machete";
    license = pkgs.lib.licenses.mit;
  };
})
