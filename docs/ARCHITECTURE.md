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

- `particles/` - a repo's checks, one registry: `jobs.errors` / `jobs.warnings` list them, the list their severity. Each one is in all three of
  - `nix run .#test` (`runner.sh`; `apps.test` added by v_flakes' flake-utils / flake-parts, which find the runner in the devShell): parallel locally, per-particle status, prepare seconds and run seconds; non-zero iff an error particle fails, or with `--severity`, any it ran
  - its section's workflow: a particle with a `ci` body is a job of its own, the rest a job each running `nix run .#test -- --severity <s> <name>`, from the store paths one `particles` job built for them all
  - its section's README badge, written by the workflow's `report` job on the default branch: failed count and the sum of the particles' own seconds (no install or cache restore, so it compares with a serial local run)
  - `prepare` is timed apart from `program`: `<name>_prepare_seconds` beside `<name>_seconds` (the program alone), shared prepares reporting once per dependent. `rust-tests` prepares its warm build (`cargo test --no-run`); its bespoke job exposes both durations as job outputs, and the `report` job writes the `build` / `test` gist badges from them, only for a succeeded job. Nothing else writes those keys
  - Programs and prepares are carried as `.drv` paths, built when selected: the CI job of one section never builds another's closure
- `workflows/` - CI workflow generation (errors.yml and warnings.yml from particles; other.yml; the standalone ones)
- `cache.nix` - the only Nix install + binary-cache definition. Generated jobs inline it; hand-written workflows reach it through the generated `.github/actions/nix-env` composite action
- `labels.nix` - GitHub label synchronization
- `git-ops.rs` - Rust script for git operations; `sync-github` (detached on pre-commit) converges the GitHub repo's state, and records one-time setups (Discussions) in `.v_flakes.lock` next to the generator line

## cli/

- `org_properties.json` - org custom property definitions; `v_flakes org sync` (cli/src/main.rs) writes them, generated workflows read them (`pr_auto_review` gates claude-code-review.yml)
- `src/clean_up_gitlfs.rs` - `v_flakes clean-up-gitlfs-dangerous`: GitHub bills LFS objects until the repo is deleted, and refuses pushes whose history points at objects it lacks (GH008). So: rewrite history without the pointers no branch tip uses, push it to a new repo, transfer issues at their own numbers, swap names, archive the old one as `.bak`. Needs gh, git-lfs, git-filter-repo on PATH

## langs/rs/

Rust toolchain configuration (config templates in `files/`):

- Generates `build.rs` (git hash, log directives)
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

- One `target/` per checkout, plus kache. The devshell exports it as `RUSTC_WRAPPER`, never writes it to the committed `config.toml`: a plain `cargo build` without the shell, or a nix sandbox build, must work on a machine without kache. A `RUSTC_WRAPPER` the caller set (CI sets it empty) wins. The devshell uses the machine's kache, whose daemon every client talks to, so a kache bump can't leave repos with older locks on another version; `tools/kache.nix` (self-pinned, what ~/nix installs) is used only where none is installed. Where neither exists (no upstream release for the platform, as FreeBSD), the wrapper is `sccache` if on PATH, else none; v_flakes doesn't bring sccache. Its `cargo` shim goes on PATH in front of the toolchain: the shim seeds a new `target/` from the store and leases it against cleanup. kache's `cc`/`gcc` shims stay off PATH, since they would sit in front of nix's cc-wrapper; build-script runs, where `cc` work happens, are cached anyway
- Rejected, all tested:
  - A shared `target`/`build-dir`. Cargo keys workspace crates by path relative to the workspace root, so `main/lib` and `wt/lib` share a slot, and freshness is mtime: main ran the worktree's code. `-Zchecksum-freshness` fixes `.rs` sources but not build-script output, so binaries embedded the other checkout's git hash (every generated `build.rs` reads git state). `-Zfine-grain-locking` deadlocks here (cargo#17508)
  - sccache: it doesn't cache proc-macros, build-script runs or incremental crates, and it keys on absolute paths. That gave about 5% hits
- Generated `rustflags` are one space-joined string, never an array. A nested worktree's cargo loads main's `config.toml` too, and arrays concatenate across files: every flag twice, worktree units hashed apart from main's, 0 hits. A string comes from the closest file only. The generator asserts that no flag contains whitespace, because cargo splits the string on it
  - Cargo errors on every invocation when a key is a string in one config file and an array in another. nixpkgs' rustPlatform writes `target.<host triple>.rustflags` as an array into the sandbox's `/build/.cargo/config.toml`, above the source. So generated rustflags sit under `target.'cfg(..)'` keys (`tripleCfg` maps each triple), whose flags cargo joins with every matching triple key. No config up the tree, `~/.cargo/config.toml` included, may set those cfg keys or `build.rustflags` as an array
  - Tables still merge, so main's local `[patch.*]` applies in its nested worktrees
- Workspace members compile with cranelift (`cranelift-wrapper.sh` as `RUSTC_WORKSPACE_WRAPPER`, exported by the shell rather than written to config, which a nix sandbox build would read). Cargo has no per-target profile and cranelift has no wasm32, so the wrapper picks it per invocation: host target and opt-level 0 only. Deps stay on LLVM; kache caches them once anyway
- `kache = false` exports an empty `RUSTC_WRAPPER`. That turns off a global wrapper too
- Misses: `kache stats --last-build`; `kache config set cache.explain_miss true` then `kache explain <crate>`; or diff the `KACHE_LOG=trace` `[key:<crate>]` lines of two checkouts

## langs/typ/

- Given `src`, the module reads every `@preview/<name>:<version>` import in it from the source text and bundles those packages from nixpkgs' `typstPackages` (or `extraPackages`, sources with a typst.toml) into the shipped `typst`. `@local` imports must come from `extraPackages`; they're linked in as-is and their own imports are bundled too. All this lets documents build in the network-less sandbox. The devShell and tinymist get the same package path. They still fall back to downloading, so adding a new import doesn't require reloading the shell
- `typst` always has the `html` feature enabled; `document` compiles `main` to PDF (plus HTML with `html = true`)

## readme_fw/

README generation from `docs/.readme_assets/`:

- Reads `description.md`, `usage.md`, etc.
- Generates badges (msrv, crates.io, docs.rs, loc, ci, build_time, test_time, size). The gist-backed ones (loc, ci, build_time, test_time, size) are shields.io endpoint files that CI jobs already running write as a by-product (`github/workflows/nix-parts/shared/gist-badges.nix`); none runs work of its own. `build_time`/`test_time` are added to every repo with a root `Cargo.toml`; the `report` job writes them (prepare and run seconds of `rust-tests`)
- Compiles typst (`.typ`) to markdown if present
- Manages license file copying
