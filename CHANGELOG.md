# Changelog

## Unreleased

- `utils.combine`: **Breaking** — now takes an attrset `{ rust, modules }` instead of a bare module list, and `rust` (the nix rust toolchain, e.g. `rs.rust`) is **required**. combine prepends `${rust}/bin` to PATH before any module hook runs, guaranteeing a working cargo for the custom rust scripts hooks invoke (`append_custom.rs`, `pyproject_merge.rs`, code-duplication, …). No more `rust != null` gates or silent rustup fallback at this layer — provision it or eval fails. Migrate `combine [ rs github readme ]` → `combine { inherit rust; modules = [ rs github readme ]; }`.
- `github`: with `enable = true`, the rust toolchain is now **asserted** (via the `rs` module) rather than silently skipping hook installation when absent — a missing `rs` fails loud at eval. The per-module `export PATH=${rust}/bin` and the `rust != null` gate around the hook install are gone (combine owns PATH now); `append_custom.rs` runs via plain `cargo`.
- `js`: new required `preCommit` arg — once the module is built, `preCommit.visual` (true/false) must be set explicitly (no default). When true, the pre-commit `custom.sh` runs `pnpm test:visual` (playwright), auto-locating the package.json that declares the `test:visual` script (repo root or `./frontend`) and re-staging any snapshot diffs. Drive it via `github { js = <js module>; ... }`.

## v1.6.1

- `rs`: **bugfix** — `binstallHook` no longer prepends `$HOME/.cargo/bin` to `PATH`. Doing so put the rustup shim ahead of the nix-provided cargo; if the active rustup toolchain happened to be broken (e.g. its patchelf'd ELF interpreter pointed at a nix-store glibc that had since been GC'd), every `cargo` invocation in the hook failed with `error: command failed: 'cargo' / No such file or directory`, silently broke the installed-version check, and then the install retry failed for the same reason. Now nix rust is prepended **at the very top** of `rs.shellHook` (covering `lintsHook`, `buildHook`, and `binstallHook` — all of which spawn `cargo` or `rustfmt`) and `~/.cargo/bin` is only appended (so cargo-installed binaries like `tracey`/`v_flakes` stay reachable, but `cargo` itself always resolves to the nix toolchain).
- **New `utils.withCargo`** — emits a shell snippet that runs its body with a `_v_flakes_cargo` shell function bound to a working cargo. Tries nix cargo on PATH first (probed with `cargo --version`, not just `command -v`, so a present-but-broken rustup shim doesn't count); falls back **loudly** to `rustup run nightly cargo` with a warning naming the caller and suggesting `rs` be added to `utils.combine`; hard-errors if neither is reachable. Used by:
  - `py.pyprojectHook` — `cargo -Zscript pyproject_merge.rs` now goes through `withCargo`, so a `py`-only combine no longer silently dispatches through whatever cargo PATH happens to surface.
  - `github.cargoNightly` (consumed by `git_ops` and `code_duplication`) — the previous silent rustup fallback was replaced with the same loud-warn / hard-error shape and gained the working-cargo probe.

## v1.6.0

- `github`: **Breaking** — the `excalidraw` param and bundled `ex` / `ex-to-md` / `md-to-ex` tools are removed. The standalone `ex` script now lives in the user's personal scripts (`~/nix/home/scripts/excalidraw.rs`); the markdown/mermaid integration is gone entirely. Drop any `excalidraw = { ... };` from your `github { ... }` call.
- `rs`: new `lints` param (default `true`) — manages `[lints.rust]` (or `[workspace.lints.rust]` when `[workspace]` is present) in `Cargo.toml` on shell entry. Default body: `unused_features = "allow"`. Pass `false` to disable, or an attrset to extend (per-key `.replace`/`.augment`/`.exclude` from `utils/core.nix` apply). Other lint sections (e.g. `[lints.clippy]`) are left alone.
  ```nix
  rs = v-utils.rs { inherit pkgs rust; lints = { unused_imports = "warn"; }; };
  rs = v-utils.rs { inherit pkgs rust; lints = false; };  # opt out
  ```
- `readme-fw`: **Breaking** — assets directory moved from `.readme_assets/` to `docs/.readme_assets/`. Run: `mv .readme_assets/ docs/.readme_assets/`
- `readme-fw`: `arch.mermaid` in `docs/.readme_assets/` is now embedded as a fenced mermaid block in the README
- `readme-fw`: warns at eval time if any file in `docs/.readme_assets/` is unrecognized and would be silently excluded
- `github`: new `jobs.*.hooks` param to override the `on:` triggers per workflow file:
  ```nix
  jobs.errors.hooks = { push = { branches = [ "main" ]; }; pull_request = {}; workflow_dispatch = {}; };
  ```
- `github`: new conditional release gate — release workflow only proceeds if `Cargo.toml` version changed since the previous commit

---

## v1.5.0

**Breaking: `github` now requires `enable = true`**
- `github` module has a new master switch `enable` that defaults to `false`.
  Without it, no CI workflows, pre-commit hooks, gitignore, or label sync are generated — only standalone workflows (`syncFork`, `gitlabSync`, `release`) still work.
  **All existing projects must add `enable = true`:**
  ```nix
  github = v-utils.github { inherit pkgs pname; enable = true; /* ... rest of params */ };
  ```
  A warning is printed at eval time if `enable`-gated fields are passed but `enable` is false.

**Breaking: array fields now require explicit `.augment` or `.replace`**
- Directly assigning a list to a field that already has a list now errors instead of silently augmenting:
  ```nix
  # old — used to silently append
  jobs.errors = [ "rust-miri" ];
  # new — must be explicit
  jobs.errors.augment = [ "rust-miri" ];  # append
  jobs.errors.replace = [ "rust-miri" ];  # replace entirely
  ```
  Applies across all modules (`rs`, `py`, `github`, file modules).

### v1.5.5
- `github`: Python projects now get a `pytest` GHA job when `py` module is passed

### v1.5.6
- Excalidraw: light/dark theme support

### v1.5.7
- Pre-commit: `cargo-autoinherit` added for Rust projects

### v1.5.8–18
- `rs`: new `config` param for arbitrary `.cargo/config.toml` extensions:
  ```nix
  rs = v-utils.rs { inherit pkgs rust; config = { build.jobs = 4; }; };
  ```

---

## v1.4.88–121

### v1.4.88–99
- `github`: top-level `install` param — nix packages applied to all CI job sections; per-section `install` still overrides:
  ```nix
  github = v-utils.github {
    install = { packages = [ "mold" "pkg-config" ]; };
    jobs.errors.install = { packages = [ "wayland" ]; };  # overrides for errors section only
  };
  ```

### v1.4.105
- `github`: new `gitignore.extra` param — append extra lines to the generated `.gitignore`

### v1.4.107
- `github`: new `syncFork` param — generates a daily-scheduled + manually-triggerable GHA workflow to rebase a fork over upstream:
  ```nix
  github = v-utils.github { syncFork = true; };
  # or via jobs: jobs.sync_fork = true;
  ```

### v1.4.118
- `github`: `langs` param deprecated — pass language modules directly, langs is now inferred:
  ```nix
  # old
  github = v-utils.github { inherit pkgs pname; langs = [ "rs" ]; };
  # new
  github = v-utils.github { inherit pkgs pname rs; };
  ```

### v1.4.119
- `py`: `ruff` param removed — ruff.toml is now always copied
- `py`: `pyproject.toml` tool sections (`tool.pytest`, `tool.ty`, `tool.inline-snapshot`) are now fully overwritten on each shell entry, not just appended when missing
- `py`: expanded ruff/pyproject linting defaults

---

## v1.4.0

**Breaking: `github` module**
- `jobsErrors`, `jobsWarnings`, `jobsOther` params removed. Use `jobs` instead:
  ```nix
  # old
  github = v-utils.github { jobsErrors = [ "rust-tests" ]; jobsWarnings = [ "rust-clippy" ]; };
  # new
  github = v-utils.github { jobs = { default = true; }; };
  # or granular:
  github = v-utils.github { jobs.errors.augment = [ "rust-miri" ]; jobs.warnings.exclude = [ "rust-doc" ]; };
  ```
- `jobs = { default = true; }` auto-populates jobs based on `langs` (e.g. `rs` gives rust-tests, rust-clippy, etc.)
- New params: `preCommit = { semverChecks = false; }`, `traceyCheck`, `styleCheck`

**Breaking: `rs` module**
- `build` param restructured: `log_directives`/`git_version` bools replaced by `build.workspace` map:
  ```nix
  # old
  build = { log_directives = true; git_version = true; };
  # new
  build.workspace = { "./" = [ "git_version" "log_directives" ]; };
  ```
- New params: `deny`, `tracey`, `style` (bool at v1.4.0, later becomes attrset)
- Now exposes `enabledPackages` - add to `packages` in devShell

### v1.4.1-10
- `defaults` param on `readme-fw` - when `true`, `licenses` can be omitted (defaults to Blue Oak)
- `rs.build`: `deprecate` module parses `since` markings, `force` mode added
- `rust-unused-features` added to default rs jobs

### v1.4.11-20
- `codestyle` replaces `rust_style`: `rs.style` changes from `bool` to attrset:
  ```nix
  # old
  style = true;
  # new
  style = { format = true; check = false; modules = { instrument = true; }; };
  ```
- `rust_style.rs` expanded: recognizes missing embeds for format strings
- `build.rs` modules now generate named functions; fixed extra closing brace bug
- `readme_fw`: architecture link joined into best_practices footnote
- Pre-commit: `nuke-snapshots` added for rs
- Codestyle version auto-bumping in CI

### v1.4.21-30
- Label sync now runs silently in background; on failure retries with output on next shell entry
- `binstall` integration: `releaseLatest` on `github` module for rolling releases per platform
- `default: bool` convention replaces `= {}` for defaults across modules
- Bump script fixes for personal binstalls
- `defaults` primitive added to `utils` to prevent naming mismatches (`default`/`defaults` aliases)

### v1.4.31-40
- **Breaking: `rs` now requires `rust` param** (the nix toolchain package):
  ```nix
  rs = v-utils.rs { inherit pkgs rust; };
  ```
  This prepends nix rust to PATH so it takes precedence over rustup shims.
- Release workflow fixes
- Bump script hardcodes removed

### v1.4.41-50
- GitLab mirror sync: `gitlabSync = { mirrorBaseUrl = "https://gitlab.com/user"; }` on `github`
  - Requires `GITLAB_TOKEN` secret
- `github` module accepts `rs` param to inherit style/tracey settings automatically:
  ```nix
  github = v-utils.github { inherit pkgs pname rs; };
  ```
- Binstall hook forces updates when outdated
- Gitignore matching improvements

### v1.4.51-60
- `v-utils.utils.combine` helper to merge modules:
  ```nix
  combined = v-utils.utils.combine [ rs github readme ];
  # then: packages = combined.enabledPackages; shellHook = combined.shellHook;
  ```
- `code-duplication` GHA workflow added (shared warning job)
- Lazy codestyle install (at pre-commit time, not shell entry)
- Treefmt no longer gets stuck with prompts

### v1.4.61-70
- `jobs.errors.install = { packages = [ "wayland" ]; }` - nix packages for CI jobs
- Qlty init fixes
- `enabledPackages` on `github` now includes `treefmt`

### v1.4.71-80
- LD_LIBRARY_PATH set for runtime library loading in CI
- `openssl.out` and `openssl.dev` auto-included in nix deps for jobs
- Dep updates now only run on minor+ version bumps (not patches)

### v1.4.81-87
- GitLab sync: LFS handling (skip during push, upload separately, disable LFS on mirror)
- `rs.targets` param for extra cargo target config in `.cargo/config.toml`
- Label sync state caching
- Readme-fw: logo auto-discovery from `.readme_assets/logo.(md|html)`

---

## v1.3.0

**New: `rs` module** for Rust project configuration:
```nix
rs = v-utils.rs {
  inherit pkgs;
  cranelift = true;
  build = { log_directives = true; git_version = true; };
};
# use rs.shellHook and add to devShell
```
- Copies rustfmt.toml, cargo config, generates build.rs
- `files.rust.build` added

### v1.3.1-3
- `rs.build`: doesn't assume top-level placement; uses parent dir of manifest file
- `cargo-semver-checks` added to pre-commit for rs
- Build.rs formatting fix

### v1.3.4-6
- `deprecate` module for build.rs: enforce removal of `#[deprecated]` items by version
- Lazy loading for build.rs modules
- `force` option on deprecation to rewrite all `since` attributes

### v1.3.7-10
- `cargo-deny` integration (`deny.toml` copied to project)
- `tracey` spec coverage tool integration
- `rust_style.rs` linter added
- Pre-commit: semver-checks

---

## v1.2.0

**New: `git_ops` with `sync-labels`** - automatic GitHub label synchronization:
```nix
github = v-utils.github {
  # ...existing params...
  labels = { defaults = true; extra = [{ name = "custom"; color = "ff0000"; }]; };
};
```
- `enabledPackages` now includes `git_ops` (was `git`)

### v1.2.1-4
- `build.rs` added to `files.rust`
- Optional `cranelift` backend support in cargo config
- Label duplicate color detection

---

## v1.1.0

**Breaking: `hooks` module merged into `github`**

```nix
# old (v1.0)
shellHook = ''
  ${v-utils.hooks.treefmt}
  ${v-utils.hooks.preCommit}
'';

# new (v1.1)
github = v-utils.github { inherit pkgs pname; langs = [ "rs" ]; };
# github.shellHook handles workflows + hooks + gitignore
# github.enabledPackages has required packages
```
- `v-utils.hooks` still exists as deprecated backward-compat alias
- `treefmt.nix` moved from `hooks/` to `files/`
- New: `v-utils.utils` module with `setDefaultEnv` and `requireEnv` helpers

---

## v1.0.0

Initial release. Modules:
- `files`: licenses (plain paths), rustfmt, deny, toolchain, config, clippy, python/ruff, golang/gofumpt, gitignore, gitattributes
- `hooks`: treefmt, pre-commit, append_custom
- `readme-fw`: README generation from `.readme_assets/`
- `workflows`/`ci`: GHA workflow generation

---

## Migration cheat-sheet

**v1.2 projects -> latest** (ask_llm, nautilus, polymarket_mm, prettify_log, shorts_basket, site, snapshot_fonts):
1. Change ref to `v1.4`
0. Add `enable = true` to your `github` call — **without this, nothing is generated**
2. `files.licenses.blue_oak` is now `{ name = "..."; path = ...; }`, not a plain path.
   If using `readme-fw` with `defaults = true`, you can drop explicit license params entirely.
3. `readme-fw` licenses changed from `[{ name = "Blue Oak 1.0.0"; outPath = "LICENSE"; }]` to `[{ license = v-utils.files.licenses.blue_oak; }]`
4. `github` params: replace `jobsErrors`/`jobsWarnings`/`jobsOther` with `jobs = { default = true; }`
5. Add `rs = v-utils.rs { inherit pkgs rust; };` if using Rust
6. Pass `rs` to `github`: `github = v-utils.github { inherit pkgs pname rs; };`
7. Consider using `v-utils.utils.combine [ rs github readme ]` instead of manually joining shellHooks

**v1.3 projects -> latest** (tg_admin):
1. Change ref to `v1.4`
0. Add `enable = true` to your `github` call — **without this, nothing is generated**
2. Steps 3-7 above
3. `rs` module: `build` param changed from `{ log_directives; git_version; }` to `{ workspace = { "./" = [...]; }; }`
4. `rs` now requires `rust` param: `v-utils.rs { inherit pkgs rust; }`
5. `style` changed from bool to attrset: `style = { format = true; check = false; }`
