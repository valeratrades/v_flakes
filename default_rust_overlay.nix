# ╔════════════════════════════════════════════════════════════════════════════╗
# ║ CANONICAL RUST-OVERLAY — see default_nixpkgs.nix; same bump policy.         ║
# ╚════════════════════════════════════════════════════════════════════════════╝
builtins.fetchTree {
  type = "github";
  owner = "oxalica";
  repo = "rust-overlay";
  rev = "5106a604b3d67cffe8eb51a8bd9f04e607f0d31d";
  narHash = "sha256-WJPfr9EAWVIuTMyb/ilHKUYlg/RNa0xrNiWR+p1iHUg=";
}
