# ╔════════════════════════════════════════════════════════════════════════════╗
# ║ CANONICAL NIXPKGS — pinned here, shared by every consumer repo.             ║
# ║                                                                             ║
# ║ Consumers `import v_flakes.default_nixpkgs { inherit system; ... }` instead ║
# ║ of carrying their own nixpkgs input, so all repos on the same v_flakes rev  ║
# ║ resolve to identical store paths (nix store dedup, shared caches).          ║
# ║ Also the base of rs/default_nightly.nix — moving this pin forks the         ║
# ║ toolchain drv for everyone.                                                 ║
# ║                                                                             ║
# ║ >>> BUMP POLICY: same as rs/default_nightly.nix — moving this pin requires  ║
# ║ >>> AT LEAST a MINOR v_flakes bump (new vX.Y branch).                       ║
# ╚════════════════════════════════════════════════════════════════════════════╝
builtins.fetchTree {
  type = "github";
  owner = "NixOS";
  repo = "nixpkgs";
  rev = "e73de5be04e0eff4190a1432b946d469c794e7b4";
  narHash = "sha256-pGvFkM8N0xEkIIXDe5YYfbEAvHrk4IxBrjB/x8OomhE=";
}
