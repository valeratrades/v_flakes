{
  description = ''
# Nix parts collection

Collection of reusable Nix components.
See individual component descriptions in their respective directories.'';

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  inputs.rust-overlay.url = "github:oxalica/rust-overlay";
  inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-utils.url = "github:numtide/flake-utils";

  outputs = { self, nixpkgs, rust-overlay, flake-utils }:
    let
      pname = "v_flakes";

      # Version constants for bundled packages - update these when bumping
      # Use partial semver (major.minor) - patch versions auto-resolve via cargo-binstall
      traceyVersion = "1.3";
      codestyleVersion = "0.2";

      parts = {
        files = (import ./files).description;
        github = (import ./github { inherit nixpkgs; }).description;
        rs = (import ./rs { inherit nixpkgs; }).description;
        py = (import ./py { inherit nixpkgs; }).description;
        tex = (import ./tex { inherit nixpkgs; }).description;
        typ = (import ./typ { inherit nixpkgs; }).description;
        js = (import ./js { inherit nixpkgs; }).description;
      };
    in
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs {
          inherit system;
          overlays = [ (import rust-overlay) ];
          config.allowUnfreePredicate = pkg: builtins.elem (nixpkgs.lib.getName pkg) [ "drawio" ];
        };
        rust = (import ./rs).default_nightly system;
        stdenv = pkgs.stdenvAdapters.useMoldLinker pkgs.stdenv;
        utils = import ./utils;
        files = import ./files;

        rsModule = (import ./rs) { inherit pkgs rust; };
        github = (import ./github) {
          inherit pkgs pname;
          rs = rsModule;
          enable = true;
          lastSupportedVersion = "nightly-2025-10-10";
          jobs = {
            default = true;
            errors.hooks = { push.paths = [ "src/**" ]; };
            warnings.hooks = { push.paths = [ "src/**" ]; };
          };
          release = {
            hooks = { push.branches = [ "main" ]; };
            gate = "\"$(git show HEAD~1:Cargo.toml | grep '^version' | head -1)\" != \"$(grep '^version' Cargo.toml | head -1)\"";
          };
        };
        readme = (import ./readme_fw) {
          inherit pkgs pname;
          rootDir = ./.;
          lastSupportedVersion = null;
          defaults = true;
          badges = [ "ci" ];
        };
        combined = utils.combine {
          inherit rust;
          modules = [
            rsModule
            github
            readme
            { shellHook = utils.mkShellHook ''
                cp -f ${(files.gitignore { inherit pkgs; langs = [ "rs" ];})} ./.gitignore
              '';
            }
          ];
        };
      in
      {
        devShells.default = pkgs.mkShell {
          inherit stdenv;
          packages = with pkgs; [ curl mold rust ] ++ combined.enabledPackages;
          shellHook = ''
            # Guard first: combined.shellHook aborts (exit 1) the entire hook
            # unless we are anchored at the repo root, so nothing below runs
            # — and pollutes a subdirectory — when invoked from elsewhere.
            ${combined.shellHook}
            _bump_script="./__scripts/bump_crate.rs"
            ${utils.checkCrateVersion { name = "tracey"; currentVersion = traceyVersion; bumpScript = "$_bump_script"; }}
            ${utils.checkCrateVersion { name = "codestyle"; currentVersion = codestyleVersion; bumpScript = "$_bump_script"; }}
            # Bootstrap: build our own binaries and put them on PATH for local testing
            cargo b -q 2>/dev/null
            export PATH="$PWD/target/debug:$PATH"
          '';
          env.RUST_BACKTRACE = 1;
        };
      }
    ) // {
      description = ''
## Files
${parts.files}

## GitHub
${parts.github}

## Rust
${parts.rs}

## Python
${parts.py}

## LaTeX
${parts.tex}

## Typst
${parts.typ}

## JavaScript
${parts.js}

## Readme Framework
Generates README.md from docs/.readme_assets/ directory structure.
'';

      default_nixpkgs = import ./default_nixpkgs.nix;
      files = import ./files;
      github = import ./github;
      container = import ./github/container/lib.nix;
      rs = import ./rs;
      py = import ./py;
      tex = import ./tex;
      typ = import ./typ;
      js = import ./js;
      readme-fw = import ./readme_fw;
      utils = import ./utils;

      # Backward compatibility aliases
      hooks = {
        description = "DEPRECATED: Use github module instead";
        appendCustom = ./github/append_custom.rs;
        treefmt = import ./files/treefmt.nix;
        preCommit = import ./github/pre_commit.nix;
      };
      workflows = import ./github/workflows/nix-parts;
      ci = import ./github;
    };
}
