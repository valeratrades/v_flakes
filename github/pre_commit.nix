{ pkgs, pname, semverChecks ? false, traceyCheck ? false, styleFormat ? true, styleAssert ? false, moduleFlags ? "",
  # Lazy install hook for codestyle - runs at pre-commit time instead of shell entry
  codestyleLazyInstall ? "",
  # List of directory paths (relative to repo root) to exclude from sort-derives and codestyle, e.g. ["libs/nautilus_trader"]
  excludeDirs ? [],
  # backwards compat
  styleCheck ? null,
}:
let
  # Handle backwards compat: if styleCheck is explicitly passed, use it for both
  actualStyleFormat = if styleCheck != null then styleCheck else styleFormat;
  actualStyleAssert = if styleCheck != null then false else styleAssert;

  semverChecksCmd = if semverChecks then "cargo semver-checks" else "";
  traceyCmd = if traceyCheck then ''
    if [ -f ".config/tracey/config.kdl" ]; then
      tracey --check
    fi
  '' else "";
  # Build codestyle command with module flags
  # New interface: codestyle rust [--module=bool...] <format|assert> <path>
  codestyleBase = "codestyle rust ${moduleFlags}";

  # cargo sort-derives: exclude specified dirs by using find+xargs when excludeDirs is set
  sortDerivesCmd = if excludeDirs == [] then "cargo sort-derives"
    else
      let notPaths = builtins.concatStringsSep " " (map (d: "-not -path './${d}/*'") excludeDirs);
      in "find . -name '*.rs' ${notPaths} -print0 | xargs -r -0 -I{} cargo sort-derives --path {}";

  # codestyle target: when excludeDirs set, loop over top-level dirs skipping excluded ones.
  # exclTopLevel: space-separated top-level dir names extracted from each excludeDirs entry.
  # e.g. "libs/nautilus_trader" → "libs", "vendor" → "vendor"
  exclList = builtins.concatStringsSep " " (map (d:
    builtins.head (builtins.filter builtins.isString (builtins.split "/" d))
  ) excludeDirs);
  # Generates a bash for-loop over top-level dirs, skipping top-level components of excludeDirs.
  # `innerCmd` is substituted as the body (use $_csd for the current dir variable).
  codestyleDirLoop = innerCmd: ''
    for _csd in */; do
      _csd_skip=0
      for _csx in ${exclList}; do
        [ "''${_csd%/}" = "$_csx" ] && { _csd_skip=1; break; }
      done
      if [ "$_csd_skip" -eq 0 ] && [ -d "$_csd" ]; then
        ${innerCmd}
      fi
    done
  '';
  codestyleDirCmd = action: mode:  # mode: "or-true" | "fail-fast" | "strict"
    if excludeDirs == [] then
      (if mode == "or-true"   then "${codestyleBase} ${action} ./ || true"
       else if mode == "fail-fast" then ''
        ${codestyleBase} ${action} ./
        if [ $? -ne 0 ]; then
          echo "codestyle: unfixable violations found"
          exit 1
        fi
       ''
       else "${codestyleBase} ${action} ./")
    else
      (if mode == "or-true" then
        codestyleDirLoop "${codestyleBase} ${action} \"$_csd\" || true"
       else if mode == "fail-fast" then ''
        _cs_any_fail=0
        ${codestyleDirLoop "${codestyleBase} ${action} \"$_csd\" || _cs_any_fail=1"}
        if [ "$_cs_any_fail" -eq 1 ]; then
          echo "codestyle: unfixable violations found"
          exit 1
        fi
       ''
       else codestyleDirLoop "${codestyleBase} ${action} \"$_csd\"");
  # Lazy install ensures codestyle is available before running (only installs if missing/outdated)
  lazyInstallPrefix = if codestyleLazyInstall != "" then codestyleLazyInstall else "";
  # If both format and assert are true: run format and error if it had unfixable issues
  # If only format: run format (auto-fix, don't error on unfixable)
  # If only assert: run assert (error on any violation)
  # Each branch includes lazyInstallPrefix to ensure codestyle is installed before use
  targetDesc = if excludeDirs == [] then "./" else "per-dir (excluding: ${builtins.concatStringsSep ", " excludeDirs})";
  styleCmd = if actualStyleFormat && actualStyleAssert then ''
    ${lazyInstallPrefix}
    echo "Running: ${codestyleBase} format ${targetDesc}"
    ${codestyleDirCmd "format" "fail-fast"}
  '' else if actualStyleFormat then ''
    ${lazyInstallPrefix}
    echo "Running: ${codestyleBase} format ${targetDesc}"
    ${codestyleDirCmd "format" "or-true"}
  ''
  else if actualStyleAssert then ''
    ${lazyInstallPrefix}
    echo "Running: ${codestyleBase} assert ${targetDesc}"
    ${codestyleDirCmd "assert" "strict"}
  ''
  else "";
  script = ''
    config_filepath_nix="''${HOME}/.config/${pname}.nix"
    config_filepath_toml="''${HOME}/.config/${pname}.toml"
    config_dir="''${HOME}/.config/${pname}"

    # .nix takes priority over .toml
    if [ -f "$config_filepath_nix" ]; then
      echo "Copying project's nix config to examples/"
      mkdir -p ./examples
      cp -f "$config_filepath_nix" ./examples/config.nix
      git add examples/

      if [ $? -ne 0 ]; then
        echo "Failed to copy project's nix config to examples"
        exit 1
      fi
    elif [ -f "$config_filepath_toml" ] || [ -d "$config_dir" ]; then
      echo "Copying project's toml config to examples/"
      mkdir -p ./examples

      if [ -f "$config_filepath_toml" ]; then
        cp -f "$config_filepath_toml" ./examples/config.toml
      else
        [ -d ./examples/config ] || cp -r "$config_dir" ./examples/config
      fi

      git add examples/

      if [ $? -ne 0 ]; then
        echo "Failed to copy project's toml config to examples"
        exit 1
      fi
    fi

    if [ -f "Cargo.toml" ]; then
      staged_files=$(git diff --name-only --cached --diff-filter=ACMR)
      cargo_sort_out=$(cargo sort --workspace --grouped 2>&1)
      cargo_sort_rewritten=$(echo "$cargo_sort_out" | grep -oP 'Cargo\.toml for "?\K[^" ]+(?="? has been rewritten)')
      if [ -n "$cargo_sort_rewritten" ]; then
        echo "# cargo-sorted:"
        echo "$cargo_sort_rewritten" | while IFS= read -r name; do
          echo "	rewrote Cargo.toml for \"$name\""
        done
      fi
      ${sortDerivesCmd}
      if grep -q '^\[workspace\]' Cargo.toml; then cargo autoinherit; fi
      # idea is: if all these functions are ran on every commit, then the only files impacted will be those with changes yet to be committed; hence if tool affects something outside of staged, it was outside of the scope meant to be committed anyways.
      echo "$staged_files" | xargs -r git add
      ${semverChecksCmd}
      ${traceyCmd}
      ${styleCmd}
    fi

    rm commit >/dev/null 2>&1 # remove commit message text file if it exists
    echo "Ran custom pre-commit hooks"
  '';
in
pkgs.writeText "pre-commit-hook.sh" script
