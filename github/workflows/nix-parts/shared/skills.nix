# A repo shipping agent skills (https://github.com/EV-Main/skills): `skargo check` on PRs, `skargo publish` on main.
{ skargo, cache ? { } }:
let
  nixCi = import ../../../cache.nix { inherit cache; };
in
{
  standalone = true;

  name = "Skills";
  on = {
    pull_request = { };
    push.branches = [ "main" ];
    workflow_dispatch = { };
  };
  concurrency = {
    group = "skills-\${{ github.ref }}";
    cancel-in-progress = false;
  };
  permissions.contents = "write";
  jobs.skills = {
    runs-on = "ubuntu-latest";
    steps =
      [{
        uses = "actions/checkout@v5";
        "with".fetch-depth = 0; # `check` diffs against released tags
      }]
      ++ nixCi.setupSteps
      ++ [
        nixCi.installStep
        nixCi.cacheStep
        {
          name = "Build skargo";
          # not `nix run`: inside skargo's own checkout, its apps.default is `cargo run` on the runner's toolchain
          run = ''
            out=$(nix build --no-link --print-out-paths ${skargo})
            echo "skargo=$out/bin/skargo" >> "$GITHUB_ENV"
          '';
        }
        {
          name = "Check";
          "if" = "github.event_name != 'push'";
          run = "$skargo check";
        }
        {
          name = "Validate Claude marketplace";
          "if" = "hashFiles('.claude-plugin/marketplace.json') != ''";
          run = "npx -y @anthropic-ai/claude-code plugin validate --strict .";
        }
        {
          name = "Publish";
          "if" = "github.event_name == 'push'";
          run = "$skargo publish";
        }
      ];
  };
}
