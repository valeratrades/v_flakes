{ pkgs, extend ? {}, ... }:
let
  core = import ../utils/core.nix;

  base = {
    global = {
      excludes = ["examples/config.*"];
    };
    formatter = {
      nix = {
        command = "nixpkgs-fmt"; # deprecated, but I still __by far__ prefer it over all the newer alternatives
        includes = ["*.nix"];
        #command = "nixfmt"; # formats with vertical bloat
        #options = ["-w" "200"];
      };
      rust = {
        command = "rustfmt";
        includes = ["*.rs"];
        options = ["--edition" "2024"]; # code duplication with formatter in dev-shell, but rust ecosystem is not smart enough yet to avoid it
      };
      # Does not seem to work (treefmt feels VERY raw)
      rust-leptos = {
        command = "leptosfmt";
        options = ["--tab-spaces" "2" "--max-width" "100"];
        includes = ["*.rs"];
      };
      # typstyle is CLI-flag configured (no repo config file). Keep these flags
      # in sync with the `typ` module's lineWidth/indentWidth — override here via
      # `extend` if a project passes non-default widths to `typ`.
      typst = {
        command = "typstyle";
        options = ["-i" "--line-width" "190" "--indent-width" "2"];
        includes = ["*.typ"];
      };
    };
  };

  merged = core.mergeConfig base extend;
in
(pkgs.formats.toml { }).generate "" merged
