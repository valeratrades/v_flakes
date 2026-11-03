# `apps.default` of a rust flake: inside a cargo workspace that has the package, `cargo run` on the working tree (shares its target/); anywhere else, the nix-built package.
{ pkgs, package }:
let
  bin = package.meta.mainProgram or package.pname;
  drv = builtins.unsafeDiscardStringContext package.drvPath; # so the nix build happens only on the branch that runs it
in
{
  type = "app";
  meta.description = "${bin}: `cargo run` from its own checkout, else the nix build";
  program = "${pkgs.writeShellScript "${bin}-run" ''
    set -e
    if meta=$(cargo metadata --no-deps --format-version 1 2>/dev/null) && ${pkgs.jq}/bin/jq -e --arg n ${package.pname} 'any(.packages[]; .name == $n)' <<<"$meta" >/dev/null; then
      exec cargo run -p ${package.pname} --bin ${bin} -- "$@"
    fi
    out=$(nix build --no-link --print-out-paths '${drv}^out')
    exec "$out/bin/${bin}" "$@"
  ''}";
}
