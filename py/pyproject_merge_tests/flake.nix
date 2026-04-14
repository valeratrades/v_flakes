{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    rust-overlay.url = "github:oxalica/rust-overlay";
    flake-utils.url = "github:numtide/flake-utils";
  };
  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; overlays = [ (import rust-overlay) ]; };
        rust = pkgs.rust-bin.selectLatestNightlyWith (t: t.default.override {
          extensions = [ "rust-src" ];
        });
      in {
        devShells.default = pkgs.mkShell {
          packages = [ rust pkgs.mold ];
          shellHook = ''
            export PATH="${rust}/bin:$PATH"
          '';
        };
      });
}
