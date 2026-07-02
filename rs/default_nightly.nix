# ╔════════════════════════════════════════════════════════════════════════════╗
# ║ CANONICAL RUST NIGHTLY — pinned here, shared by every consumer repo.        ║
# ║                                                                             ║
# ║ All repos on `v_flakes.rs.default_nightly` resolve to byte-identical        ║
# ║ toolchain store paths, which is what makes nix store dedup and cross-repo   ║
# ║ sccache hits possible. Any change below forks that path for everyone.       ║
# ║                                                                             ║
# ║ >>> BUMP POLICY: touching ANYTHING in this file requires AT LEAST a MINOR   ║
# ║ >>> v_flakes bump (new vX.Y branch). Never move these pins in a patch —     ║
# ║ >>> repos tracking the same minor must keep resolving to the same build.    ║
# ╚════════════════════════════════════════════════════════════════════════════╝
# Deliberately self-pinned (not taking the consumer's pkgs): the aggregate
# toolchain copies + patchelfs rustc with its own $out in the rpath, so ANY input
# difference — even a nixpkgs rev — changes rustc bytes and kills cache sharing.
system:
let
  nixpkgs = builtins.fetchTree {
    type = "github";
    owner = "NixOS";
    repo = "nixpkgs";
    rev = "e73de5be04e0eff4190a1432b946d469c794e7b4";
    narHash = "sha256-pGvFkM8N0xEkIIXDe5YYfbEAvHrk4IxBrjB/x8OomhE=";
  };
  rust-overlay = builtins.fetchTree {
    type = "github";
    owner = "oxalica";
    repo = "rust-overlay";
    rev = "5106a604b3d67cffe8eb51a8bd9f04e607f0d31d";
    narHash = "sha256-WJPfr9EAWVIuTMyb/ilHKUYlg/RNa0xrNiWR+p1iHUg=";
  };
  pkgs = import nixpkgs { inherit system; overlays = [ (import rust-overlay) ]; };
in
# wasm32 included unconditionally: an extra rust-std component is ~free, while
# omitting it in some repos would fork the toolchain drv (see rpath note above).
pkgs.rust-bin.nightly."2026-06-29".default.override {
  extensions = [ "rust-src" "rust-analyzer" "rust-docs" "rustc-codegen-cranelift-preview" ];
  targets = [ "wasm32-unknown-unknown" ];
}
