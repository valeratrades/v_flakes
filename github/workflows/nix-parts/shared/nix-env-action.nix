# `.github/actions/nix-env/action.yml`: cache.nix's setup for hand-written workflows, as one step.
#
#   - uses: actions/checkout@v5
#   - uses: ./.github/actions/nix-env
#     with: { rust-cache: <shared-key> }  # optional
#     with: { cachix-auth-token: ${{ secrets.CACHIX_AUTH_TOKEN }} }  # optional, `cache.cachix` only: push to the cache
{ cache ? { } }:
let
  nixCi = import ../../../cache.nix { inherit cache; };
  lean = import ../../../cache.nix { };
  bash = step: if step ? run then { shell = "bash"; } // step else step; # composite `run` steps require it
  onlyIf = cond: step: step // { "if" = if step ? "if" then "${cond} && (${step."if"})" else cond; };
  onRustCache = onlyIf "inputs.rust-cache != ''";

  # A composite action has no `secrets` context, so pushing takes the token as an input. Without it, cachix
  # only substitutes, and what the job builds goes to the lean cache: two post-build-hooks can't coexist.
  pushing = "inputs.cachix-auth-token != ''";
  pulling = "inputs.cachix-auth-token == ''";
  cacheSteps =
    if cache ? cachix then
      map (onlyIf pulling) (lean.setupSteps ++ [ lean.installStep ])
      ++ [ (onlyIf pushing nixCi.installStep) ]
      ++ map (step: step // { "with" = step."with" // { authToken = "\${{ inputs.cachix-auth-token }}"; }; }) nixCi.cacheSteps
      ++ map (onlyIf pulling) lean.cacheSteps
    else nixCi.setupSteps ++ [ nixCi.installStep ] ++ nixCi.cacheSteps;
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
      description = "Cachix auth token: the job pushes what it builds to the cache. Empty pulls only";
      required = false;
      default = "";
    };
  } else { });
  runs = {
    using = "composite";
    steps = map bash (cacheSteps ++ map onRustCache [
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
