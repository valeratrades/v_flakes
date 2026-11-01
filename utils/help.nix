# `nix run .#help`, listed off one system's flake outputs so it can't drift from them. Every app owes a `meta.description`.
{ pkgs, apps, packages, devShells, about ? "" }:
let
  lib = pkgs.lib;
  row = cmd: desc: "  ${cmd}" + lib.optionalString (desc != "") "${lib.strings.replicate (lib.max 1 (32 - builtins.stringLength cmd)) " "}${desc}";
  appRows = lib.mapAttrsToList
    (name: app: row "nix run .#${name}" (app.meta.description or (throw "v_flakes help: apps.${name} has no meta.description")))
    (removeAttrs apps [ "help" ]);
  packageRows = lib.concatLists (lib.mapAttrsToList
    (name: p:
      let desc = builtins.tryEval (p.meta.description or ""); in
      lib.optional desc.success (row "nix build .#${name}" desc.value)) # devenv's `container-*` throw until nix2container is an input; unbuildable, so unlisted
    packages);
  shellRows = map (name: row "nix develop${lib.optionalString (name != "default") " .#${name}"}" "") (builtins.attrNames devShells);
  text = lib.concatStringsSep "\n" (lib.filter (s: s != "") [ about (lib.concatStringsSep "\n" (appRows ++ packageRows ++ shellRows)) ]);
in
{
  type = "app";
  meta.description = "this listing";
  program = "${pkgs.writeShellScriptBin "help" "cat <<'EOF'\n${text}\nEOF\n"}/bin/help";
}
