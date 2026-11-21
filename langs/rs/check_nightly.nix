# The canonical nightly (./nightly_version.nix, same targets as ./default_nightly.nix) that particles check the code with:
# clippy, rustfmt, cranelift (./cranelift-wrapper.sh's workspace members), without the dev extras (rust-src, rust-analyzer,
# rust-docs), ~1.2 GiB a CI job would fetch for nothing. Same bump policy as default_nightly.nix.
system:
let
  nixpkgs = import ../../pins/nixpkgs.nix;
  rust-overlay = import ../../pins/rust_overlay.nix;
  pkgs = import nixpkgs { inherit system; overlays = [ (import rust-overlay) ]; };
in
pkgs.rust-bin.nightly.${import ./nightly_version.nix}.minimal.override {
  extensions = [ "clippy" "rustfmt" ] ++ pkgs.lib.optional (!pkgs.stdenv.hostPlatform.isFreeBSD) "rustc-codegen-cranelift-preview"; # not shipped for FreeBSD
  targets = [ "wasm32-unknown-unknown" "x86_64-unknown-linux-musl" ];
}
