# Fails CI when a flake app that gates something exits non-zero.
#
#   jobs.errors.augment = [ { name = "flake-app"; args.app = "visual"; } ];
#
# The app is the whole contract: it decides what "current" means and exits 1 when it
# is not. `asset-gate` does the comparison itself and so is bound to a single file;
# this one compares nothing, which is what a gate over a directory of outputs needs.
{ app, cache ? { } }:
let
  nixCi = import ../../../cache.nix { inherit cache; };
in
{
  name = "nix run .#${app}";
  runs-on = "ubuntu-latest";
  steps =
    [{
      name = "Checkout repository";
      uses = "actions/checkout@v4";
    }]
    ++ nixCi.setupSteps
    ++ [
      nixCi.installStep
      nixCi.cacheStep
      {
        name = "Run ${app}";
        run = "nix run .#${app}";
      }
    ];
}
