{
  __functor = _: import ./module.nix;
  default_nightly = import ./default_nightly.nix;
  nightly_version = import ./nightly_version.nix;
  sort_derives = import ./sort_derives.nix;
}
