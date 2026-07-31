{
  description = "Example usage";

  inputs = {
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs =
    {
      self,
      flake-utils,
    }:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import (import ../default_nixpkgs.nix) { inherit system; };
        utils = import ../utils;
        readme-fw = import ./.;

        pname = "readme-fw";
        readme = readme-fw {
          inherit pkgs pname;
          defaults = true;
          lastSupportedVersion = "nightly-1.86";
          rootDir = ./.;
          badges = [
            "msrv"
            "crates_io"
            "docs_rs"
            "loc"
            "ci"
          ];
        };

        # Generate GitHub Actions workflows
        workflows = import ../github/workflows/nix-parts {
          inherit pkgs;
          lastSupportedVersion = "nightly-1.86";
          jobsErrors = [ ];  # Add your error jobs here
          jobsWarnings = [ ];  # Add your warning jobs here
          jobsOther = [ "loc-badge" ];  # LOC badge updater
        };

        combined = utils.combine {
          # combine requires a rust toolchain (cargo on PATH) — this example
          # has no rust modules, but the contract is unconditional, so hand it
          # nixpkgs' cargo to satisfy it.
          rust = pkgs.cargo;
          modules = [
            readme
            { shellHook = utils.mkShellHook ''
                # Generate workflows
                mkdir -p .github/workflows
                cp -f ${workflows.other} .github/workflows/other.yml
              '';
            }
          ];
        };
      in
      {
        packages = {
          inherit workflows;
        };

        devShells.default = pkgs.mkShell {
          buildInputs = [ pkgs.typst pkgs.pandoc ];
          shellHook = combined.shellHook;
        };
      }
    );
}
