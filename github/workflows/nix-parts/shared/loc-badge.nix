{ gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb", tokei }:
{
  name = "Update LOC Badge";
  runs-on = "ubuntu-latest";
  steps = [
    {
      name = "Checkout repository";
      uses = "actions/checkout@v5";
    }
    { name = "Install Nix"; uses = "DeterminateSystems/nix-installer-action@main"; }
    {
      name = "Install tokei";
      # by store path, from cache.nixos.org: no flake to evaluate, nothing to build
      run = "nix-store --realise ${tokei} > /dev/null && echo ${tokei}/bin >> \"$GITHUB_PATH\"";
    }
  ] ++ import ./gist-badges.nix {
    inherit gistId;
    badges.loc = { label = "LoC"; message = "$(tokei --output json | jq .Total.code)"; };
  };
}
