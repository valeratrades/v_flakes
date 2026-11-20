{ pkgs ? null
, nixpkgs ? null
, # config options
  cranelift ? true
, # `--cfg web_sys_unstable_apis` on every target and in CI. For apps only: see files/config.nix
  webUnstable ? false
, # kache as rustc-wrapper and cargo shim; `false` builds with no wrapper at all
  kache ? true
, targets ? { }
, config ? { }
, deny ? false
, clippy ? { }
, sortDerives ? { }
, lints ? true
, tracey ? true
, # write pins/Cargo.toml's requirements into the workspace's manifests
  pinDeps ? false
, style ? { }
, # build.rs options
  build ? { }
, # directory of the Cargo root (the crate or workspace manifest), relative to the repo root
  cargoRoot ? "."
, # rust toolchain package - required to prepend to PATH so nix rust takes
  # precedence over rustup. Defaulted to null so the module can be imported with
  # just `nixpkgs` to read `.description` (flake.nix); real build paths assert it.
  rust ? null
,
}:
# Normalize style.modules: { instrument = true; loops = false; } -> "--instrument=true --loops=false"
# Accepts both booleans and strings as values
let
  styleModules = style.modules or { };
  # Convert value to string, handling both bool and string inputs
  valueToString = value:
    if builtins.isBool value then (if value then "true" else "false")
    else builtins.toString value;
  moduleFlags = builtins.concatStringsSep " " (
    builtins.attrValues (builtins.mapAttrs
      (name: value:
        "--${builtins.replaceStrings ["_"] ["-"] name}=${valueToString value}"
      )
      styleModules)
  );
in
# If called with just nixpkgs (for flake description), return description attribute
if nixpkgs != null && pkgs == null then {
  description = ''
    Rust project configuration module combining rustfmt, cargo config, and build.rs.

    Canonical toolchain — link it instead of assembling your own from rust-overlay:
    ```nix
    rust = v-utils.rs.default_nightly system;
    ```
    Self-pinned (own nixpkgs + rust-overlay + date, ignoring your inputs), so every
    repo on the same v_flakes minor resolves to a byte-identical store path: nix
    dedups it and kache cross-references compilations between repos. The pin lives
    in langs/rs/default_nightly.nix and moves ONLY on at-least-minor v_flakes bumps.

    Usage:
    ```nix
    rs = v-utils.rs {
      inherit pkgs rust;  # rust is the nix toolchain package
      cranelift = true;  # Workspace members compile with cranelift when unoptimized and for the host target; deps, wasm and release stay LLVM (default: true)
      kache = true;      # kache as rustc-wrapper (gitignored .cargo/local.toml), its cargo shim on PATH; sccache, then none, where kache isn't installed and has no release (default: true). `false` sets no wrapper, overriding a global one
      webUnstable = false; # Build against web-sys' unstable APIs (`--cfg web_sys_unstable_apis`), native + wasm + CI. Apps only: a library built so compiles against an API its dependents don't get (default: false)
      deny = false;      # Copy deny.toml for cargo-deny (default: false)
      clippy = {};      # Extend .cargo/clippy.toml (default: base defaults, see langs/rs/files/clippy.nix)
      sortDerives = {}; # Extend .sort-derives.toml (default: qualified_last, see langs/rs/files/sort_derives.nix)
      lints = true;     # `false` disables Cargo.toml [lints.rust]/[lints.cargo] (or [workspace.lints.*]) management. Pass an attrset to extend [lints.rust] defaults (default: { unused_features = "allow"; stable_features = "allow"; }). Use per-key `.replace`/`.augment`/`.exclude` modifiers from utils/core.nix. Also fills `[lints.clippy]` with `integer_division` + `if_not_else` = "warn", only where the manifest doesn't set that key.
      tracey = true;     # Enable tracey spec coverage (default: true)
      pinDeps = false;   # Rewrite the requirement of every registry dep named in v_flakes' pins/Cargo.toml to the pinned one, in the root and every member manifest; features, inherited, path and git deps untouched (default: false)
      cargoRoot = ".";   # Dir holding the Cargo root, relative to the repo root (default: "."). Same meaning as nixpkgs buildRustPackage.cargoRoot
      style = {
        format = true;   # Auto-fix style issues in pre-commit (default: true)
        check = false;   # Error on unfixable style issues (default: false)
        modules = {      # Toggle individual codestyle checks (default: use codestyle defaults)
          instrument = true;  # Require #[instrument] on async functions (default: false)
          loops = true;       # Enforce //LOOP comments on endless loops (default: true)
        };
      };
      build = {
        enable = true;          # Generate build.rs (default: true)
        workspace = {           # Per-directory build.rs modules, keys relative to the repo root (default: { "<cargoRoot>" = [ "git_version" "log_directives" ]; })
          "./" = [ "git_version" "log_directives" ];
          "./cli" = [ "git_version" "log_directives" { deprecate = { by_version = "2.0.0"; }; } ];
        };
      };
    };
    ```

    build.workspace: Map of directories to their build.rs module lists.
      Each directory gets its own build.rs with the specified modules.
      Available modules:
        - "git_version": Embed GIT_HASH at compile time
        - "log_directives": Embed LOG_DIRECTIVES from .cargo/log_directives
        - "deprecate": Deprecation enforcement (see below)
        - "api_docs": The handlers' `///` into OUT_DIR for ev_lib's `api_docs!()` (build-dependency
          `ev_lib` with feature `api_docs`)
        - { lightweight_charts = { version; sha256; }; }: Fetch lightweight-charts (see below)

      lightweight_charts module:
        Under the crate's `lightweight_charts` cargo feature, downloads
        lightweight-charts@<version>/dist/lightweight-charts.standalone.production.mjs into OUT_DIR
        and asserts it hashes to <sha256>, so the crate can `include_str!` it rather than vendoring
        196 KB of third-party JS into its published tarball. Needs `curl` and `sha256sum` on PATH.
        A rebuild that already holds the right bytes skips the download, so it stays offline.

        A hermetic build (nix) has no network inside the derivation: set `LWC_MJS` to a copy it
        fetched itself (`pkgs.fetchurl`) and the download is skipped. The <sha256> pin is asserted
        against that copy too, so the two sources are interchangeable rather than one being trusted.

        Both fields are required — the pin belongs next to the JS written against that API, so there
        is deliberately no default and no bare-string form.

          { lightweight_charts = { version = "5.2.0"; sha256 = "66ac22df..."; }; }

      deprecate module:
        Checks that #[deprecated] items are removed by their specified version.
        Uses the `since` attribute from each #[deprecated(since = "X.Y.Z")] to determine
        when an item should be removed. If current package version >= since version, build fails.

        Configuration:
          - "deprecate"
              Requires all #[deprecated] to have `since` attribute, errors otherwise.

          - { deprecate = { by_version = "X.Y.Z"; }; }
              Sets default version for items without `since`. Items with `since` still
              use their own version.

          - { deprecate = { by_version = "X.Y.Z"; force = true; }; }
              Rewrites ALL `since` attributes to the target version (adds if missing,
              replaces if different), then exits. Useful for bumping all deprecation
              deadlines at once before a release.

    Then use in devShell:
    ```nix
    devShells.default = pkgs.mkShell {
      shellHook = rs.shellHook;
      packages = [ ... ] ++ rs.enabledPackages;
    };
    ```

    The shellHook will:
    - Prepend nix rust to PATH so it takes precedence over rustup shims
    - Copy rustfmt.toml to ./rustfmt.toml
    - Merge cargo config into ./.cargo/config.toml: only the keys v_flakes generates are overwritten, everything else is kept (a git clean filter keeps local `[patch.*]` out of the index)
    - Copy clippy config to ./.cargo/clippy.toml
    - Copy sort-derives config to <cargoRoot>/.sort-derives.toml
    - Merge controlled `[lints.rust]` + `[lints.cargo]` (or `[workspace.lints.*]` if `[workspace]` exists) into <cargoRoot>/Cargo.toml, and seed `[lints.clippy]` keys the manifest doesn't set
    - Copy build.rs to each directory in build.workspace (with write permissions for treefmt)
    - Copy deny.toml to <cargoRoot>/deny.toml (if deny = true)

    cargoRoot: rustfmt.toml and .cargo/ stay at the repo root, as rustfmt and cargo search upward for them.
    The github module reads `rs.cargoRoot`: rust CI jobs and the rust pre-commit steps run there.

    enabledPackages includes:
    - `tracey` - spec coverage tool (if tracey = true)
    - `codestyle` - code style linter and formatter (if style.format or style.check is true)
    - `cargo-diet`, `cargo-release`, and `cpublish` — `cargo diet -r`, committing the manifest if
      its include changed (asks first; `-y` / `--yes` accepts), then `cargo release --no-confirm
      --execute` with the remaining args. On success it force-moves the `release` branch to the
      release commit.
  '';
} else

  assert pkgs.lib.assertMsg (rust != null)
    "rs module: `rust` toolchain package is required for the build/devshell path (only omittable when reading `.description` with just `nixpkgs`)";

  let
    core = import ../../utils/core.nix;
    utils = import ../../utils;
    diet = (import ../../tools/diet.nix) pkgs.stdenv.hostPlatform.system;
    kachePkg = (import ../../tools/kache.nix) pkgs.stdenv.hostPlatform.system;
    # Only the cargo shim: kache's cc/gcc ones would sit in front of nix's cc-wrapper. The marker makes kache skip this dir when looking for the real cargo.
    craneliftWrapper = pkgs.writeShellScript "cranelift-wrapper" (builtins.readFile ./cranelift-wrapper.sh);

    cargoRootNormalized =
      let
        stripped = pkgs.lib.removeSuffix "/" (pkgs.lib.removePrefix "./" cargoRoot);
        dir = if stripped == "" then "." else stripped;
      in
      assert pkgs.lib.assertMsg (!pkgs.lib.hasPrefix "/" dir && !builtins.elem ".." (pkgs.lib.splitString "/" dir))
        "rs module: cargoRoot must be a relative path without `..`, got ${cargoRoot}";
      dir;
    inRoot = f: if cargoRootNormalized == "." then "./${f}" else "./${cargoRootNormalized}/${f}";

    buildEnable = build.enable or true;
    workspace = build.workspace or { ${inRoot ""} = [ "git_version" "log_directives" ]; };

    # codestyle installed via binstall (same as tracey)
    # Building from source fails in nix sandbox due to TMPDIR issues during cargo build

    # Normalize directory path: ensure no trailing slash, then append /build.rs
    # Handles both "./" and "./cli" and "./cli/" correctly
    normalizePath = dir:
      let
        stripped = pkgs.lib.removeSuffix "/" dir;
      in
      if stripped == "." || stripped == "" then "./build.rs" else "${stripped}/build.rs";

    rustfmtFile = import ./files/rustfmt.nix { inherit pkgs; };
    targetsExtend = if targets != { } then { target.augment = targets; } else { };
    configExtend = assert !(config ? patch) || throw "v_flakes.rs: `config.patch` would be stripped from git by the `.cargo/config.toml` clean filter; put it in Cargo.toml"; core.mergeConfig targetsExtend config;
    configFile = import ./files/config.nix {
      inherit pkgs webUnstable;
      extend = configExtend;
    };
    denyExtend = if builtins.isAttrs deny then deny else { };
    denyFile = import ./files/deny.nix { inherit pkgs; extend = denyExtend; };
    clippyFile = import ./files/clippy.nix { inherit pkgs; extend = clippy; };
    sortDerivesFile = import ./files/sort_derives.nix { inherit pkgs; extend = sortDerives; };
    lintsExtend = if builtins.isAttrs lints then lints else { };
    lintsEnabled = if builtins.isBool lints then lints else true;
    lintsFile = import ./files/lints.nix { inherit pkgs; extend = lintsExtend; };
    manifest = inRoot "Cargo.toml";
    lintsHook =
      if lintsEnabled then ''
        export CARGO_UNSTABLE_CARGO_LINTS=true # pinned nightly ignores [lints.cargo] without it
        # `repository` comes from `origin`, as README links do; with none it is left alone
        if [ -f ${manifest} ] && ! _vf_fresh cargo-lints "${./cargo-merge.rs} ${lintsFile}" ${manifest} "$_vf_gitconfig"; then
          _vf_slug="$(git remote get-url origin 2>/dev/null | sed -E 's#^(https://github\.com/|git@github\.com:|ssh://git@github\.com/)##; s#\.git$##')"
          case "$_vf_slug" in
            */*) _vf_repo=(--repository "https://github.com/$_vf_slug") ;;
            *) _vf_repo=() ;;
          esac
          cargo -Zscript -q ${./cargo-merge.rs} ${manifest} ${lintsFile} "''${_vf_repo[@]}" && _vf_stamp cargo-lints "${./cargo-merge.rs} ${lintsFile}" ${manifest} "$_vf_gitconfig"
          unset _vf_slug _vf_repo
        fi
      '' else "";

    pinsKey = "${./cargo-pins.rs} ${../../pins/Cargo.toml}";
    pinsHook =
      if pinDeps then ''
        if [ -f ${manifest} ] && { [ ! -e .git ] || ! _vf_fresh cargo-pins "${pinsKey}" $(git ls-files -- '*Cargo.toml'); }; then
          cargo -Zscript -q ${./cargo-pins.rs} ${manifest} ${../../pins/Cargo.toml} && { [ ! -e .git ] || _vf_stamp cargo-pins "${pinsKey}" $(git ls-files -- '*Cargo.toml'); }
        fi
      '' else "";

    # Generate a build file for each workspace directory with its specific modules
    makeBuildFile = modules: import ./files/build.nix { inherit pkgs modules; };

    # Generate install commands for each workspace directory
    workspaceDirs = builtins.attrNames workspace;
    buildRustfmtFile = ./files/build/rustfmt.toml;
    buildHook =
      if buildEnable then
        builtins.concatStringsSep "\n"
          (map
            (dir:
              let
                buildFile = makeBuildFile workspace.${dir};
                targetPath = normalizePath dir;
                stamp = builtins.replaceStrings [ "/" ] [ "%" ] targetPath;
              in
              ''
                if ! _vf_fresh ${stamp} "${buildFile} ${buildRustfmtFile}" ${targetPath}; then
                  cp -f ${buildFile} ${targetPath}
                  chmod 644 ${targetPath}
                  rustfmt --config-path ${buildRustfmtFile} ${targetPath} && _vf_stamp ${stamp} "${buildFile} ${buildRustfmtFile}" ${targetPath}
                fi
              '')
            workspaceDirs)
      else "";

    patchAwk = builtins.readFile ./cargo-patch.awk;
    patchAwkKey = builtins.hashString "sha256" patchAwk;
    cargoConfigHook = ''
      if [ -e .git ]; then
        _vf_attrs=''${_vf_gitconfig%config}info/attributes
        if ! _vf_fresh cargo-patch-filter "${patchAwkKey}" "$_vf_gitconfig" "$_vf_attrs"; then
          git config filter.vf-cargo-patch.clean ${pkgs.lib.escapeShellArg "awk ${pkgs.lib.escapeShellArg patchAwk}"} # inlined: a store path gets GCd, and a missing filter commits the patch
          [[ -f $_vf_attrs && $(<"$_vf_attrs") == *'/.cargo/config.toml filter=vf-cargo-patch'* ]] || { mkdir -p "''${_vf_attrs%/attributes}" && echo '/.cargo/config.toml filter=vf-cargo-patch' >> "$_vf_attrs"; }
          _vf_stamp cargo-patch-filter "${patchAwkKey}" "$_vf_gitconfig" "$_vf_attrs"
        fi
        _vf_exclude=''${_vf_gitconfig%config}info/exclude
        grep -qxF /.cargo/local.toml "$_vf_exclude" 2>/dev/null || { mkdir -p "''${_vf_exclude%/exclude}" && echo /.cargo/local.toml >> "$_vf_exclude"; }
        unset _vf_attrs _vf_exclude
      fi
      if ! _vf_fresh cargo-config "${configFile} ${./cargo-config-merge.rs}" ./.cargo/config.toml; then
        _vf_owned=("$_vf_stamps/cargo-config.owned") # what we last generated, so keys dropped from it get retracted
        [ -f "$_vf_owned" ] || _vf_owned=()
        cargo -Zscript -q ${./cargo-config-merge.rs} ./.cargo/config.toml ${configFile} "''${_vf_owned[@]}" &&
          cp -f ${configFile} "$_vf_stamps/cargo-config.owned" &&
          { [ ! -e .git ] || ! git ls-files --error-unmatch -- .cargo/config.toml >/dev/null 2>&1 || ! git diff --quiet -- .cargo/config.toml || git add -- .cargo/config.toml; } && # re-records the stat: git calls a file whose size differs from the index modified without running the filter
          _vf_stamp cargo-config "${configFile} ${./cargo-config-merge.rs}" ./.cargo/config.toml
        unset _vf_owned
      fi
    '';

    denyEnabled = if builtins.isBool deny then deny else deny != { };
    denyHook =
      if denyEnabled then ''
        _vf_cp ${denyFile} ${inRoot "deny.toml"}
      '' else "";

    # Normalize style config
    styleFormat = style.format or true;
    styleAssert = style.check or false;
    styleEnabled = styleFormat || styleAssert;

    binstallHook = ''
      export PATH="$PATH:$HOME/.cargo/bin"
    '' + (if tracey then utils.binstallOnEntry { name = "tracey"; } else "");

    # codestyle is installed lazily at pre-commit time, not at shell entry.
    codestyleLazyInstall = if styleEnabled then utils.binstallCrate { name = "codestyle"; } else "";
  in
  {
    cargoRoot = cargoRootNormalized;
    # a particle's `ciCache`, for one that runs cargo in the repo's target dir. A save rolls the restored entry forward, so it drops
    # the units this run's cargo didn't look at: every build reads the fingerprint of each unit in its graph.
    ciCache =
      let target = inRoot "target"; in
      {
        paths = [ target "~/.cargo/registry/index" "~/.cargo/registry/cache" "~/.cargo/git/db" ];
        hashFiles = [ (inRoot "Cargo.lock") ];
        # under relatime a read updates atime only while it's older than mtime or ctime
        stamp = "[ ! -d ${target} ] || find ${target} -type f -exec touch -a -d @1 {} +";
        sweep = ''
          [ -d ${target} ] || exit 0
          probe=$(mktemp -p ${target}) && echo x > "$probe" && touch -a -d @1 "$probe" && cat "$probe" > /dev/null
          [ "$(stat -c %X "$probe")" != 1 ] || { echo "::error::a read doesn't update atime here: the sweep can't tell the units this run used"; exit 1; }
          rm "$probe"
          used=0 dropped=0
          for fp in ${target}/*/.fingerprint/*/ ${target}/*/*/.fingerprint/*/; do
            [ -d "$fp" ] || continue
            if [ -n "$(find "$fp" -type f -newerat @2 -print -quit)" ]; then used=$((used + 1)); continue; fi
            unit=''${fp%/}; hash=''${unit##*-}; dir=''${unit%/.fingerprint/*}
            rm -rf "$fp" "$dir"/build/*-"$hash" "$dir"/deps/*-"$hash" "$dir"/deps/*-"$hash".* "$dir"/examples/*-"$hash" "$dir"/examples/*-"$hash".*
            dropped=$((dropped + 1))
          done
          echo "cargo units kept: $used, dropped: $dropped"
        '';
      };
    # a CI job's mkShell that builds and runs the code, never develops it: none of the dev tools nor the hook's generated files
    ciShell =
      let system = pkgs.stdenv.hostPlatform.system; in
      assert rust.outPath == (import ./default_nightly.nix system).outPath || throw "v_flakes.rs.ciShell: its toolchain is the canonical nightly's, the shell's `rust` is another";
      {
        packages = [ (import ./ci_nightly.nix system) ];
        shellHook = if cranelift then "export RUSTC_WORKSPACE_WRAPPER=${craneliftWrapper}" else "";
      };
    inherit rust rustfmtFile configFile denyFile clippyFile sortDerivesFile lintsFile styleFormat styleAssert moduleFlags codestyleLazyInstall webUnstable;

    # For backwards compatibility, expose the first build file
    buildFile = makeBuildFile (workspace.${builtins.head workspaceDirs});

    shellHook = utils.mkShellHook ''
      # Prepend nix rust to PATH FIRST so every cargo/rustfmt invocation below
      # (lintsHook → cargo -Zscript, buildHook → rustfmt, binstallHook → cargo
      # install) resolves to the nix toolchain instead of a (possibly broken)
      # rustup shim in ~/.cargo/bin. Also critical for trybuild tests which
      # spawn cargo subprocesses.
      export PATH="${rust}/bin:$PATH"
      ${if pkgs.stdenv.hostPlatform.isDarwin then ''
      # rust-lld and proc-macro linking look for libLLVM.dylib in bin/../lib; a fallback var leaves Nix's clang alone
      export DYLD_FALLBACK_LIBRARY_PATH="${rust}/lib''${DYLD_FALLBACK_LIBRARY_PATH:+:$DYLD_FALLBACK_LIBRARY_PATH}"
      '' else ""}[ -d ./.cargo ] || mkdir -p ./.cargo
      _vf_cp ${rustfmtFile} ./rustfmt.toml
      ${cargoConfigHook}
      _vf_cp ${clippyFile} ./.cargo/clippy.toml
      _vf_cp ${sortDerivesFile} ${inRoot ".sort-derives.toml"}
      ${lintsHook}
      ${pinsHook}
      ${buildHook}
      ${denyHook}
      ${binstallHook}
      ${if cranelift then ''export RUSTC_WORKSPACE_WRAPPER=${craneliftWrapper} # env, not config: a nix sandbox build reads the committed config.toml'' else ""}
      ${if kache then ''
        # the machine's kache, which runs the daemon: a devshell pinning its own splits versions on every kache bump until each repo's lock follows
        if _vf_kache=$(command -v kache)${if kachePkg != null then " || { _vf_kache=${kachePkg}/bin/kache && export PATH=\"${kachePkg}/bin:$PATH\"; }" else ""}; then
          # only the cargo shim: kache's cc/gcc ones would sit in front of nix's cc-wrapper. The marker makes kache skip this dir when looking for the real cargo
          _vf_shim=$_vf_stamps/kache-shim
          if ! [ "$_vf_shim/cargo" -ef "$_vf_kache" ]; then
            mkdir -p "$_vf_shim" && ln -sfn "$_vf_kache" "$_vf_shim/cargo" && : > "$_vf_shim/.kache-shims"
          fi
          export PATH="$_vf_shim:$PATH" # last, so the hook's own `cargo -Zscript` runs skip it
          # own bins and test binaries change on every edit: 9% reuse, yet each miss copies ~80 MB into the store
          _vf_local=$(printf '[build]\nrustc-wrapper = "%s"\n\n[env]\nKACHE_CACHE_EXECUTABLES = "false"' "$_vf_kache")
          unset _vf_shim
        else
          _vf_local=$(printf '[build]\nrustc-wrapper = "%s"' "$(command -v sccache)")
        fi
        unset _vf_kache
      '' else ''
        _vf_local=$(printf '[build]\nrustc-wrapper = ""') # also turns off a global wrapper
      ''}
      [ "$(cat ./.cargo/local.toml 2>/dev/null)" = "$_vf_local" ] || printf '%s\n' "$_vf_local" > ./.cargo/local.toml
      unset _vf_local
    '';

    # cargo-binstall for tracey and codestyle
    enabledPackages = [ pkgs.cargo-binstall diet pkgs.cargo-release ((import ./cpublish.nix) pkgs diet cargoRootNormalized) ];
    traceyCheck = tracey;
  }
