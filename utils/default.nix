let
  core = import ./core.nix;

  # Wrap a raw shellHook string into the opaque form expected by `combine`.
  # All v_flakes producer modules expose `shellHook` via this helper rather
  # than as a plain string. That way `pkgs.mkShell { shellHook = mod.shellHook; }`
  # fails with a Nix "cannot coerce attrset to string" error, forcing the
  # consumer to route through `combine` (which installs the repo-root guard).
  mkShellHook = raw:
    if !(builtins.isString raw)
    then throw "v_flakes.utils.mkShellHook: expected a string, got ${builtins.typeOf raw}"
    else { __vFlakesHook = raw; };

  # Unwrap an opaque shellHook back to a raw string. Throws if the value
  # was not produced via `mkShellHook` — that catches consumers passing
  # plain strings into `combine` (which would silently bypass the guard).
  unwrapShellHook = h:
    if builtins.isAttrs h && h ? __vFlakesHook then h.__vFlakesHook
    else throw ''
      v_flakes: shellHook must be constructed via utils.mkShellHook.
      Got: ${if builtins.isString h
             then "a plain string (use `utils.mkShellHook \"...\"` to wrap it)"
             else builtins.typeOf h}
    '';

  # Helper to allow both `default` and `defaults` as aliases for the same attribute.
  # When one is provided, both are set to the same value. When neither is provided, neither is set
  # (allowing downstream `or` fallbacks to work correctly).
  # Usage: let cfg = optionalDefaults args; in cfg.default or someDefault
  optionalDefaults = args:
    let
      hasDefault = args ? default;
      hasDefaults = args ? defaults;
      # Only add default/defaults if at least one was explicitly provided
      value = if hasDefault then args.default else args.defaults;
    in
    if hasDefault || hasDefaults
    then args // { default = value; defaults = value; }
    else args;

  maskSecret = s: isSecret:
    if !isSecret then s else
    let len = builtins.stringLength s;
    in if len < 8 then "[REDACTED]"
       else (builtins.substring 0 2 s) + "..." + (builtins.substring (len - 2) 2 s);

  maskSh = ''
    _mask() {
      val="$1"; secret="$2"
      if [ "$secret" = "true" ]; then
        if [ ''\${#val} -lt 8 ]; then
          printf "[REDACTED]"
        else
          printf "%s..%s" "''\${val:0:2}" "''\${val: -2}"
        fi
      else
        printf "%s" "$val"
      fi
    }
  '';

  # Emit a shell snippet that runs `body` with a `_v_flakes_cargo` shell function
  # bound to whichever cargo we can find — preferring a working `cargo` on PATH
  # (i.e. the nix-provided toolchain when `rs` is included in combine), and
  # only falling back to a *global rustup* invocation if there is no working
  # cargo on PATH. The fallback is loud (prints a warning naming `caller` and
  # nudging the user to add `rs` to utils.combine). If neither is available,
  # we hard-error rather than silently skip the hook.
  #
  # The `cargo --version` (and `rustup run nightly cargo --version`) probe is
  # there to catch the case where a rustup shim exists on PATH but dispatches
  # to a broken toolchain (e.g. its patchelf'd ELF interpreter is a nix-store
  # glibc that got GC'd) — `command -v` succeeds for that shim but the shim
  # itself fails. We want that to be treated as "no working cargo".
  #
  # Usage:
  #   ${withCargo { caller = "py"; body = ''
  #     _v_flakes_cargo -Zscript -q ${./pyproject_merge.rs} ./pyproject.toml ${a} ${b}
  #   ''; }}
  withCargo = { caller, body }: ''
    if command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1; then
      _v_flakes_cargo() { command cargo "$@"; }
    elif command -v rustup >/dev/null 2>&1 && rustup run nightly cargo --version >/dev/null 2>&1; then
      echo "warning: v_flakes ${caller}: no working nix cargo on PATH — falling back to 'rustup run nightly cargo'. Add 'rs' to utils.combine to silence." >&2
      _v_flakes_cargo() { rustup run nightly cargo "$@"; }
    else
      echo "error: v_flakes ${caller}: needs cargo on PATH (add 'rs' to utils.combine, or install rustup with the nightly toolchain)." >&2
      exit 1
    fi
    ${body}
    unset -f _v_flakes_cargo
  '';

  # Generate shell command to check if a crate is outdated and auto-bump
  # Uses crates.io API to get latest version, with proper semver comparison
  # If outdated and bumpScript is provided, runs the script to update
  #
  # Parameters:
  #   name: crate name on crates.io
  #   currentVersion: current version string (X.Y.Z)
  #   bumpScript: path to bump_crate.rs script (optional)
  #   mode: "binstall" or "source" (default: "binstall")
  #   versionVarPostfix: postfix for version variable name (default: "Version")
  checkCrateVersion = { name, currentVersion, bumpScript ? null, mode ? "binstall", versionVarPostfix ? "Version" }: ''
    _check_crate_${builtins.replaceStrings ["-"] ["_"] name}() {
      local latest
      latest=$(curl -sf "https://crates.io/api/v1/crates/${name}" 2>/dev/null | \
        grep -o '"newest_version":"[^"]*"' | head -1 | cut -d'"' -f4)
      if [ -n "$latest" ]; then
        # Parse semver components (handles X.Y.Z, ignores pre-release suffixes)
        IFS='.-' read -r cur_major cur_minor cur_patch _ <<< "${currentVersion}"
        IFS='.-' read -r lat_major lat_minor lat_patch _ <<< "$latest"
        # Compare: latest > current means outdated
        if [ "$lat_major" -gt "$cur_major" ] 2>/dev/null || \
           ([ "$lat_major" -eq "$cur_major" ] && [ "$lat_minor" -gt "$cur_minor" ]) 2>/dev/null || \
           ([ "$lat_major" -eq "$cur_major" ] && [ "$lat_minor" -eq "$cur_minor" ] && [ "$lat_patch" -gt "$cur_patch" ]) 2>/dev/null; then
          echo "⚠️  ${name} ${currentVersion} is outdated (latest: $latest), bumping..."
          ${if bumpScript != null then ''
          if yes | ${bumpScript} --crate "${name}:${mode}" --version-var-postfix "${versionVarPostfix}"; then
            echo "✅ ${name} bumped to $latest. Please restart shell and commit changes."
          else
            echo "❌ Failed to bump ${name}"
          fi
          '' else ''
          echo "   No bump script configured"
          ''}
        fi
      fi
    }
    _check_crate_${builtins.replaceStrings ["-"] ["_"] name}
  '';
in
{
  setDefaultEnv = { name, default, is_secret ? false }:
    let
      maskedDefault = maskSecret default is_secret;
      secretFlag = if is_secret then "true" else "false";
    in
    ''
      ${maskSh}
      if [ -z "''\${${name}}" ]; then
        export ${name}="${default}"
        echo "⚠️  [WARN] Default used for ${name} = ${maskedDefault}"
      else
        __val="''\${${name}}"
        __disp="$(_mask "$__val" "${secretFlag}")"
        echo "ℹ️  [INFO] ${name} is set: ''\${__disp}"
      fi
    '';

  requireEnv = { name, is_secret ? false }:
    let
      secretFlag = if is_secret then "true" else "false";
    in
    ''
      ${maskSh}
      if [ -z "''\${${name}}" ]; then
        echo "❌ [ERROR] Required env ${name} is missing"
        exit 1
      else
        __val="''\${${name}}"
        __disp="$(_mask "$__val" "${secretFlag}")"
        echo "✅ [OK] Required env ${name} is present: ''\${__disp}"
      fi
    '';

  # GitHub Actions step asserting a repo/org secret is present before it gets used.
  # GitHub substitutes a missing secret with the empty string and would otherwise
  # fail deep inside whatever consumes it — this surfaces it loud and early.
  # The secret is injected as an env var (kept off the command line, masked in logs);
  # `hint` lines are appended as extra `::error::` annotations for setup guidance.
  # A private repo on a Free-plan org can't see org secrets, so an empty value there
  # most likely means "set org-wide but unreachable" rather than "never set" — the
  # message branches on github.event.repository.private to say which.
  requireSecret = { name, hint ? [] }: {
    name = "Ensure ${name} secret is configured";
    env = { ${name} = "\${{ secrets.${name} }}"; };
    run = builtins.concatStringsSep "\n" ([
      "if [ -z \"\${${name}}\" ]; then"
      "  echo \"::error::Secret '${name}' is not set (empty in this job).\""
      "  if [ \"\${{ github.event.repository.private }}\" = \"true\" ]; then"
      "    echo \"::error::This repo is PRIVATE. On GitHub Free-plan orgs, organization secrets are NOT exposed to private repos — if '${name}' is set org-wide it still won't reach here. Fix: set it repo-level (gh secret set ${name} -R \${{ github.repository }}), or upgrade the org to Team/Enterprise.\""
      "  else"
      "    echo \"::error::Add it under Settings → Secrets and variables → Actions (repo-level, or org-level with 'All repositories' visibility — org secrets reach public repos on any plan).\""
      "  fi"
    ] ++ (map (l: "  echo \"::error::${l}\"") hint) ++ [
      "  exit 1"
      "fi"
    ]) + "\n";
  };

  # Default GitHub Actions `on` triggers for standard CI workflows.
  # Fires on every push, every PR, and allows manual dispatch.
  # Override per-section via jobs.errors.hooks = { ... } in github/default.nix.
  defaultHooks = {
    push = { };
    pull_request = { };
  };

  inherit checkCrateVersion optionalDefaults mkShellHook unwrapShellHook withCargo;
  inherit (core) mergeConfig;

  # Combine multiple v-utils modules into a single shell configuration
  # Extracts enabledPackages and shellHook from each module and combines them
  #
  # Usage:
  #   combined = v-utils.utils.combine { inherit rust; modules = [ rs github readme ]; };
  #   devShells.default = pkgs.mkShell {
  #     packages = combined.enabledPackages;
  #     shellHook = combined.shellHook;
  #   };
  #
  # `rust` is the nix rust toolchain package (e.g. `rs.rust`) and is REQUIRED:
  # combine prepends `${rust}/bin` to PATH before any module hook runs, so every
  # module is guaranteed a working cargo for the custom rust scripts its hook
  # invokes (append_custom.rs, pyproject_merge.rs, code-duplication, …). No
  # rustup fallback, no `rust != null` gates downstream — provision it or fail.
  #
  # Each module should have optional `enabledPackages` (list) and `shellHook` (string) attributes.
  # Missing attributes are treated as empty.
  #
  # The combined shellHook is wrapped in a guard that aborts (exit 1) whenever
  # the shell is not anchored at the git repo root:
  #   - no git repository — module hooks write files via relative paths, so a
  #     missing repo means we have no anchor and risk dumping files in arbitrary
  #     locations.
  #   - CWD is not the git repo root (e.g. `nix develop ..` from inside a
  #     subdirectory) — otherwise generated `.github/`, `.gitignore`,
  #     `.gitattributes`, etc. would pollute that subdirectory.
  #
  # The abort is `exit 1`, not a mere skip of our own hooks. A `nix develop`
  # shellHook is *sourced* into the bash that drives the dev shell (this is why
  # the no-git `exit 1` already tears the whole thing down), so exiting here
  # hijacks and aborts the ENTIRE enclosing flake.nix shellHook — including
  # whatever the consumer concatenated around `${combined.shellHook}`. That is
  # the intended blast radius: if we cannot trust the anchor, nothing should
  # run, not just the parts we own. We still print a warning explaining why.
  # determinate_nix (default true): abort the dev shell unless the evaluating nix
  # has lazy-trees on (i.e. Determinate Nix). Stock nix produces flake.lock NAR
  # hashes that diverge from CI, so private git inputs fail to verify. There is no
  # eval-time way to detect Determinate (nixVersion is identical, settings aren't
  # readable from eval), so the check lives here in the sourced shellHook.
  combine = { rust, modules, determinate_nix ? true }:
    assert (rust != null) || throw "v_flakes.utils.combine: `rust` is required — pass the nix rust toolchain (e.g. `rs.rust`) so module hooks have a guaranteed cargo on PATH.";
    let
      determinateGuard = if !determinate_nix then "" else ''
        if [ "$(nix config show lazy-trees 2>/dev/null)" != true ]; then
          printf '%s\n' \
            "✘ This repo requires Determinate Nix (lazy-trees=true)." \
            "  Stock nix produces flake.lock NAR hashes that diverge from CI — private inputs fail to verify." \
            "  Install: https://determinate.systems/nix   NixOS: nix.settings.lazy-trees = true" >&2
          exit 1
        fi
      '';
      getPackages = m: m.enabledPackages or [];
      # Each module's shellHook is opaque (built via mkShellHook). unwrap throws
      # if a plain string slipped in — that's a programmer error we want loud.
      getHook = m: if m ? shellHook then unwrapShellHook m.shellHook else "";
      combinedHooks = builtins.concatStringsSep "\n" (builtins.filter (h: h != "") (map getHook modules));

      # Advisory: flag heavyweight duplicated flake inputs (e.g. several nixpkgs revs pulled in because sub-inputs don't `follows` the root nixpkgs). Each
      # redundant copy is eval-only, so GC reaps it and the next full eval
      # re-fetches hundreds of MB. `--offline` guarantees the check itself never fetches
      max_duplication_mb = 20;
      dedupeCheck = ''
        if command -v jq >/dev/null 2>&1; then
          _vf_dups="$(nix flake archive --json --offline 2>/dev/null | jq -r '
            def walk: .inputs // {} | to_entries[] | [.key, (.value.path // null)], (.value | walk);
            [walk] | map(select(.[1] != null)) | group_by(.[0])
            | map(select((map(.[1]) | unique | length) > 1))
            | .[] | .[0][0] as $n | (map(.[1]) | unique)[] | "\($n)\t\(.)"' 2>/dev/null)"
          if [ -n "$_vf_dups" ]; then
            _vf_over="$(printf '%s\n' "$_vf_dups" | while IFS=$'\t' read -r _n _p; do
              printf '%s\t%s\n' "$_n" "$(du -sm "$_p" 2>/dev/null | cut -f1)"
            done | awk -F'\t' '
              { tot[$1] += $2; if ($2+0 > max[$1]) max[$1] = $2; cnt[$1]++ }
              END { for (n in tot) { w = tot[n] - max[n]; if (w > ${toString max_duplication_mb}) printf "%s\t%d\t%d\n", n, w, cnt[n] } }')"
            if [ -n "$_vf_over" ]; then
              echo "" >&2
              echo "⚠️  v_flakes: duplicate flake inputs — redundant copies re-fetched after every GC:" >&2
              printf '%s\n' "$_vf_over" | while IFS=$'\t' read -r _n _w _c; do
                echo "      • $_n — $_c copies, ~''${_w}MB wasted" >&2
              done
              echo "    Cause: sub-inputs pin their own nixpkgs instead of following the root." >&2
              echo "    Fix in flake.nix inputs, then run \`nix flake lock\`:" >&2
              echo "      <input>.inputs.nixpkgs.follows = \"nixpkgs\";" >&2
              echo "" >&2
            fi
          fi
        fi
      '';
    in
    {
      enabledPackages = builtins.concatLists (map getPackages modules);
      shellHook = ''
        _v_flakes_repo_root="$(git rev-parse --show-toplevel 2>/dev/null)" || {
          echo "error: v_flakes shellHook requires a git repository" >&2
          exit 1
        }
        if [ "$PWD" != "$_v_flakes_repo_root" ]; then
          echo "warning: v_flakes shellHook aborting entire flake.nix hook — CWD is not repo root ($PWD != $_v_flakes_repo_root)" >&2
          unset _v_flakes_repo_root
          exit 1
        fi
        unset _v_flakes_repo_root
        ${determinateGuard}
        # Guarantee cargo for the rust scripts module hooks invoke.
        export PATH="${rust}/bin:$PATH"
        ${combinedHooks}
        ${dedupeCheck}
      '';
    };
}
