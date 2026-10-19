{ pkgs, extra ? "" }:
pkgs.writeText "envrc" (builtins.readFile ./envrc/envrc + (if extra != "" then "\n${extra}" else ""))
