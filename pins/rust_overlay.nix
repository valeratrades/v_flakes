# ╔════════════════════════════════════════════════════════════════════════════╗
# ║ CANONICAL RUST-OVERLAY — see pins/nixpkgs.nix; same bump policy.            ║
# ╚════════════════════════════════════════════════════════════════════════════╝
builtins.fetchTree {
  type = "github";
  owner = "oxalica";
  repo = "rust-overlay";
  rev = "892c035d7c2ff75acd5da10424a47ab454e1f3dc";
  narHash = "sha256-KJhq0HYg2gIZjpsj47z1kWrjoUUAqSqdD2mMWAsOg4k=";
}
