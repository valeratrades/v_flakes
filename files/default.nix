# Things are generated at lower level, as this can have unbounded number of members, and each can have its own args, - if I were to gen tomls at this level, we'd start taking a bunch of random args
{
  description = "Project conf files";
  licenses = {
    blue_oak = { name = "Blue Oak 1.0.0"; path = ./licenses/blue_oak.md; };
    agpl = { name = "AGPL-3.0"; path = ./licenses/agpl.txt; };
    gl = { name = "GLWTS"; path = ./licenses/glwts.txt; };
  };
  preCommit = import ../git/hooks.nix;
  treefmt = import ./treefmt.nix;
  rust = {
    rustfmt = import ../langs/rs/files/rustfmt.nix;
    deny = import ../langs/rs/files/deny.nix;
    toolchain = import ../langs/rs/files/toolchain.nix;
    config = import ../langs/rs/files/config.nix;
    clippy = import ../langs/rs/files/clippy.nix;
    sort_derives = import ../langs/rs/files/sort_derives.nix;
    lints = import ../langs/rs/files/lints.nix;
    build = import ../langs/rs/files/build.nix;
  };
  python = {
    ruff = import ../langs/py/files/ruff.nix;
  };
  golang = {
    gofumpt = import ../langs/go/files/gofumpt.nix;
  };
  gitignore = import ./gitignore.nix;
  gitattributes = import ./gitattributes.nix;
  envrc = import ./envrc.nix;
}
