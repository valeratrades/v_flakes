# JavaScript/TypeScript project configuration module
{ pkgs ? null, nixpkgs ? null, node ? null, corepack_home ? ".direnv/corepack" }:
if pkgs == null then {
  description = ''
JavaScript/TypeScript project configuration module.

Provides nodejs and pnpm. pnpm is provisioned through corepack so the exact
version pinned by each project's `packageManager` field is honored (nixpkgs'
`pnpm` tracks a single version and would drift from the pin). The corepack
shims live under a writable, gitignored directory since the nodejs install
in the read-only nix store cannot be written to.
'';
} else
let
  utils = import ../utils;
  nodejs = if node != null then node else pkgs.nodejs;
in
{
  enabledPackages = [ nodejs pkgs.corepack ];

  shellHook = utils.mkShellHook ''
    # Provision the pnpm version pinned by each subproject's `packageManager`
    # field via corepack. Shims live under ${corepack_home} (gitignored,
    # writable) so the read-only /nix/store node install is never touched.
    export COREPACK_HOME="$PWD/${corepack_home}"
    mkdir -p "$COREPACK_HOME/bin"
    corepack enable --install-directory "$COREPACK_HOME/bin" pnpm
    export PATH="$COREPACK_HOME/bin:$PATH"
  '';
}
