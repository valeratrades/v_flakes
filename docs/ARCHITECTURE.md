# Architecture

v-utils is a Nix flake providing reusable components for project configuration. Each module is independent and composable.

## Module Dependencies

```
flake.nix (entry point)
    │
    ├── files/         (lang-agnostic templates: gitignore, envrc, treefmt, licenses; re-exports langs/*/files)
    │
    ├── git/           (pre-commit: hooks.nix for git-hooks.nix, pre_commit.nix + pre-commit.rs for .git/hooks/custom.sh)
    │
    ├── github/        (depends on: files/, git/)
    │
    ├── pins/          (standalone - nixpkgs / rust-overlay revs, asserted equal to flake inputs)
    │
    ├── tools/         (self-pinned binaries: qlty, cargo-machete, cargo-diet, cargo-sort-derives; depend on pins/)
    │
    ├── langs/         (per-language modules: rs py js tex typ lean go)
    │   └── <lang>/files/  (that language's config templates)
    │
    ├── readme_fw/     (standalone)
    │
    ├── cli/           (the v_flakes crate: helpers the nix scripts depend on, `v_flakes` binary)
    │
    └── utils/         (standalone - helper functions)
```

## Key Entry Points

- `flake.nix` - Main flake definition, exports all modules
- `*/default.nix`, `langs/*/default.nix` - Each module's entry point

## Data Flow

1. Consumer flake imports `v-utils`
2. Consumer calls module functions with config (e.g., `v-utils.rs { pkgs; tracey = true; }`)
3. Module returns:
   - `shellHook` - Commands to run on `nix develop`
   - `enabledPackages` - Packages to include in dev shell
   - Generated files/configs

## files/

Templates for project files. Each submodule generates a derivation containing the file.

- `gitignore/` - Language-specific gitignore rules
- `envrc/` - `.envrc`, the `--impure` nix wrapper behind `impure`
- `treefmt.nix` - treefmt configuration
- `licenses/` - License file templates

## github/

GitHub-specific configuration:

- `workflows/` - CI workflow generation (errors.yml, warnings.yml)
- `labels.nix` - GitHub label synchronization
- `git-ops.rs` - Rust script for git operations

## cli/

- `org_properties.json` - org custom property definitions; `v_flakes org sync` (cli/src/main.rs) writes them, generated workflows read them (`pr_auto_review` gates claude-code-review.yml)

## langs/rs/

Rust toolchain configuration (config templates in `files/`):

- Generates `build.rs` for cranelift backend detection
- Integrates cargo-deny for dependency auditing
- Configures tracey for spec coverage
- Sets up codestyle linting
- `.cargo/config.toml` is merged: `cargo-config-merge.rs` owns only the keys v_flakes generates, the rest of the file is kept; `cargo-patch.awk`, as a git clean filter registered in `info/attributes`, keeps local `[patch.*]` out of the index

## readme_fw/

README generation from `docs/.readme_assets/`:

- Reads `description.md`, `usage.md`, etc.
- Generates badges (msrv, crates.io, docs.rs, loc, ci)
- Compiles typst (`.typ`) to markdown if present
- Manages license file copying
