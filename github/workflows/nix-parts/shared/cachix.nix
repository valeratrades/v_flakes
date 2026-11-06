# Publishes `packages.<system>.default` to a cachix cache on every push to main, so
# downstream flakes that take this repo as an input substitute the binary instead of
# rebuilding it (the point of the whole exercise: weak machines — rpi, old laptops).
#
# Once every system built, `cached` is moved to the rev, so consumers on `?ref=cached` only
# ever lock revs that substitute. Runs are serialized, so it never moves backwards.
#
# Distinct from `cache` (github/cache.nix), which only speeds up THIS repo's CI.
# Requires the CACHIX_AUTH_TOKEN secret. Public cache ⇒ public repos only.
{ name, systems ? [ "x86_64-linux" "aarch64-linux" ], gistId }:
let
  runners = {
    x86_64-linux = "ubuntu-latest";
    aarch64-linux = "ubuntu-24.04-arm";
    aarch64-darwin = "macos-latest";
  };
in
{
  standalone = true;

  name = "cachix";
  on = {
    push.branches = [ "main" ];
    workflow_dispatch = { };
  };
  concurrency = {
    group = "cachix";
    cancel-in-progress = false;
  };
  jobs.build = {
    name = "build \${{ matrix.system }}";
    strategy = {
      fail-fast = false;
      matrix.include = map
        (system: {
          inherit system;
          runner = runners.${system} or (throw "v_flakes publishCachix: no runner for ${system}");
        })
        systems;
    };
    runs-on = "\${{ matrix.runner }}";
    steps = [
      { uses = "actions/checkout@v5"; }
      { uses = "cachix/install-nix-action@v31"; }
      {
        uses = "cachix/cachix-action@v17";
        "with" = {
          inherit name;
          authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
          skipPush = true;
        };
      }
      { run = "nix build -L '.#packages.\${{ matrix.system }}.default'"; }
      { run = "cachix push ${name} ./result"; } # the action's own push silently no-ops without a token, and `cached` must not move then
    ] ++ import ./gist-badges.nix {
      inherit gistId;
      condition = "matrix.system == 'x86_64-linux'";
      badges.size = { label = "size"; message = "$(LC_ALL=C numfmt --to=iec-i --suffix=B --format=%.1f $(cat result/bin/* | wc -c))"; };
    };
  };
  jobs.cached = {
    needs = "build";
    runs-on = "ubuntu-latest";
    permissions.contents = "write";
    steps = [
      { uses = "actions/checkout@v5"; }
      { run = "git push --force origin HEAD:refs/heads/cached"; }
    ];
  };
}
