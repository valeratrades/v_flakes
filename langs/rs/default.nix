{
  __functor = _: import ./module.nix;
  default_nightly = import ./default_nightly.nix;
  build_nightly = import ./build_nightly.nix;
  nightly_version = import ./nightly_version.nix;
  sort_derives = import ../../tools/sort_derives.nix;
  machete = import ../../tools/machete.nix;
  cpublish = import ./cpublish.nix;
  diet = import ../../tools/diet.nix;
}
