{ pkgs, impure ? false, extra ? "" }:
pkgs.writeText "envrc" (builtins.readFile ./envrc/nix_config + (if impure then builtins.readFile ./envrc/impure else "") + "use flake\n" + (if extra != "" then "\n${extra}" else ""))
