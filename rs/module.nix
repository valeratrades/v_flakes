{ pkgs ? null
, nixpkgs ? null
, # config options
  cranelift ? true
, targets ? { }
, config ? { }
, deny ? false
, clippy ? { }
, sortDerives ? { }
, lints ? true
, tracey ? true
, style ? { }
, # build.rs options
  build ? { }
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
    dedups it and sccache cross-references compilations between repos. The pin lives
    in rs/default_nightly.nix and moves ONLY on at-least-minor v_flakes bumps.

    Usage:
    ```nix
    rs = v-utils.rs {
      inherit pkgs rust;  # rust is the nix toolchain package
      cranelift = true;  # Enable cranelift backend (default: true)
      deny = false;      # Copy deny.toml for cargo-deny (default: false)
      clippy = {};      # Extend .cargo/clippy.toml (default: base defaults, see files/rust/clippy.nix)
      sortDerives = {}; # Extend .sort-derives.toml (default: qualified_last, see files/rust/sort_derives.nix)
      lints = true;     # `false` disables Cargo.toml [lints.rust] (or [workspace.lints.rust]) management. Pass an attrset to extend defaults (default: { unused_features = "allow"; }). Use per-key `.replace`/`.augment`/`.exclude` modifiers from utils/core.nix.
      tracey = true;     # Enable tracey spec coverage (default: true)
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
        workspace = {           # Per-directory build.rs modules (default: { "./" = [ "git_version" "log_directives" ]; })
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
    - Copy cargo config to ./.cargo/config.toml
    - Copy clippy config to ./.cargo/clippy.toml
    - Merge controlled `[lints.rust]` (or `[workspace.lints.rust]` if `[workspace]` exists) into ./Cargo.toml
    - Copy build.rs to each directory in build.workspace (with write permissions for treefmt)
    - Copy deny.toml to ./deny.toml (if deny = true)

    enabledPackages includes:
    - `tracey` - spec coverage tool (if tracey = true)
    - `codestyle` - code style linter and formatter (if style.format or style.check is true)
    - `cargo-diet`, `cargo-release`, and `cpublish` — `cargo release --no-confirm --execute`,
      refusing to run while `cargo diet` still has include directives to rewrite. The check is a
      read (`cargo diet -n -r`); applying and committing the rewrite is yours.
  '';
} else

  assert pkgs.lib.assertMsg (rust != null)
    "rs module: `rust` toolchain package is required for the build/devshell path (only omittable when reading `.description` with just `nixpkgs`)";

  let
    files = import ../files;
    core = import ../utils/core.nix;
    utils = import ../utils;
    diet = (import ./diet.nix) pkgs.stdenv.hostPlatform.system;

    buildEnable = build.enable or true;
    workspace = build.workspace or { "./" = [ "git_version" "log_directives" ]; };

    # codestyle installed via binstall (same as tracey)
    # Building from source fails in nix sandbox due to TMPDIR issues during cargo build

    # Normalize directory path: ensure no trailing slash, then append /build.rs
    # Handles both "./" and "./cli" and "./cli/" correctly
    normalizePath = dir:
      let
        stripped = pkgs.lib.removeSuffix "/" dir;
      in
      if stripped == "." || stripped == "" then "./build.rs" else "${stripped}/build.rs";

    rustfmtFile = files.rust.rustfmt { inherit pkgs; };
    targetsExtend = if targets != { } then { target.augment = targets; } else { };
    configExtend = core.mergeConfig targetsExtend config;
    configFile = files.rust.config {
      inherit pkgs cranelift;
      extend = configExtend;
    };
    denyExtend = if builtins.isAttrs deny then deny else { };
    denyFile = files.rust.deny { inherit pkgs; extend = denyExtend; };
    clippyFile = files.rust.clippy { inherit pkgs; extend = clippy; };
    sortDerivesFile = files.rust.sort_derives { inherit pkgs; extend = sortDerives; };
    lintsExtend = if builtins.isAttrs lints then lints else { };
    lintsEnabled = if builtins.isBool lints then lints else true;
    lintsFile = files.rust.lints { inherit pkgs; extend = lintsExtend; };
    lintsHook =
      if lintsEnabled then ''
        if [ -f ./Cargo.toml ]; then
          cargo -Zscript -q ${./cargo-merge.rs} ./Cargo.toml ${lintsFile}
        fi
      '' else "";

    # Generate a build file for each workspace directory with its specific modules
    makeBuildFile = modules: files.rust.build { inherit pkgs modules; };

    # Generate install commands for each workspace directory
    workspaceDirs = builtins.attrNames workspace;
    buildRustfmtFile = ../files/rust/build/rustfmt.toml;
    buildHook =
      if buildEnable then
        builtins.concatStringsSep "\n"
          (map
            (dir:
              let
                buildFile = makeBuildFile workspace.${dir};
                targetPath = normalizePath dir;
              in
              ''
                cp -f ${buildFile} ${targetPath}
                chmod 644 ${targetPath}
                rustfmt --config-path ${buildRustfmtFile} ${targetPath}
              '')
            workspaceDirs)
      else "";

    denyEnabled = if builtins.isBool deny then deny else deny != { };
    denyHook =
      if denyEnabled then ''
        cp -f ${denyFile} ./deny.toml
      '' else "";

    # Normalize style config
    styleFormat = style.format or true;
    styleAssert = style.check or false;
    styleEnabled = styleFormat || styleAssert;

    binstallHook = ''
      export PATH="$PATH:$HOME/.cargo/bin"
    '' + (if tracey then utils.binstallCrate { name = "tracey"; } else "");

    # codestyle is installed lazily at pre-commit time, not at shell entry.
    codestyleLazyInstall = if styleEnabled then utils.binstallCrate { name = "codestyle"; } else "";
  in
  {
    inherit rust rustfmtFile configFile denyFile clippyFile sortDerivesFile lintsFile styleFormat styleAssert moduleFlags codestyleLazyInstall;

    # For backwards compatibility, expose the first build file
    buildFile = makeBuildFile (workspace.${builtins.head workspaceDirs});

    shellHook = utils.mkShellHook ''
      # Prepend nix rust to PATH FIRST so every cargo/rustfmt invocation below
      # (lintsHook → cargo -Zscript, buildHook → rustfmt, binstallHook → cargo
      # install) resolves to the nix toolchain instead of a (possibly broken)
      # rustup shim in ~/.cargo/bin. Also critical for trybuild tests which
      # spawn cargo subprocesses.
      export PATH="${rust}/bin:$PATH"
      mkdir -p ./.cargo
      cp -f ${rustfmtFile} ./rustfmt.toml
      cp -f ${configFile} ./.cargo/config.toml
      cp -f ${clippyFile} ./.cargo/clippy.toml
      cp -f ${sortDerivesFile} ./.sort-derives.toml
      ${lintsHook}
      ${buildHook}
      ${denyHook}
      ${binstallHook}
    '';

    # cargo-binstall for tracey and codestyle
    enabledPackages = [ pkgs.cargo-binstall diet pkgs.cargo-release ((import ./cpublish.nix) pkgs diet) ];
    traceyCheck = tracey;
  }
