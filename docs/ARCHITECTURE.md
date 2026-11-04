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
    ├── pins/          (standalone - nixpkgs / rust-overlay revs, asserted equal to flake inputs; the skargo rev skills.yml runs)
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
- `git-ops.rs` - Rust script for git operations; `sync-github` (detached on pre-commit) converges the GitHub repo's state, and records one-time setups (Discussions) in `.v_flakes.lock` next to the generator line

## cli/

- `org_properties.json` - org custom property definitions; `v_flakes org sync` (cli/src/main.rs) writes them, generated workflows read them (`pr_auto_review` gates claude-code-review.yml)
- `src/clean_up_gitlfs.rs` - `v_flakes clean-up-gitlfs-dangerous`: GitHub bills LFS objects until the repo is deleted, and refuses pushes whose history points at objects it lacks (GH008). So: rewrite history without the pointers no branch tip uses, push it to a new repo, transfer issues at their own numbers, swap names, archive the old one as `.bak`. Needs gh, git-lfs, git-filter-repo on PATH

## langs/rs/

Rust toolchain configuration (config templates in `files/`):

- Generates `build.rs` for cranelift backend detection
- Integrates cargo-deny for dependency auditing
- Configures tracey for spec coverage
- Sets up codestyle linting
- `.cargo/config.toml` is merged: `cargo-config-merge.rs` owns only the keys v_flakes generates, the rest of the file is kept; `cargo-patch.awk`, as a git clean filter registered in `info/attributes`, keeps local `[patch.*]` out of the index

## langs/typ/

- Given `src`, the module reads every `@preview/<name>:<version>` import in it from the source text and bundles those packages from nixpkgs' `typstPackages` (or `extraPackages`, sources with a typst.toml) into the shipped `typst`. `@local` imports must come from `extraPackages`; they're linked in as-is and their own imports are bundled too. All this lets documents build in the network-less sandbox. The devShell and tinymist get the same package path. They still fall back to downloading, so adding a new import doesn't require reloading the shell
- `typst` always has the `html` feature enabled; `document` compiles `main` to PDF (plus HTML with `html = true`)

## readme_fw/

README generation from `docs/.readme_assets/`:

- Reads `description.md`, `usage.md`, etc.
- Generates badges (msrv, crates.io, docs.rs, loc, ci)
- Compiles typst (`.typ`) to markdown if present
- Manages license file copying
