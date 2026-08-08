{
  description = ''
    # Nix parts collection

    Collection of reusable Nix components.
    See individual component descriptions in their respective directories.'';

  # Revs must equal ./default_nixpkgs.nix and ./default_rust_overlay.nix (asserted
  # below). Flake inputs can't reference those files, so they are restated here —
  # otherwise this repo, and every consumer of the re-exported inputs, would drift
  # off the pins we hand out.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/e73de5be04e0eff4190a1432b946d469c794e7b4";
  inputs.rust-overlay.url = "github:oxalica/rust-overlay/5106a604b3d67cffe8eb51a8bd9f04e607f0d31d";
  inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.pre-commit-hooks.url = "github:cachix/git-hooks.nix";
  inputs.pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  inputs.process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  inputs.devenv.url = "github:cachix/devenv/v1.6.1";
  inputs.devenv.inputs.nixpkgs.follows = "nixpkgs";
  # devenv's cachix and vendored-nix each pin their own nixpkgs; unfollowed that is
  # ~800MB of duplicate store paths in EVERY repo consuming v_flakes, devenv or not.
  inputs.devenv.inputs.cachix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.devenv.inputs.nix.inputs.nixpkgs.follows = "nixpkgs";

  outputs = { self, nixpkgs, rust-overlay, flake-utils, pre-commit-hooks, flake-parts, process-compose-flake, devenv }:
    assert nixpkgs.rev == (import ./default_nixpkgs.nix).rev;
    assert rust-overlay.rev == (import ./default_rust_overlay.nix).rev;
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
    flake-utils.lib.eachDefaultSystem
      (system:
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
            lastSupportedVersion = "nightly-${(import ./rs).nightly_version}";
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
          # Dogfooding: this repo consumes its own commit-msg hook.
          preCommitCheck = pre-commit-hooks.lib.${system}.run (files.preCommit {
            inherit pkgs;
            stripClaudeSignature = true;
          });
          combined = utils.combine {
            inherit rust;
            modules = [
              rsModule
              github
              readme
              {
                shellHook = utils.mkShellHook ''
                  cp -f ${(files.gitignore { inherit pkgs; langs = [ "rs" ];})} ./.gitignore
                '';
              }
            ];
          };
        in
        {
          # Exposed as a package (not just `rs.sort_derives`) so CI can `nix run` the same
          # binary the dev shells get, instead of a divergent upstream build.
          packages.cargo-sort-derives = (import ./rs).sort_derives system;
          packages.cargo-machete = (import ./rs).machete system;

          devShells.default = pkgs.mkShell {
            inherit stdenv;
            packages = with pkgs; [ curl mold rust ] ++ preCommitCheck.enabledPackages ++ combined.enabledPackages;
            shellHook = ''
              # Before combined: append_custom.rs only patches .git/hooks/pre-commit
              # if it already exists, and this is what writes it.
              ${preCommitCheck.shellHook}
              # Guard first: combined.shellHook aborts (exit 1) the entire hook
              # unless we are anchored at the repo root, so nothing below runs
              # — and pollutes a subdirectory — when invoked from elsewhere.
              ${combined.shellHook}
              cp -f ${files.treefmt { inherit pkgs; }} ./.treefmt.toml
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
      # Re-exported so consumers pin one input (v_flakes) instead of each carrying
      # their own copies — same rev everywhere means nix store dedup, shared caches.
      # `nixpkgs` is the flake (for consumers needing `.lib`); default_nixpkgs above
      # is the same rev as a bare source tree, for `import`.
      inherit nixpkgs flake-utils rust-overlay pre-commit-hooks flake-parts process-compose-flake devenv;
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
      qlty = import ./qlty.nix;

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
