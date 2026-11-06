# Self-pinned for the same reason as diet.nix: one store path for the whole fleet. Upstream's own
# recipe, so the `shims/` farm and its `.kache-shims` marker come as upstream lays them out.
system:
let
  pkgs = import (import ../pins/nixpkgs.nix) { inherit system; };
  src = builtins.fetchTarball {
    url = "https://github.com/kunobi-ninja/kache/archive/e465eff90d87669d7b0a9ee1010f1ee1e44090ed.tar.gz"; # v2.0.0
    sha256 = "sha256-1O4JrN2zzKS7QgBT2fnih2W+zvEqBT5dvEuxCuyU3Kg=";
  };
in
(pkgs.callPackage "${src}/packaging/nix/package.nix" { }).overrideAttrs (o: {
  # Cache-miss memo assertions the Linux sandbox trips, not correctness.
  checkFlags = (o.checkFlags or [ ]) ++ [
    "--skip=compiler::cc::tests::the_direct_capture_probe_rejects_a_driver_that_writes_no_object_and_remembers"
    "--skip=compiler::rustdoc::tests::a_second_invocation_does_not_run_rustdoc_again"
  ];
})
