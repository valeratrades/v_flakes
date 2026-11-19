# The canonical nightly (./nightly_version.nix) for a CI job that builds and runs the code, never develops it: `minimal`, with
# cranelift (./cranelift-wrapper.sh's workspace members) and wasm32. Same bump policy as default_nightly.nix.
system:
let
  nixpkgs = import ../../pins/nixpkgs.nix;
  rust-overlay = import ../../pins/rust_overlay.nix;
  pkgs = import nixpkgs { inherit system; overlays = [ (import rust-overlay) ]; };
in
pkgs.rust-bin.nightly.${import ./nightly_version.nix}.minimal.override {
  extensions = pkgs.lib.optional (!pkgs.stdenv.hostPlatform.isFreeBSD) "rustc-codegen-cranelift-preview"; # not shipped for FreeBSD
  targets = [ "wasm32-unknown-unknown" ];
}
