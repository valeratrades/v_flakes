# The canonical nightly (./nightly_version.nix, same targets as ./default_nightly.nix) in the
# `minimal` profile: rustc, cargo, std. What a package build links against; the dev extras
# (rust-src, rust-analyzer, rust-docs, cranelift) are ~0.9 GiB every builder would fetch for
# nothing. Same bump policy as default_nightly.nix.
system:
let
  nixpkgs = import ../default_nixpkgs.nix;
  rust-overlay = import ../default_rust_overlay.nix;
  pkgs = import nixpkgs { inherit system; overlays = [ (import rust-overlay) ]; };
in
pkgs.rust-bin.nightly.${import ./nightly_version.nix}.minimal.override {
  targets = [ "wasm32-unknown-unknown" "x86_64-unknown-linux-musl" ];
}
