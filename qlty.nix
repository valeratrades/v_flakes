# qlty — `qlty smells`, `qlty check`, `qlty fmt`. Not in nixpkgs, so this is the upstream
# release tarball. The musl builds are static and the darwin ones are self-contained, so the
# archive is the whole package; qlty fetches its own linter plugins at runtime.
#
# Self-pinned like rs/sort_derives: the hashes below belong to one release, not to whatever
# a consumer's nixpkgs happens to carry.
system:
let
  pkgs = import (import ./default_nixpkgs.nix) { inherit system; };
  version = "0.641.0";
  targets = {
    x86_64-linux = { target = "x86_64-unknown-linux-musl"; hash = "sha256-bXiAqdAdyi5uEAs1oju55y/ewpY542o+X3Cz9gcaAvc="; };
    aarch64-linux = { target = "aarch64-unknown-linux-musl"; hash = "sha256-3HP2Dqs2hVjzJCYO4sbo3bamkLHoWu03gr/eCgOfAuQ="; };
    x86_64-darwin = { target = "x86_64-apple-darwin"; hash = "sha256-i5pNBdsBUJqRFPvOAE90458C9ce0W5B+jN2vhR0XI8A="; };
    aarch64-darwin = { target = "aarch64-apple-darwin"; hash = "sha256-ok1NCkkHLpW0LFJ3qK9eeTLTXCyekeqz2/DkoHL3ZTY="; };
  };
  inherit (targets.${system} or (throw "v_flakes.qlty: no upstream release for ${system}")) target hash;
in
pkgs.runCommand "qlty-${version}"
{
  meta = {
    description = "Code quality CLI — smells, linters, formatters";
    homepage = "https://qlty.sh";
    mainProgram = "qlty";
  };
} ''
  mkdir -p $out/bin
  tar xJf ${pkgs.fetchurl {
    url = "https://github.com/qltysh/qlty/releases/download/v${version}/qlty-${target}.tar.xz";
    inherit hash;
  }} -C $out/bin --strip-components=1 qlty-${target}/qlty
''
