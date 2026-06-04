{ pkgs, pname, semverChecks ? false, traceyCheck ? false, styleFormat ? true, styleAssert ? false, moduleFlags ? "",
  # Lazy install hook for codestyle - runs at pre-commit time instead of shell entry
  codestyleLazyInstall ? "",
  # List of directory paths (relative to repo root) to exclude from sort-derives and codestyle, e.g. ["libs/nautilus_trader"]
  excludeDirs ? [],
  # Run `pnpm test:visual` (playwright) in the hook. Driven by the js module's
  # `preCommit.visual`. Runs outside the Cargo.toml guard — it is not rust-gated.
  jsVisual ? false,
  # backwards compat
  styleCheck ? null,
}:
let
  # Handle backwards compat: if styleCheck is explicitly passed, use it for both
  actualStyleFormat = if styleCheck != null then styleCheck else styleFormat;
  actualStyleAssert = if styleCheck != null then false else styleAssert;

  semverChecksCmd = if semverChecks then "cargo semver-checks" else "";
  # Visual regression hook. Located by the package.json that actually declares a
  # `test:visual` script (root or ./frontend), so it works for both flat and
  # frontend-subdir layouts without a project-specific path. Snapshot diffs the
  # run produces are re-staged, mirroring the rust hooks' staged-only contract.
  jsVisualCmd = if jsVisual then ''
    visual_dir=""
    for d in . frontend; do
      if [ -f "$d/package.json" ] && grep -q '"test:visual"' "$d/package.json"; then
        visual_dir="$d"; break
      fi
    done
    if [ -z "$visual_dir" ]; then
      echo "js.preCommit.visual: no package.json with a \"test:visual\" script found (looked in ./ and ./frontend)"
      exit 1
    fi
    echo "Running: pnpm test:visual ($visual_dir)"
    ( cd "$visual_dir" && pnpm test:visual )
    if [ $? -ne 0 ]; then
      echo "pnpm test:visual failed"
      exit 1
    fi
    git add -u
  '' else "";
  traceyCmd = if traceyCheck then ''
    if [ -f ".config/tracey/config.kdl" ]; then
      tracey --check
    fi
  '' else "";
  # Build codestyle command: --exclude flags go before the `rust` subcommand (top-level Cli arg)
  excludeFlags = builtins.concatStringsSep " " (map (d: "--exclude ${d}") excludeDirs);
  codestyleBase = "codestyle ${excludeFlags} rust ${moduleFlags}";

  # cargo sort-derives: exclude specified dirs by using find+xargs when excludeDirs is set
  # (sort-derives has no native --exclude flag)
  sortDerivesCmd = if excludeDirs == [] then "cargo sort-derives"
    else
      let notPaths = builtins.concatStringsSep " " (map (d: "-not -path './${d}/*'") excludeDirs);
      in "find . -name '*.rs' ${notPaths} -print0 | xargs -r -0 -I{} cargo sort-derives --path {}";

  codestyleDirCmd = action: mode:
    if mode == "or-true"   then "${codestyleBase} ${action} ./ || true"
    else if mode == "fail-fast" then ''
      ${codestyleBase} ${action} ./
      if [ $? -ne 0 ]; then
        echo "codestyle: unfixable violations found"
        exit 1
      fi
    ''
    else "${codestyleBase} ${action} ./";
  # Lazy install ensures codestyle is available before running (only installs if missing/outdated)
  lazyInstallPrefix = if codestyleLazyInstall != "" then codestyleLazyInstall else "";
  # If both format and assert are true: run format and error if it had unfixable issues
  # If only format: run format (auto-fix, don't error on unfixable)
  # If only assert: run assert (error on any violation)
  # Each branch includes lazyInstallPrefix to ensure codestyle is installed before use
  targetDesc = if excludeDirs == [] then "./" else "./ (excluding: ${builtins.concatStringsSep ", " excludeDirs})";
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
      patched_manifests=$(find . -name Cargo.toml -not -path './target/*' -print0 | xargs -r -0 grep -l '^\[patch\.crates-io\]' 2>/dev/null || true)
      if [ -n "$patched_manifests" ]; then
        echo "WARNING: [patch.crates-io] section present in:"
        echo "$patched_manifests" | sed 's|^\./||;s|^|	|'
      fi
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

    ${jsVisualCmd}

    rm commit >/dev/null 2>&1 # remove commit message text file if it exists
    echo "Ran custom pre-commit hooks"
  '';
in
pkgs.writeText "pre-commit-hook.sh" script
