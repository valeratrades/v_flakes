{
  pkgs ? null,
  nixpkgs ? null,
  # config options
  cranelift ? true,
  targets ? {},
  config ? {},
  deny ? false,
  clippy ? {},
  lints ? true,
  tracey ? true,
  style ? {},
  # build.rs options
  build ? {},
  # rust toolchain package - required to prepend to PATH so nix rust takes precedence over rustup
  rust,
}:
# Normalize style.modules: { instrument = true; loops = false; } -> "--instrument=true --loops=false"
# Accepts both booleans and strings as values
let
  styleModules = style.modules or {};
  # Convert value to string, handling both bool and string inputs
  valueToString = value:
    if builtins.isBool value then (if value then "true" else "false")
    else builtins.toString value;
  moduleFlags = builtins.concatStringsSep " " (
    builtins.attrValues (builtins.mapAttrs (name: value:
      "--${builtins.replaceStrings ["_"] ["-"] name}=${valueToString value}"
    ) styleModules)
  );
in
# If called with just nixpkgs (for flake description), return description attribute
if nixpkgs != null && pkgs == null then {
  description = ''
Rust project configuration module combining rustfmt, cargo config, and build.rs.

Usage:
```nix
rs = v-utils.rs {
  inherit pkgs rust;  # rust is the nix toolchain package
  cranelift = true;  # Enable cranelift backend (default: true)
  deny = false;      # Copy deny.toml for cargo-deny (default: false)
  clippy = {};      # Extend .cargo/clippy.toml (default: base defaults, see files/rust/clippy.nix)
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
'';
} else

let
  files = import ../files;
  core = import ../utils/core.nix;

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
  targetsExtend = if targets != {} then { target.augment = targets; } else {};
  configExtend = core.mergeConfig targetsExtend config;
  configFile = files.rust.config {
    inherit pkgs cranelift;
    extend = configExtend;
  };
  denyExtend = if builtins.isAttrs deny then deny else {};
  denyFile = files.rust.deny { inherit pkgs; extend = denyExtend; };
  clippyFile = files.rust.clippy { inherit pkgs; extend = clippy; };
  lintsExtend = if builtins.isAttrs lints then lints else {};
  lintsEnabled = if builtins.isBool lints then lints else true;
  lintsFile = files.rust.lints { inherit pkgs; extend = lintsExtend; };
  lintsHook = if lintsEnabled then ''
    if [ -f ./Cargo.toml ]; then
      cargo -Zscript -q ${./cargo_merge.rs} ./Cargo.toml ${lintsFile}
    fi
  '' else "";

  # Generate a build file for each workspace directory with its specific modules
  makeBuildFile = modules: files.rust.build { inherit pkgs modules; };

  # Generate install commands for each workspace directory
  workspaceDirs = builtins.attrNames workspace;
  buildRustfmtFile = ../files/rust/build/rustfmt.toml;
  buildHook = if buildEnable then
    builtins.concatStringsSep "\n" (map (dir:
      let
        buildFile = makeBuildFile workspace.${dir};
        targetPath = normalizePath dir;
      in ''
      cp -f ${buildFile} ${targetPath}
      chmod 644 ${targetPath}
      rustfmt --config-path ${buildRustfmtFile} ${targetPath}
    '') workspaceDirs)
  else "";

  denyEnabled = if builtins.isBool deny then deny else deny != {};
  denyHook = if denyEnabled then ''
    cp -f ${denyFile} ./deny.toml
  '' else "";

  # Normalize style config
  styleFormat = style.format or true;
  styleAssert = style.check or false;
  styleEnabled = styleFormat || styleAssert;

  # binstall hook - installs/upgrades tracey via cargo-binstall at shell entry
  # Uses ~/.cargo/bin as install location
  # Queries crates.io for the latest version, installs if different from local
  # Note: codestyle is installed lazily at pre-commit time, not here
  latestCrateVersion = name: ''
    curl -sf "https://crates.io/api/v1/crates/${name}" 2>/dev/null | grep -o '"newest_version":"[^"]*"' | head -1 | cut -d'"' -f4
  '';
  vFlakesVersion = (builtins.fromTOML (builtins.readFile ../Cargo.toml)).package.version;

  #HACK: install expressions are not DRY (could move out binstallPinned, binstallExact; both using binstallCmd for exact expression (as it repeats exactly))
  binstallHook = ''
    export PATH="$HOME/.cargo/bin:$PATH"
  '' + (if tracey then ''
    _tracey_installed=$(cargo install --list 2>/dev/null | grep "^tracey v" | grep -oP '\d+\.\d+\.\d+' || echo "")
    _tracey_latest=$(${latestCrateVersion "tracey"})
    if [ -n "$_tracey_latest" ] && [ "$_tracey_installed" != "$_tracey_latest" ]; then
      echo "Installing tracey@$_tracey_latest..."
      cargo binstall "tracey@$_tracey_latest" --no-confirm -q 2>/dev/null || cargo install "tracey@$_tracey_latest" -q
    fi
  '' else "") + ''
    _v_flakes_installed=$(cargo install --list 2>/dev/null | grep "^v_flakes v" | grep -oP '\d+\.\d+\.\d+' || echo "")
    if [ "$_v_flakes_installed" != "${vFlakesVersion}" ]; then
      echo "Installing v_flakes@${vFlakesVersion}..."
      cargo binstall "v_flakes@${vFlakesVersion}" --no-confirm -q 2>/dev/null || cargo install "v_flakes@${vFlakesVersion}" -q
    fi
  '';

  # Lazy install hook for codestyle - called from pre-commit, not shell entry
  codestyleLazyInstall = if styleEnabled then ''
    _codestyle_installed=$(codestyle --version 2>/dev/null | grep -oP '\d+\.\d+\.\d+' | head -1 || echo "")
    _codestyle_latest=$(${latestCrateVersion "codestyle"})
    if [ -n "$_codestyle_latest" ] && [ "$_codestyle_installed" != "$_codestyle_latest" ]; then
      echo "Installing codestyle@$_codestyle_latest..."
      cargo binstall "codestyle@$_codestyle_latest" --no-confirm -q 2>/dev/null || cargo install "codestyle@$_codestyle_latest" -q
    fi
  '' else "";
in
{
  inherit rust rustfmtFile configFile denyFile clippyFile lintsFile styleFormat styleAssert moduleFlags codestyleLazyInstall;

  # For backwards compatibility, expose the first build file
  buildFile = makeBuildFile (workspace.${builtins.head workspaceDirs});

  shellHook = ''
    mkdir -p ./.cargo
    cp -f ${rustfmtFile} ./rustfmt.toml
    cp -f ${configFile} ./.cargo/config.toml
    cp -f ${clippyFile} ./.cargo/clippy.toml
    ${lintsHook}
    ${buildHook}
    ${denyHook}
    ${binstallHook}
    # Prepend nix rust to PATH so it takes precedence over rustup shims in ~/.cargo/bin.
    # This is critical for trybuild tests which spawn cargo subprocesses.
    # Must be AFTER binstallHook which also modifies PATH.
    export PATH="${rust}/bin:$PATH"
  '';

  # cargo-binstall for tracey and codestyle
  enabledPackages = [ pkgs.cargo-binstall ];
  traceyCheck = tracey;
}
