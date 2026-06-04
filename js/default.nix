# JavaScript/TypeScript project configuration module
{ pkgs ? null, nixpkgs ? null, node ? null, corepack_home ? ".direnv/corepack",
  # Pre-commit configuration. No default: once `js` is declared for a build, its
  # fields are mandatory and must be set explicitly (true/false), so a project
  # never silently inherits a hook policy it didn't opt into.
  #   visual : run `pnpm test:visual` (playwright) in the pre-commit hook.
  preCommit ? null,
}:
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
  preCommit' =
    assert pkgs.lib.assertMsg (preCommit != null)
      "v_flakes.js: `preCommit` is required when the module is built. Pass e.g. `preCommit = { visual = true; };` (no default — opt in explicitly).";
    assert pkgs.lib.assertMsg (preCommit ? visual)
      "v_flakes.js: `preCommit.visual` is required (true/false) — whether to run `pnpm test:visual` in the pre-commit hook.";
    preCommit;
in
{
  # Validated pre-commit policy. Reading this forces the requiredness asserts,
  # so `github` (which reads `js.preCommit.visual`) gets a clear error rather
  # than a silent `null` when a field was omitted.
  preCommit = preCommit';
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
