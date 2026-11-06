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
    ├── tools/         (self-pinned binaries: qlty, cargo-machete, cargo-diet, cargo-sort-derives, kache; depend on pins/)
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

### Compile reuse across checkouts

Agents build in `.claude/worktrees/<name>/`. Each one would otherwise compile the whole dependency graph from scratch.

```
 main/                                 main/.claude/worktrees/x/
 ├ .cargo/config.toml  ◄── cargo reads both ──┤ .cargo/config.toml
 ├ target/  (own)                             ├ target/  (own)
 └───────────────┬────────────────────────────┴───────┘
                 ▼
   kache: content-addressed store + daemon, ~/.cache/kache
```

- One `target/` per checkout, plus kache (`tools/kache.nix`, self-pinned; ~/nix installs the same build as the global wrapper). It's set as `rustc-wrapper`. Its `cargo` shim goes on PATH in front of the toolchain: the shim seeds a new `target/` from the store and leases it against cleanup. kache's `cc`/`gcc` shims stay off PATH, since they would sit in front of nix's cc-wrapper; build-script runs, where `cc` work happens, are cached anyway
- Rejected, all tested:
  - A shared `target`/`build-dir`. Cargo keys workspace crates by path relative to the workspace root, so `main/lib` and `wt/lib` share a slot, and freshness is mtime: main ran the worktree's code. `-Zchecksum-freshness` fixes `.rs` sources but not build-script output, so binaries embedded the other checkout's git hash (every generated `build.rs` reads git state). `-Zfine-grain-locking` deadlocks here (cargo#17508)
  - sccache: it doesn't cache proc-macros, build-script runs or incremental crates, and it keys on absolute paths. That gave about 5% hits
- Generated `rustflags` are one space-joined string, never an array. A nested worktree's cargo loads main's `config.toml` too, and arrays concatenate across files: every flag twice, worktree units hashed apart from main's, 0 hits. A string comes from the closest file only. The generator asserts that no flag contains whitespace, because cargo splits the string on it
  - Cargo errors on every invocation when a key is a string in one config file and an array in another. nixpkgs' rustPlatform writes `target.<host triple>.rustflags` as an array into the sandbox's `/build/.cargo/config.toml`, above the source. So generated rustflags sit under `target.'cfg(..)'` keys (`tripleCfg` maps each triple), whose flags cargo joins with every matching triple key. No config up the tree, `~/.cargo/config.toml` included, may set those cfg keys or `build.rustflags` as an array
  - Tables still merge, so main's local `[patch.*]` applies in its nested worktrees
- `kache = false` writes `rustc-wrapper = ""`. That turns off a global wrapper too
- Nix sandbox builds have no kache: a consumer's package sets `RUSTC_WRAPPER = ""`, which overrides the config
- Misses: `kache stats --last-build`; `kache config set cache.explain_miss true` then `kache explain <crate>`; or diff the `KACHE_LOG=trace` `[key:<crate>]` lines of two checkouts

## langs/typ/

- Given `src`, the module reads every `@preview/<name>:<version>` import in it from the source text and bundles those packages from nixpkgs' `typstPackages` (or `extraPackages`, sources with a typst.toml) into the shipped `typst`. `@local` imports must come from `extraPackages`; they're linked in as-is and their own imports are bundled too. All this lets documents build in the network-less sandbox. The devShell and tinymist get the same package path. They still fall back to downloading, so adding a new import doesn't require reloading the shell
- `typst` always has the `html` feature enabled; `document` compiles `main` to PDF (plus HTML with `html = true`)

## readme_fw/

README generation from `docs/.readme_assets/`:

- Reads `description.md`, `usage.md`, etc.
- Generates badges (msrv, crates.io, docs.rs, loc, ci)
- Compiles typst (`.typ`) to markdown if present
- Manages license file copying
