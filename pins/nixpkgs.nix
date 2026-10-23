# ╔════════════════════════════════════════════════════════════════════════════╗
# ║ CANONICAL NIXPKGS — pinned here, shared by every consumer repo.             ║
# ║                                                                             ║
# ║ Consumers `import v_flakes.default_nixpkgs { inherit system; ... }` instead ║
# ║ of carrying their own nixpkgs input, so all repos on the same v_flakes rev  ║
# ║ resolve to identical store paths (nix store dedup, shared caches).          ║
# ║ Also the base of langs/rs/default_nightly.nix — moving this pin forks the   ║
# ║ toolchain drv for everyone.                                                 ║
# ║                                                                             ║
# ║ >>> BUMP POLICY: same as langs/rs/default_nightly.nix — avoid moving        ║
# ║ >>> without a minor v_flakes bump.                                          ║
# ╚════════════════════════════════════════════════════════════════════════════╝
builtins.fetchTree {
  type = "github";
  owner = "NixOS";
  repo = "nixpkgs";
  rev = "7a6522c868711d06e3a520bbcdfafe9806f4337f";
  narHash = "sha256-mN15cwddbOOIzzXSSwYUeRfOYeizz47Vy6y3Hzq6DuY=";
}
