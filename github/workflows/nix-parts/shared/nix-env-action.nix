# `.github/actions/nix-env/action.yml`: cache.nix's setup for hand-written workflows, as one step.
#
#   - uses: actions/checkout@v5
#   - uses: ./.github/actions/nix-env
#     with: { rust-cache: <shared-key> }  # optional
#     with: { cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }} }  # required with `cache.cachix`
{ cache ? { } }:
let
  nixCi = import ../../../cache.nix { inherit cache; };
  bash = step: if step ? run then { shell = "bash"; } // step else step; # composite `run` steps require it
  onRustCache = step: step // { "if" = "inputs.rust-cache != ''"; };
  # a composite action has no `secrets` context, so the caller hands the token in
  tokenFromInput = step:
    if step ? uses && builtins.match "cachix/cachix-action@.*" step.uses != null
    then step // { "with" = step."with" // { authToken = "\${{ inputs.cachix-auth-token }}"; }; }
    else step;
in
{
  name = "nix-env";
  description = "Install Nix with the repo's v_flakes binary cache; optionally Swatinem/rust-cache keyed on the dev shell's toolchain";
  inputs = {
    rust-cache = {
      description = "rust-cache shared-key; empty leaves rust-cache off";
      required = false;
      default = "";
    };
  } // (if cache ? cachix then {
    cachix-auth-token = {
      description = "Cachix auth token, for pushing to the cache";
      required = true;
    };
  } else { });
  runs = {
    using = "composite";
    steps = map bash (nixCi.setupSteps ++ [ nixCi.installStep ] ++ map tokenFromInput nixCi.cacheSteps ++ map onRustCache [
      {
        name = "Toolchain on PATH"; # rust-cache keys on the rustc it finds, else the runner's rustup one
        run = "nix develop --command bash -c 'dirname \"$(command -v rustc)\" >> \"$GITHUB_PATH\"'"; # inside: the shellHook may print to stdout
      }
      {
        name = "No rustc wrapper"; # the kache store isn't kept on runners
        run = ''echo RUSTC_WRAPPER= >> "$GITHUB_ENV"'';
      }
      {
        uses = "Swatinem/rust-cache@v2";
        "with" = {
          shared-key = "\${{ inputs.rust-cache }}";
          save-if = "\${{ github.ref_name == github.event.repository.default_branch }}";
        };
      }
    ]);
  };
}
