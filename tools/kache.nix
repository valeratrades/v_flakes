# Self-pinned for the same reason as diet.nix: one store path for the whole fleet. Upstream's release
# binaries (what `cargo binstall kache` fetches): the source build runs kache's ~2000-test suite on every
# cache miss, ~40 min on a CI runner. The `shims/` farm and its `.kache-shims` marker are laid out as
# upstream's packaging/nix/package.nix does.
system:
let
  pkgs = import (import ../pins/nixpkgs.nix) { inherit system; };
  version = "2.1.1";
  release = {
    x86_64-linux = { triple = "x86_64-unknown-linux-musl"; hash = "sha256-dgMCLueLSKmv3pBVsN8n5cLO8TUaVPot5rT94PN64iw="; };
    aarch64-linux = { triple = "aarch64-unknown-linux-musl"; hash = "sha256-Rm8K70iF9SkTWbPBvAyZdoJGNBlMW2fhzuKk/jA1FVo="; };
    x86_64-darwin = { triple = "x86_64-apple-darwin"; hash = "sha256-aWJ8/sMBeqUh0GqEr8bF50c0RoZ4vWZZ2Sr9V9mk9Fc="; };
    aarch64-darwin = { triple = "aarch64-apple-darwin"; hash = "sha256-1FM7qjxXvlHV8jkLcFUcqdbCqDoZMyZvoKVwU3dOCPY="; };
  }.${system} or (throw "kache: no upstream release binary for ${system}");
in
pkgs.stdenvNoCC.mkDerivation {
  pname = "kache";
  inherit version;
  src = pkgs.fetchurl {
    url = "https://github.com/kunobi-ninja/kache/releases/download/v${version}/kache-${release.triple}.tar.gz";
    inherit (release) hash;
  };
  sourceRoot = ".";
  installPhase = ''
    install -Dm755 -t $out/bin kache kache-engine
    mkdir -p $out/lib/kache
    for name in cc c++ gcc g++ clang clang++ cargo rustdoc; do
      ln -s $out/bin/kache $out/lib/kache/$name
    done
    touch $out/lib/kache/.kache-shims
    ln -s lib/kache $out/shims
  '';
  meta.mainProgram = "kache";
}
