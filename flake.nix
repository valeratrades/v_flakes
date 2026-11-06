{
  description = ''
    # Nix parts collection

    Collection of reusable Nix components.
    See individual component descriptions in their respective directories.'';

  # Revs must equal ./pins/nixpkgs.nix and ./pins/rust_overlay.nix (asserted
  # below). Flake inputs can't reference those files, so they are restated here —
  # otherwise this repo, and every consumer of the re-exported inputs, would drift
  # off the pins we hand out.
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/7a6522c868711d06e3a520bbcdfafe9806f4337f";
  inputs.rust-overlay.url = "github:oxalica/rust-overlay/892c035d7c2ff75acd5da10424a47ab454e1f3dc";
  inputs.rust-overlay.inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-utils.url = "github:numtide/flake-utils";
  inputs.pre-commit-hooks.url = "github:cachix/git-hooks.nix";
  inputs.pre-commit-hooks.inputs.nixpkgs.follows = "nixpkgs";
  inputs.flake-parts.url = "github:hercules-ci/flake-parts";
  inputs.flake-parts.inputs.nixpkgs-lib.follows = "nixpkgs";
  inputs.process-compose-flake.url = "github:Platonic-Systems/process-compose-flake";
  inputs.lean4-nix.url = "github:lenianiva/lean4-nix/e04ca093bca4c944f587c5e306cb5ff0c2c6ea87"; # manifests up to lean v4.33.1
  inputs.lean4-nix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.lean4-nix.inputs.flake-parts.follows = "flake-parts";
  inputs.devenv.url = "github:cachix/devenv/v1.6.1";
  inputs.devenv.inputs.nixpkgs.follows = "nixpkgs";
  # devenv's cachix and vendored-nix each pin their own nixpkgs; unfollowed that is
  # ~800MB of duplicate store paths in EVERY repo consuming v_flakes, devenv or not.
  inputs.devenv.inputs.cachix.inputs.nixpkgs.follows = "nixpkgs";
  inputs.devenv.inputs.nix.inputs.nixpkgs.follows = "nixpkgs";
  # devenv's subtree pins its own git-hooks.nix / flake-parts / flake-compat at
  # revs we already carry — ~700KB of second copies in every consumer's lock.
  inputs.devenv.inputs.git-hooks.follows = "pre-commit-hooks";
  inputs.devenv.inputs.flake-compat.follows = "pre-commit-hooks/flake-compat";
  inputs.devenv.inputs.nix.inputs.flake-parts.follows = "flake-parts";

  outputs = { self, nixpkgs, rust-overlay, flake-utils, pre-commit-hooks, flake-parts, process-compose-flake, devenv, lean4-nix }:
    assert nixpkgs.rev == (import ./pins/nixpkgs.nix).rev;
    assert rust-overlay.rev == (import ./pins/rust_overlay.nix).rev;
    let
      pname = "v_flakes";
      isRust = packages: (builtins.tryEval (packages ? default && packages.default ? cargoDeps)).value; # a packages.default that fails to evaluate gets no apps.default

      # `combine` stamps every repo it generates into with this v_flakes, and refuses to run
      # under an older one than the stamp; see `utils.combine`.
      utils =
        let raw = import ./utils;
        in raw // { combine = args: raw.combine (args // { generator = { stamp = self.lastModified; rev = self.shortRev or self.dirtyShortRev; }; }); };

      # Version constants for bundled packages - update these when bumping
      # Use partial semver (major.minor) - patch versions auto-resolve via cargo-binstall
      traceyVersion = "1.3";
      codestyleVersion = "0.2";
      steCheckerVersion = "0.2";

      parts = {
        files = (import ./files).description;
        github = (import ./github { inherit nixpkgs; }).description;
        rs = (import ./langs/rs { inherit nixpkgs; }).description;
        py = (import ./langs/py { inherit nixpkgs; }).description;
        tex = (import ./langs/tex { inherit nixpkgs; }).description;
        typ = (import ./langs/typ { inherit nixpkgs; }).description;
        js = (import ./langs/js { inherit nixpkgs; }).description;
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
          rust = (import ./langs/rs).default_nightly system;
          stdenv = pkgs.stdenvAdapters.useMoldLinker pkgs.stdenv;
          utils = import ./utils;
          files = import ./files;

          rsModule = (import ./langs/rs) { inherit pkgs rust; cargoRoot = "cli"; };
          github = (import ./github) {
            inherit pkgs pname;
            rs = rsModule;
            enable = true;
            lastSupportedVersion = "nightly-${(import ./langs/rs).nightly_version}";
            jobs = {
              default = true;
              errors.hooks = { push.paths = [ "cli/src/**" ]; };
              warnings.hooks = { push.paths = [ "cli/src/**" ]; };
            };
            release.hooks = { push.tags = [ "v[0-9]+.[0-9]+.0" ]; };
            skills = { };
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
            # A `.v_flakes.lock` stamp of its own `lastModified` would lag every commit; the devShell checks HEAD instead.
            generator = null;
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
          packages.cargo-sort-derives = (import ./langs/rs).sort_derives system;
          packages.cargo-machete = (import ./langs/rs).machete system;
          packages.kache = (import ./langs/rs).kache system; # ~/nix installs this one, so the shared daemon and every client are the same kache
          packages.v_flakes = (let build_rust = (import ./langs/rs).build_nightly system; in pkgs.makeRustPlatform { cargo = build_rust; rustc = build_rust; }).buildRustPackage {
            inherit pname;
            version = (builtins.fromTOML (builtins.readFile ./cli/Cargo.toml)).package.version;
            src = pkgs.lib.fileset.toSource {
              root = ./cli;
              fileset = pkgs.lib.fileset.unions [ ./cli/Cargo.toml ./cli/Cargo.lock ./cli/build.rs ./cli/src ./cli/org_properties.json ];
            };
            cargoLock.lockFile = ./cli/Cargo.lock;
            doCheck = false; # tests/ is outside the fileset
          };

          apps.help = utils.help {
            inherit pkgs self system;
            about = ''
              ${pname} — shared Nix parts. Consumers pin one input:
                inputs.v_flakes.url = "github:valeratrades/v_flakes?ref=v1.6";
              Parts (v_flakes.<attr>):  files github rs py tex typ js readme-fw utils qlty container lean
              Re-exported inputs:       nixpkgs default_nixpkgs flake-utils rust-overlay pre-commit-hooks
                                        flake-parts process-compose-flake devenv lean4-nix
              v_flakes org sync <ORG>   converge org custom property definitions (cli/org_properties.json)
              v_flakes clean-up-gitlfs-dangerous <OWNER/REPO>
                                        re-home a repo without the LFS objects no branch tip uses; old one archived as .bak
              ./__scripts/release.sh    release (see `docs/`)
            '';
          };

          devShells.default = pkgs.mkShell {
            inherit stdenv;
            packages = with pkgs; [ curl mold rust ] ++ preCommitCheck.enabledPackages ++ combined.enabledPackages;
            shellHook = ''
              # A cached dev shell is an older self, and nix-direnv never sees langs/ change: refuse when HEAD is newer than this shell's source.
              if [ "$(git log -1 --format=%ct)" -gt ${toString self.lastModified} ]; then
                rm -f .direnv/flake-profile-*
                printf '%s\n' "✘ v_flakes: this shell was built from a commit older than HEAD, and would write its older generated files." "  Dropped the cached dev shell; \`direnv reload\` builds the current one." >&2
                exit 1
              fi
              # Before combined: append-custom.rs only patches .git/hooks/pre-commit
              # if it already exists, and this is what writes it.
              ${preCommitCheck.shellHook}
              # Guard first: combined.shellHook aborts (exit 1) the entire hook
              # unless we are anchored at the repo root, so nothing below runs
              # — and pollutes a subdirectory — when invoked from elsewhere.
              ${combined.shellHook}
              cp -f ${files.treefmt { inherit pkgs; }} ./.treefmt.toml
              _bump_script="./__scripts/bump-crate.rs"
              ${utils.checkCrateVersion { name = "tracey"; currentVersion = traceyVersion; bumpScript = "$_bump_script"; }}
              ${utils.checkCrateVersion { name = "codestyle"; currentVersion = codestyleVersion; bumpScript = "$_bump_script"; }}
              ${utils.checkCrateVersion { name = "ste_checker"; currentVersion = steCheckerVersion; bumpScript = "$_bump_script"; }}
              # Bootstrap: build our own binaries and put them on PATH for local testing
              cargo b -q --manifest-path cli/Cargo.toml 2>/dev/null
              export PATH="$PWD/cli/target/debug:$PATH"
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

      default_nixpkgs = import ./pins/nixpkgs.nix;
      # Re-exported so consumers pin one input (v_flakes) instead of each carrying
      # their own copies — same rev everywhere means nix store dedup, shared caches.
      # `nixpkgs` is the flake (for consumers needing `.lib`); default_nixpkgs above
      # is the same rev as a bare source tree, for `import`.
      inherit nixpkgs rust-overlay pre-commit-hooks process-compose-flake devenv lean4-nix;
      # Wrapped to give every flake built through them an `apps.help`, unless it defines its own `help`,
      # and a rust `packages.default` an `apps.default` (utils/cargo-run.nix), unless it defines its own.
      flake-utils =
        let
          withApps = f: system:
            let
              out = f system;
              pkgs = nixpkgs.legacyPackages.${system};
              apps = (out.apps or { }) // nixpkgs.lib.optionalAttrs (!(out ? apps.default) && isRust (out.packages or { })) {
                default = import ./utils/cargo-run.nix { inherit pkgs; package = out.packages.default; };
              };
            in
            out // {
              apps = apps // nixpkgs.lib.optionalAttrs (!(out ? apps.help || out ? packages.help)) {
                help = import ./utils/help.nix {
                  inherit pkgs apps;
                  packages = out.packages or { };
                  devShells = out.devShells or { };
                };
              };
            };
        in
        flake-utils // {
          lib = flake-utils.lib // {
            eachSystem = systems: f: flake-utils.lib.eachSystem systems (withApps f);
            eachDefaultSystem = f: flake-utils.lib.eachDefaultSystem (withApps f);
          };
        };
      flake-parts = flake-parts // {
        lib = flake-parts.lib // {
          mkFlake = args: module: flake-parts.lib.mkFlake args {
            imports = [
              module
              {
                perSystem = { config, system, lib, ... }: {
                  apps.help = lib.mkIf (!(config.packages ? help)) (lib.mkDefault (import ./utils/help.nix {
                    pkgs = nixpkgs.legacyPackages.${system};
                    inherit (config) apps packages devShells;
                  }));
                  apps.default = lib.mkIf (isRust config.packages) (lib.mkDefault (import ./utils/cargo-run.nix {
                    pkgs = nixpkgs.legacyPackages.${system};
                    package = config.packages.default;
                  }));
                };
              }
            ];
          };
        };
      };
      files = import ./files;
      github = import ./github;
      container = import ./github/container/lib.nix;
      rs = import ./langs/rs;
      py = import ./langs/py;
      tex = import ./langs/tex;
      typ = import ./langs/typ;
      js = import ./langs/js;
      readme-fw = import ./readme_fw;
      inherit utils;
      qlty = import ./tools/qlty.nix;
      lean = import ./langs/lean { inherit lean4-nix; };

      # Backward compatibility aliases
      hooks = {
        description = "DEPRECATED: Use github module instead";
        appendCustom = ./git/append-custom.rs;
        treefmt = import ./files/treefmt.nix;
        preCommit = import ./git/pre_commit.nix;
      };
      workflows = import ./github/workflows/nix-parts;
      ci = import ./github;
    };
}
