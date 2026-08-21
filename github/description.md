GitHub integration module combining workflows, git hooks, and related tooling.

Usage:
```nix
github = v-utils.github {
  enable = true;  # Enable CI workflows, pre-commit hooks, gitignore, label sync
  inherit pkgs pname rs;  # Pass language modules — langs is inferred automatically
  # inherit py tex;       # Pass any combination; langs = ["rs" "py" "tex"] inferred
  lastSupportedVersion = "nightly-1.86";
  gitignore.extra = "_scripts/node_modules";  # Appended to generated .gitignore
  lfs = false;  # null (default): don't touch .gitattributes; false: explicitly opt out of LFS for known binary patterns; true: track them via LFS

  # Top-level install applies to all sections (errors, warnings, other, release)
  # Per-section install overrides this.
  install = { packages = [ "mold" "pkg-config" ]; };

  # Jobs configuration - new interface
  jobs = {
    default = true;  # Enable defaults for all sections (based on langs)

    # Or configure each section individually:
    errors = {
      default = true;        # Enable default error jobs for langs
      augment = [ "rust-miri" ];  # Add extra jobs
      exclude = [ "rust-doc" ];   # Remove from defaults
      install = { packages = [ "wayland" "libxkbcommon" ]; };  # Per-section override
      # hooks: override the `on` triggers for this workflow (default: push + pull_request)
      # workflow_dispatch is always appended automatically unless you set it explicitly.
      hooks = { push = { branches = [ "main" ]; }; pull_request = { }; };
    };
    warnings = {
      default = true;
      augment = [ { name = "rust-clippy"; args.extra = "--all-features"; } ];
    };
    other = {
      default = true;
      augment = [ "loc-badge" ];
    };
  };

  labels = {
    enable = true;    # Auto-sync labels on shell entry (default: true)
    defaults = true;  # Include default labels (default: true)
    extra = [         # Additional labels
      { name = "priority:high"; color = "ff0000"; description = "High priority"; }
    ];
  };
  preCommit = {
    semverChecks = false;  # Run cargo-semver-checks (default: false, can be very slow)
  };
  # Copy convention files (e.g. GIT_CONVENTION.md) from github.com/<owner>/<owner>
  # or github.com/<owner>/.github on shell entry. Cached per v_flakes version, so
  # subsequent rebuilds are no-ops until v_flakes itself is bumped. Default: false.
  conventions = true;
  # Style settings are inherited from rs module automatically.
  # Override with style = { ... } or traceyCheck = ... if needed.

  # Binary releases — one workflow per target (release-{shortName}.yml)
  # Enabled by presence, disabled with `enable = false`
  release = { };  # Defaults: push to v* tags + workflow_dispatch, standard targets
  # OR customize:
  release = {
    targets = [ "x86_64-unknown-linux-gnu" "x86_64-apple-darwin" "aarch64-apple-darwin" ];
    aptDeps = [ "libssl-dev" ];  # Optional apt deps for linux builds
    # hooks: override `on` triggers (default: push.tags = ["v[0-9]+.*"]; workflow_dispatch always appended)
    hooks = { push.tags = [ "v[0-9]+.*" ]; push.branches = [ "release" ]; };
    # gate: shell condition — release only runs if true. Default: no gate (always run).
    gate = "\"$(git show HEAD~1:Cargo.toml | grep '^version' | head -1)\" != \"$(grep '^version' Cargo.toml | head -1)\"";
    # cargoTomlPath: path to the binary crate's Cargo.toml (relative to repo root).
    # Required in workspaces where the root has no [package] section. Default: "Cargo.toml".
    cargoTomlPath = "./social_networks/Cargo.toml";
  };

  # Sync fork over upstream via rebase (daily schedule + manual trigger)
  # Can also be set via jobs.sync_fork = true;
  syncFork = true;

  # GitLab mirror sync (triggers on any push)
  gitlabSync = { mirrorBaseUrl = "https://gitlab.com/user"; };
  # Repo name appended from GitHub context. Requires GITLAB_TOKEN secret

  # Publish packages.default to a cachix cache on every push to main, so downstream
  # flakes substitute instead of rebuilding. Requires CACHIX_AUTH_TOKEN; public repos only.
  publishCachix = "valeratrades";
};
```

Then use in devShell:
```nix
devShells.default = pkgs.mkShell {
  shellHook = github.shellHook;
  packages = [ ... ] ++ github.enabledPackages;
};
```

The shellHook will:
- Copy workflow files to .github/workflows/
- Set up git hooks (pre-commit with treefmt integration)
- Copy gitignore based on specified langs
- Copy gitattributes when `lfs` is set (true to track via LFS, false to explicitly opt out)

Label sync also runs todo-sync: every `TODO<bangs>:` comment in the repo becomes a
`ext:from_todo` issue, and closing that issue deletes the comment from the file.

- Keep the whole comment on one line. It is read from `TODO` to end of line, so a wrapped
  continuation never reaches the issue and survives the deletion as orphaned prose.
- Fixture paths are skipped, so test data containing that literal is left alone — see
  `FIXTURE_PATHSPECS` in `github/git_ops.rs` for the exact list.

enabledPackages includes:
- `git_ops` - GitHub operations (sync-labels, etc.)
- `code_duplication` - Run the same duplication detection used in CI locally (requires qlty)
