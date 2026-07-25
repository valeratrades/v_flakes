# Publishes `packages.<system>.default` to a cachix cache on every push to main, so
# downstream flakes that take this repo as an input substitute the binary instead of
# rebuilding it (the point of the whole exercise: weak machines — rpi, old laptops).
#
# Distinct from `cache` (github/cache.nix), which only speeds up THIS repo's CI.
# Requires the CACHIX_AUTH_TOKEN secret. Public cache ⇒ public repos only.
{ name }:
{
  standalone = true;

  name = "cachix";
  on = {
    push.branches = [ "main" ];
    workflow_dispatch = { };
  };
  jobs.build = {
    name = "build \${{ matrix.system }}";
    strategy = {
      fail-fast = false;
      matrix.include = [
        { runner = "ubuntu-latest"; system = "x86_64-linux"; }
        { runner = "ubuntu-24.04-arm"; system = "aarch64-linux"; }
      ];
    };
    runs-on = "\${{ matrix.runner }}";
    steps = [
      { uses = "actions/checkout@v4"; }
      { uses = "cachix/install-nix-action@v31"; }
      {
        uses = "cachix/cachix-action@v17";
        "with" = {
          inherit name;
          authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
        };
      }
      { run = "nix build -L '.#packages.\${{ matrix.system }}.default'"; }
    ];
  };
}
