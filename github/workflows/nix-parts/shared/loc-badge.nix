{ gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb" }:
{
  name = "Update LOC Badge";
  runs-on = "ubuntu-latest";
  steps = [
    {
      name = "Checkout repository";
      uses = "actions/checkout@v5";
    }
    {
      name = "Install tokei";
      run = "cargo install tokei";
    }
  ] ++ import ./gist-badges.nix {
    inherit gistId;
    badges.loc = { label = "LoC"; message = "$(tokei --output json | jq .Total.code)"; };
  };
}
