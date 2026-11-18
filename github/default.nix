args@{ pkgs ? null
, nixpkgs ? null
, pname ? null
, lastSupportedVersion ? null
, jobs ? { }
, gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb"
, langs ? null
, gitignore ? { }
, envrc ? { }
, lfs ? null
, labels ? { }
, preCommit ? { }
, conventions ? false
, # Pass language module outputs — langs is inferred from whichever are non-null
  # rs also provides the rust toolchain (rs.rust) — required when enable = true
  rs ? null
, py ? null
, tex ? null
, js ? null
, # Or override individually (these take precedence over rs)
  traceyCheck ? null
, style ? null
, styleFormat ? null
, styleAssert ? null
, moduleFlags ? null
, # Top-level install applies to all job sections (errors, warnings, other, release)
  # Per-section install overrides this.
  install ? { }
, # CI binary-cache mechanism for every nix-using workflow; modes and default in cache.nix
  cache ? { }
, # Cachix cache name to publish `packages.default` to on every push to main, so
  # downstream flakes substitute instead of rebuilding. Needs CACHIX_AUTH_TOKEN.
  # "<name>", or { name; systems = [ "x86_64-linux" "aarch64-darwin" ]; tags = true; } (`tags`: publish on `v*` tags, not main).
  publishCachix ? null
, release ? null
, containerRelease ? null
, # { scope; packagesDir; }: release-npm.yml, npm trusted publishing on `@<scope>/<pkg>-v*` tags
  npmRelease ? null
, # { dir; render; gate ? null; paths ? null; rustCache ? null; }: visual-baselines.yml, contract in description.md
  visualBaselines ? null
, # typ module with `main`: release-typst.yml, its document on release tags (+ GitHub Pages with `html`); contract in description.md
  typ ? null
, # { on = "gha" | "publish"; folder ? null; }: the repo's pages into a Figma folder, by figma.yml (release tag, `[figma]` comment) or by `publish`; contract in description.md
  figma ? null
, # { skargo ? <pins/skargo.nix rev>; }: skills.yml, `skargo check` / `publish` of a repo shipping agent skills
  skills ? null
, gitlabSync ? null
, syncFork ? false
, # Claude Code workflows (PR assistant + auto code review). On by default for enabled repos.
  claude ? true
, # Dirs to exclude from sort-derives and codestyle (e.g. vendored code or submodules), e.g. ["libs/nautilus_trader"]
  excludeDirs ? [ ]
, # Master switch: enables CI workflows, pre-commit hooks, gitignore, label sync, git_ops, etc.
  # When false (default), only explicitly requested standalone workflows (syncFork, gitlabSync, release) are generated.
  enable ? false
,
}:

# Warn when enable-gated fields are explicitly passed but enable is false
let
  enableGatedFields = [ "lastSupportedVersion" "jobs" "gitignore" "envrc" "lfs" "labels" "preCommit" "conventions" "release" "containerRelease" "npmRelease" "visualBaselines" "figma" "typ" "skills" "gitlabSync" "install" "traceyCheck" "style" "styleFormat" "styleAssert" "moduleFlags" "excludeDirs" "claude" ];
  presentGated = builtins.filter (f: args ? ${f}) enableGatedFields;
  warnIfNeeded = value:
    if (!enable && presentGated != [ ]) then
      builtins.trace "WARNING [v_flakes.github]: `enable` is false but the following fields were explicitly set and will have no effect: ${builtins.concatStringsSep ", " presentGated}" value
    else value;
in

# Priority: explicit params > rs module > defaults
let
  # Infer langs from which language modules are passed
  inferredLangs =
    (if rs != null then [ "rs" ] else [ ])
    ++ (if py != null then [ "py" ] else [ ])
    ++ (if tex != null then [ "tex" ] else [ ])
    ++ (if js != null then [ "js" ] else [ ]);
  #DEPRECATE: when everything has switched to new standard
  effectiveLangs =
    if langs != null then
      builtins.trace "DEPRECATED [v_flakes.github]: `langs` is deprecated. Pass language modules directly instead (e.g. `inherit rs py tex;`)" langs
    else inferredLangs;

  # the hook install's cargo is `combine`'s, which requires `rust`; this one is the rust particles'
  rust = if rs != null then (rs.rust or null) else null;

  # Extract from rs if provided
  rsTraceyCheck = if rs != null then (rs.traceyCheck or false) else false;
  rsStyleFormat = if rs != null then (rs.styleFormat or true) else true;
  rsStyleAssert = if rs != null then (rs.styleAssert or false) else false;
  rsModuleFlags = if rs != null then (rs.moduleFlags or "") else "";
  rsCodestyleLazyInstall = if rs != null then (rs.codestyleLazyInstall or "") else "";
  cargoRoot = if rs != null then (rs.cargoRoot or ".") else ".";
  webUnstable = if rs != null then (rs.webUnstable or false) else false;

  # Compute from style parameter if provided (for standalone usage without rs)
  styleModules = if style != null then (style.modules or { }) else { };
  valueToString = value:
    if builtins.isBool value then (if value then "true" else "false")
    else builtins.toString value;
  computedModuleFlags = builtins.concatStringsSep " " (
    builtins.attrValues (builtins.mapAttrs
      (name: value:
        "--${builtins.replaceStrings ["_"] ["-"] name}=${valueToString value}"
      )
      styleModules)
  );
  styleParamFormat = if style != null then (style.format or null) else null;
  styleParamAssert = if style != null then (style.check or null) else null;

  # Final values: explicit > style param > rs > defaults
  actualTraceyCheck = if traceyCheck != null then traceyCheck else rsTraceyCheck;
  actualStyleFormat =
    if styleFormat != null then styleFormat
    else if styleParamFormat != null then styleParamFormat
    else rsStyleFormat;
  actualStyleAssert =
    if styleAssert != null then styleAssert
    else if styleParamAssert != null then styleParamAssert
    else rsStyleAssert;
  actualModuleFlags =
    if moduleFlags != null then moduleFlags
    else if computedModuleFlags != "" then computedModuleFlags
    else rsModuleFlags;
in

# If called with just nixpkgs (for flake description), return description attribute
if nixpkgs != null && pkgs == null then {
  description = builtins.readFile ./description.md;
} else

  let
    utils = import ../utils;
    files = import ../files;

    # Default particles per language; a string names one of particles/catalog.nix
    defaultsByLang = {
      rs = {
        errors = [ "rust-tests" ];
        warnings = [ "rust-doc" "rust-clippy" "rust-machete" "rust-sorted" "rust-sorted-derives" "tokei" ]; #WAIT: until "rust-unused-features" finally gets --edition 2024 support
      };
      go = {
        errors = [ "go-tests" ];
        warnings = [ "go-gocritic" "go-security-audit" ];
      };
      py.errors = [ "py-tests" ];
      js = if js != null then js.particles else { };
    };
    sharedDefaults.warnings = [ "code-duplication" ]; #TEST: if code-duplication works for other languages
    sharedDefaults.other = [ "loc-badge" ];

    computeDefaultsForLangs = category:
      builtins.concatLists (map (lang: defaultsByLang.${lang}.${category} or [ ]) effectiveLangs)
      ++ (sharedDefaults.${category} or [ ]);

    # A section: { default? = bool; defaults? = bool; augment? = [...]; exclude? = [...]; } or just a list (legacy)
    processJobsSection = category: sectionConfig: topDefault:
      let
        sectionRaw = if builtins.isList sectionConfig then { augment = sectionConfig; } else sectionConfig;
        section = utils.optionalDefaults sectionRaw;
        baseJobs = if section.default or topDefault then computeDefaultsForLangs category else [ ];
        getJobName = spec: if builtins.isString spec then spec else spec.name;
        excludeJobs = section.exclude or [ ];
        unexcludable = builtins.filter (n: !(builtins.elem n (map getJobName baseJobs))) excludeJobs;
      in
      assert unexcludable == [ ] || throw "v_flakes.github: jobs.${category}.exclude names no default of it: ${toString unexcludable}";
      builtins.filter (job: !(builtins.elem (getJobName job) excludeJobs)) baseJobs ++ (section.augment or [ ]);

    # Get top-level default setting (accepts both `default` and `defaults`)
    jobsNormalized = utils.optionalDefaults jobs;
    topDefault = jobsNormalized.default or false;

    # Process each section
    jobsErrors = processJobsSection "errors" (jobs.errors or { }) topDefault;
    jobsWarnings = processJobsSection "warnings" (jobs.warnings or { }) topDefault;
    jobsOther = processJobsSection "other" (jobs.other or { }) topDefault;

    # Extract install config from each section, falling back to top-level install
    effectiveInstall = section:
      if builtins.isAttrs section && section ? install then section.install
      else install;
    installErrors = effectiveInstall (jobs.errors or { });
    installWarnings = effectiveInstall (jobs.warnings or { });
    installOther = effectiveInstall (jobs.other or { });

    # Extract hooks (on-triggers) from each section, null means use default
    effectiveHooks = section:
      if builtins.isAttrs section && section ? hooks then section.hooks
      else null;
    hooksErrors = effectiveHooks (jobs.errors or { });
    hooksWarnings = effectiveHooks (jobs.warnings or { });
    hooksOther = effectiveHooks (jobs.other or { });

    # sync_fork: can be set via jobs.sync_fork or top-level syncFork param
    effectiveSyncFork = syncFork || (jobs.sync_fork or false);

    # A section's `install.packages` are nixpkgs attribute paths its CI jobs get; v_flakes' own particles get them locally too
    catalogFor = installConfig: import ./particles/catalog.nix {
      inherit pkgs rust rs cargoRoot webUnstable lastSupportedVersion;
      runtimeInputs = map (n: pkgs.lib.getAttrFromPath (pkgs.lib.splitString "." n) pkgs) (installConfig.packages or [ ]);
    };
    particles = import ./particles {
      inherit pkgs;
      catalogs = { errors = catalogFor installErrors; warnings = catalogFor installWarnings; };
      sections = { errors = jobsErrors; warnings = jobsWarnings; };
    };

    figmaChecked =
      if figma == null then null
      else
        let unknown = builtins.removeAttrs figma [ "on" "folder" ]; in
        assert unknown == { } || throw "v_flakes figma: unknown keys ${builtins.toJSON (builtins.attrNames unknown)}";
        assert builtins.elem (figma.on or null) [ "gha" "publish" ] || throw "v_flakes figma: `on` is \"gha\" (figma.yml) or \"publish\" (github's `publish` app)";
        figma;
    figmaPublish = pkgs.writeShellApplication {
      name = "figma-publish";
      runtimeInputs = [ pkgs.git pkgs.gh pkgs.coreutils ];
      text = (if figma.folder or null != null then "FIGMA_FOLDER=${pkgs.lib.escapeShellArg figma.folder}\n" else ''
        FIGMA_FOLDER="$(gh variable get FIGMA_FOLDER --org "$(gh repo view --json owner -q .owner.login)")"
      '') + import ./workflows/nix-parts/shared/figma-render.nix;
    };

    workflows = import ./workflows/nix-parts ({
      inherit pkgs gistId cargoNightly cache publishCachix;
      syncFork = effectiveSyncFork;
    } // (if enable then {
      typstRelease = if typ == null then null else
        assert typ ? document || throw "v_flakes.github: `typ` is only taken for its document; set `main` on the typ module";
        { inherit (typ) html; };
      inherit pname lastSupportedVersion jobsOther release containerRelease npmRelease visualBaselines gitlabSync cargoRoot webUnstable;
      figma = figmaChecked;
      lfs = lfs == true;
      skills = if skills == null then null else { skargo = "github:EV-Main/skills/${import ../pins/skargo.nix}"; } // skills;
      rustRepo = rust != null;
      inherit installErrors installWarnings installOther;
      inherit hooksErrors hooksWarnings hooksOther;
      inherit claude;
      particlesErrors = particles.errors;
      particlesWarnings = particles.warnings;
    } else { }));

    # --- Everything below is only computed when `enable = true` ---

    # Process labels config (accepts both `default` and `defaults`)
    defaultLabels = import ./labels.nix;
    labelsConfigRaw = if builtins.isAttrs labels then labels else { extra = labels; };
    labelsConfig = utils.optionalDefaults labelsConfigRaw;
    labelsEnabled = enable && (labelsConfig.enable or true);
    useDefaults = labelsConfig.default or true;
    extraLabels = labelsConfig.extra or [ ];
    allLabels = (if useDefaults then defaultLabels else [ ]) ++ extraLabels;

    # These are interpolated directly into a bash script (no eval), so we just need to escape
    # single quotes for the bash 'literal string' context.
    escapeForBash = s: builtins.replaceStrings [ "'" ] [ "'\\''" ] s;
    syncArgs = "--labels-json '" + escapeForBash (builtins.toJSON allLabels) + "'" + pkgs.lib.optionalString (typ != null && typ.html) " --pages";

    # Use local cargo, falling back loudly to rustup's nightly if unavailable.
    # Unset RUSTC_WRAPPER: the backgrounded run must not depend on the wrapper's daemon outliving the shell.
    # NB: `cargo --version` probe catches the case where a rustup shim exists on
    # PATH but dispatches to a broken toolchain (e.g. patchelf'd ELF interpreter
    # GC'd). That should be treated as "no working cargo", not silently retried.
    cargoNightly = pkgs.writeShellScript "cargo-nightly" ''
      export RUSTC_WRAPPER=
      if command -v cargo >/dev/null 2>&1 && cargo --version >/dev/null 2>&1; then
        exec cargo "$@"
      elif command -v rustup >/dev/null 2>&1 && rustup run nightly cargo --version >/dev/null 2>&1; then
        echo "warning: v_flakes github (cargoNightly): no working nix cargo on PATH — falling back to 'rustup run nightly cargo'. Add 'rs' to utils.combine to silence." >&2
        exec rustup run nightly cargo "$@"
      else
        echo "error: v_flakes github (cargoNightly): needs cargo on PATH (add 'rs' to utils.combine, or install rustup with the nightly toolchain)." >&2
        exit 1
      fi
    '';

    git_ops = import ./git.nix { inherit pkgs syncArgs cargoNightly; gitOpsScript = ./git-ops.rs; };
    code_duplication = import ./code_duplication.nix { inherit pkgs cargoNightly; script = ./workflows/code-duplication.rs; };

    # Process preCommit config
    # can be very slow
    semverChecks = preCommit.semverChecks or false;


    # Convention files copied from github.com/<owner>/<owner> or github.com/<owner>/.github
    # on first rebuild for each v_flakes version. Expand this list to add more.
    conventionsFiles = [ "GIT_CONVENTION.md" ];
    # Version key: any change to the script or the file list re-pulls.
    # Tied to v_flakes via the on-disk contents of git-ops.rs (its store path
    # changes with every v_flakes revision that touches it).
    conventionsVersionKey = builtins.hashString "sha256" (
      (builtins.readFile ./git-ops.rs) + (builtins.toJSON conventionsFiles)
    );
    conventionsFileArgs = builtins.concatStringsSep " " (map (f: "--file ${f}") conventionsFiles);
    # The custom pre-commit hook is installed by a `cargo -Zscript`, so it costs a
    # toolchain — and what it runs is guarded by a Cargo.toml anyway. A language
    # module is what says one is owed; a repo that passes none (typst, docs) takes
    # the rest of the hook without it. Forced only through the `enable` branch.
    customSh = (import ../git/pre_commit.nix) { inherit pkgs pname cargoNightly semverChecks excludeDirs cargoRoot; gitOps = if labelsEnabled then git_ops else null; traceyCheck = actualTraceyCheck; styleFormat = actualStyleFormat; styleAssert = actualStyleAssert; moduleFlags = actualModuleFlags; codestyleLazyInstall = rsCodestyleLazyInstall; autoinherit = if rs != null then (import ../tools/cargo_autoinherit.nix) pkgs.stdenv.hostPlatform.system else null; };
    preCommitInstallHook =
      if effectiveLangs == [ ] && rust == null then "" else
      ''
        ${"# cargo is guaranteed on PATH by utils.combine (which requires `rust`)."}
        ${"# builtins-only checks: this runs on every direnv load, and cargo -Zscript alone is ~7 processes"}
        [[ ! -f $_vf_hooks/pre-commit || $(<"$_vf_hooks"/pre-commit) == *'source "$script_dir"/custom.sh'* ]] || cargo -Zscript -q ${../git/append-custom.rs} "$_vf_hooks"/pre-commit
        ${"# hooks run with the dev shell's tools even when committing from outside it; only its store entries, so the outer PATH is not frozen in"}
        _vf_path=
        IFS=: read -ra _vf_dirs <<< "$PATH"
        for _vf_d in "''${_vf_dirs[@]}"; do [[ $_vf_d == /nix/store/* ]] && _vf_path+=$_vf_d:; done
        printf -v _vf_custom 'export PATH=%q"$PATH"\n%s' "$_vf_path" "$(<${customSh})"
        [[ -x $_vf_hooks/custom.sh && $(<"$_vf_hooks"/custom.sh) == "$_vf_custom" ]] || { printf '%s\n' "$_vf_custom" > "$_vf_hooks"/custom.sh && chmod 0755 "$_vf_hooks"/custom.sh; }
        unset _vf_path _vf_dirs _vf_d _vf_custom
      '';

    lfsGitConfig = ''
      git config merge.ours.driver true
      ${"# `git wt <path> [worktree-add args]`: a worktree without the LFS-tracked files, which a checkout would copy out of .git/lfs one by one"}
      git config alias.wt '!f() { set -f; top="$(git rev-parse --show-toplevel)"; cd "''${GIT_PREFIX:-.}" && git worktree add --no-checkout "$@" && git -C "$1" sparse-checkout set --no-cone "/*" $(sed -n "s/^\([^ #]*\) .*filter=lfs.*/!\1/p" "$top/.gitattributes") && git -C "$1" checkout -q; }; f'
      ${"# prune keeps only what a checkout, worktree, stash or unpushed commit references, and deletes nothing origin lacks"}
      git config lfs.fetchrecentrefsdays 0
      git config lfs.fetchrecentcommitsdays 0
      git config lfs.pruneverifyremotealways true
      git config lfs.pruneverifyunreachablealways true # staged-never-committed objects are unreachable; without this, prune deletes them
    '';

    envrcFile = files.envrc { inherit pkgs; impure = envrc.impure or false; extra = envrc.extra or ""; };

    conventionsHook =
      if enable && conventions then ''
        (${git_ops}/bin/git_ops sync-conventions --version-key ${conventionsVersionKey} ${conventionsFileArgs} </dev/null >/dev/null 2>/dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &) # fd 3+: direnv waits on its env-dump pipe
      '' else "";
  in
  warnIfNeeded ({
    inherit workflows;
    inherit (workflows) errors warnings other;

    publish = import ../utils/publish.nix { inherit pkgs; after = pkgs.lib.optional (enable && figmaChecked != null && figmaChecked.on == "publish") (pkgs.lib.getExe figmaPublish); };

    appendCustom = ../git/append-custom.rs;
    preCommit = import ../git/pre_commit.nix;

    shellHook = utils.mkShellHook ''
      ${workflows.shellHook.__vFlakesHook}
      ${if enable then ''
      ${preCommitInstallHook}
      mkdir -p ./.github/actions/nix-env
      _vf_cp ${workflows.nixEnvAction} ./.github/actions/nix-env/action.yml
      _vf_cp ${(files.gitignore { inherit pkgs; langs = effectiveLangs; extra = gitignore.extra or "";})} ./.gitignore
      ${"# a consumer's own lines belong in `envrc.extra`; the diff names whatever the rewrite drops"}
      _vf_same ${envrcFile} ./.envrc || { [ -e ./.envrc ] && diff ${envrcFile} ./.envrc | sed -n 's/^> /v_flakes: .envrc rewritten, move into github.envrc.extra: /p' >&2; cp -f ${envrcFile} ./.envrc; }
      ${if lfs != null then ''
      _vf_cp ${(files.gitattributes { inherit pkgs; inherit lfs; })} ./.gitattributes
      ${"# Register the `ours` merge driver referenced by .gitattributes (kept in"}
      ${"# local .git/config, so it must be (re)applied per clone — `true` always"}
      ${"# succeeds without touching the file, keeping our version on conflict)."}
      if ! _vf_fresh lfs-git-config "${builtins.hashString "sha256" lfsGitConfig}" "$_vf_gitconfig"; then
        ${lfsGitConfig}
        _vf_stamp lfs-git-config "${builtins.hashString "sha256" lfsGitConfig}" "$_vf_gitconfig"
      fi
      (${pkgs.git-lfs}/bin/git-lfs prune --when-unverified=continue </dev/null >/dev/null 2>/dev/null 3>&- 4>&- 5>&- 6>&- 7>&- 8>&- 9>&- &) # fd 3+: direnv waits on its env-dump pipe
      '' else ""}
      ${conventionsHook}
      ''
      else ""}
    '';

    enabledPackages =
      if enable then
        [ git_ops code_duplication pkgs.treefmt ]
          ++ pkgs.lib.optional (particles.errors ++ particles.warnings != [ ]) particles.runner
          ++ (if semverChecks then [ pkgs.cargo-semver-checks ] else [ ])
          ++ (if npmRelease != null then [ (import ./npm-trust.nix { inherit pkgs; inherit (npmRelease) scope packagesDir; }) ] else [ ])
      else [ ];
  } // (if enable then { inherit git_ops code_duplication; test = particles.runner; } else { }))

