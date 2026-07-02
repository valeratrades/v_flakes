args@{ pkgs ? null, nixpkgs ? null, pname ? null, lastSupportedVersion ? null, jobs ? {}, hookPre ? {}, gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb", langs ? null, gitignore ? {}, lfs ? null, labels ? {}, preCommit ? {}, conventions ? false,
  # Pass language module outputs — langs is inferred from whichever are non-null
  # rs also provides the rust toolchain (rs.rust) — required when enable = true
  rs ? null,
  py ? null,
  tex ? null,
  js ? null,
  # Or override individually (these take precedence over rs)
  traceyCheck ? null, style ? null, styleFormat ? null, styleAssert ? null, moduleFlags ? null,
  # Top-level install applies to all job sections (errors, warnings, other, release)
  # Per-section install overrides this.
  install ? {},
  # CI binary-cache mechanism for every nix-using workflow (install steps, load_nix,
  # container release). Exactly one of { nix-action = true; } (default, private GH cache)
  # or { cachix = "<name>"; } (public/org cache; push needs CACHIX_AUTH_TOKEN). See cache.nix.
  cache ? { nix-action = true; },
  release ? null, containerRelease ? null, gitlabSync ? null,
  syncFork ? false,
  # Claude Code workflows (PR assistant + auto code review). On by default for enabled repos.
  claude ? true,
  # Dirs to exclude from sort-derives and codestyle (e.g. vendored code or submodules), e.g. ["libs/nautilus_trader"]
  excludeDirs ? [],
  # Master switch: enables CI workflows, pre-commit hooks, gitignore, label sync, git_ops, etc.
  # When false (default), only explicitly requested standalone workflows (syncFork, gitlabSync, release) are generated.
  enable ? false,
}:

# Warn when enable-gated fields are explicitly passed but enable is false
let
  enableGatedFields = [ "lastSupportedVersion" "jobs" "hookPre" "gitignore" "lfs" "labels" "preCommit" "conventions" "release" "containerRelease" "gitlabSync" "install" "traceyCheck" "style" "styleFormat" "styleAssert" "moduleFlags" "excludeDirs" "claude" ];
  presentGated = builtins.filter (f: args ? ${f}) enableGatedFields;
  warnIfNeeded = value:
    if (!enable && presentGated != []) then
      builtins.trace "WARNING [v_flakes.github]: `enable` is false but the following fields were explicitly set and will have no effect: ${builtins.concatStringsSep ", " presentGated}" value
    else value;
in

# Priority: explicit params > rs module > defaults
let
  # Infer langs from which language modules are passed
  inferredLangs =
    (if rs != null then [ "rs" ] else [])
    ++ (if py != null then [ "py" ] else [])
    ++ (if tex != null then [ "tex" ] else [])
    ++ (if js != null then [ "js" ] else []);
  #DEPRECATE: when everything has switched to new standard
  effectiveLangs =
    if langs != null then
      builtins.trace "DEPRECATED [v_flakes.github]: `langs` is deprecated. Pass language modules directly instead (e.g. `inherit rs py tex;`)" langs
    else inferredLangs;

  # Extract rust toolchain from rs module. Required when `enable` — the hook
  # install runs append_custom.rs via cargo, and `combine` (which provisions
  # cargo on PATH) likewise demands `rust`. The assert lives in the `enable`
  # branch of shellHook below (not on this binding — nothing forces `rust`
  # there anymore, so a lazy assert would never fire).
  rust = if rs != null then (rs.rust or null) else null;

  # Extract from rs if provided
  rsTraceyCheck = if rs != null then (rs.traceyCheck or false) else false;
  rsStyleFormat = if rs != null then (rs.styleFormat or true) else true;
  rsStyleAssert = if rs != null then (rs.styleAssert or false) else false;
  rsModuleFlags = if rs != null then (rs.moduleFlags or "") else "";
  rsCodestyleLazyInstall = if rs != null then (rs.codestyleLazyInstall or "") else "";

  # Compute from style parameter if provided (for standalone usage without rs)
  styleModules = if style != null then (style.modules or {}) else {};
  valueToString = value:
    if builtins.isBool value then (if value then "true" else "false")
    else builtins.toString value;
  computedModuleFlags = builtins.concatStringsSep " " (
    builtins.attrValues (builtins.mapAttrs (name: value:
      "--${builtins.replaceStrings ["_"] ["-"] name}=${valueToString value}"
    ) styleModules)
  );
  styleParamFormat = if style != null then (style.format or null) else null;
  styleParamAssert = if style != null then (style.check or null) else null;

  # Final values: explicit > style param > rs > defaults
  actualTraceyCheck = if traceyCheck != null then traceyCheck else rsTraceyCheck;
  actualStyleFormat = if styleFormat != null then styleFormat
                      else if styleParamFormat != null then styleParamFormat
                      else rsStyleFormat;
  actualStyleAssert = if styleAssert != null then styleAssert
                      else if styleParamAssert != null then styleParamAssert
                      else rsStyleAssert;
  actualModuleFlags = if moduleFlags != null then moduleFlags
                      else if computedModuleFlags != "" then computedModuleFlags
                      else rsModuleFlags;
  # Visual-regression pre-commit step, driven by the js module's required
  # `preCommit.visual`. Reading it forces js's requiredness asserts.
  actualJsVisual = if js != null then js.preCommit.visual else false;
in

# If called with just nixpkgs (for flake description), return description attribute
if nixpkgs != null && pkgs == null then {
  description = builtins.readFile ./description.md;
} else

let
  utils = import ../utils;
  files = import ../files;

  # Shared defaults across all languages
  sharedWarnings = [ "tokei" "code-duplication" ]; #TEST: if code-duplication works for other languages
  sharedOther = [ "loc-badge" ];

  # Default jobs per language
  defaultJobsByLang = {
    rs = {
      errors = [ "rust-tests" ];
      warnings = [ "rust-doc" "rust-clippy" "rust-machete" "rust-sorted" "rust-sorted-derives" ]; #WAIT: until "rust-unused-features" finally gets --edition 2024 support
    };
    go = {
      errors = [ "go-tests" ];
      warnings = [ "go-gocritic" "go-security-audit" ];
    };
    py = {
      errors = [ "py-tests" ];
      warnings = [];
    };
    tex = {
      errors = [];
      warnings = [];
    };
    js = {
      errors = [ ];
      warnings = [ ];
    };
  };

  # Compute defaults based on langs
  computeDefaultsForLangs = category:
    let
      langJobs = builtins.concatLists (map (lang:
        (defaultJobsByLang.${lang}.${category} or [])
      ) effectiveLangs);
      shared = if category == "warnings" then sharedWarnings
               else if category == "other" then sharedOther
               else [];
    in
    langJobs ++ shared;

  # Process a jobs section (errors, warnings, or other)
  # Takes: { default? = bool; defaults? = bool; augment? = [...]; exclude? = [...]; } or just a list (legacy)
  # Accepts both `default` and `defaults` as aliases via optionalDefaults
  processJobsSection = category: sectionConfig: topDefault:
    let
      # Handle legacy list format
      isLegacyList = builtins.isList sectionConfig;
      sectionRaw = if isLegacyList then { augment = sectionConfig; } else sectionConfig;
      section = utils.optionalDefaults sectionRaw;

      # Determine if defaults should be enabled for this section
      sectionDefault = section.default or topDefault;

      # Get base jobs from defaults if enabled
      baseJobs = if sectionDefault then computeDefaultsForLangs category else [];

      # Get augment and exclude lists
      augmentJobs = section.augment or [];
      excludeJobs = section.exclude or [];

      # Helper to get job name from spec (handles both string and attrset)
      getJobName = spec: if builtins.isString spec then spec else spec.name;

      # Filter out excluded jobs
      filteredBase = builtins.filter (job:
        !(builtins.elem (getJobName job) excludeJobs)
      ) baseJobs;
    in
    filteredBase ++ augmentJobs;

  # Get top-level default setting (accepts both `default` and `defaults`)
  jobsNormalized = utils.optionalDefaults jobs;
  topDefault = jobsNormalized.default or false;

  # Process each section
  jobsErrors = processJobsSection "errors" (jobs.errors or {}) topDefault;
  jobsWarnings = processJobsSection "warnings" (jobs.warnings or {}) topDefault;
  jobsOther = processJobsSection "other" (jobs.other or {}) topDefault;

  # Extract install config from each section, falling back to top-level install
  effectiveInstall = section:
    if builtins.isAttrs section && section ? install then section.install
    else install;
  installErrors = effectiveInstall (jobs.errors or {});
  installWarnings = effectiveInstall (jobs.warnings or {});
  installOther = effectiveInstall (jobs.other or {});

  # Extract hooks (on-triggers) from each section, null means use default
  effectiveHooks = section:
    if builtins.isAttrs section && section ? hooks then section.hooks
    else null;
  hooksErrors = effectiveHooks (jobs.errors or {});
  hooksWarnings = effectiveHooks (jobs.warnings or {});
  hooksOther = effectiveHooks (jobs.other or {});

  # sync_fork: can be set via jobs.sync_fork or top-level syncFork param
  effectiveSyncFork = syncFork || (jobs.sync_fork or false);

  workflows = import ./workflows/nix-parts ({
    inherit pkgs gistId cargoNightly cache;
    syncFork = effectiveSyncFork;
  } // (if enable then {
    inherit pname lastSupportedVersion jobsErrors jobsWarnings jobsOther hookPre release containerRelease gitlabSync;
    inherit installErrors installWarnings installOther;
    inherit hooksErrors hooksWarnings hooksOther;
    inherit claude;
  } else {
    jobsErrors = [];
    jobsWarnings = [];
  }));

  # --- Everything below is only computed when `enable = true` ---

  # Process labels config (accepts both `default` and `defaults`)
  defaultLabels = import ./labels.nix;
  labelsConfigRaw = if builtins.isAttrs labels then labels else { extra = labels; };
  labelsConfig = utils.optionalDefaults labelsConfigRaw;
  labelsEnabled = enable && (labelsConfig.enable or true);
  useDefaults = labelsConfig.default or true;
  extraLabels = labelsConfig.extra or [];
  allLabels = (if useDefaults then defaultLabels else []) ++ extraLabels;

  # Generate label args for git commands
  # These are interpolated directly into a bash script (no eval), so we just need to escape
  # single quotes for the bash 'literal string' context.
  escapeForBash = s: builtins.replaceStrings ["'"] ["'\\''"] s;
  labelArgs = "--labels-json '" + escapeForBash (builtins.toJSON allLabels) + "'";

  # Use local cargo, falling back loudly to rustup's nightly if unavailable.
  # Unset RUSTC_WRAPPER to bypass sccache (its temp dir may not survive backgrounding).
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

  git_ops = import ./git.nix { inherit pkgs labelArgs cargoNightly; gitOpsScript = ./git_ops.rs; };
  code_duplication = import ./code_duplication.nix { inherit pkgs cargoNightly; script = ./workflows/code-duplication.rs; };

  # Process preCommit config
  # can be very slow
  semverChecks = preCommit.semverChecks or false;

  # Label sync runs in background to avoid blocking shell startup.
  labelSyncHook = if labelsEnabled then ''
    ${"# </dev/null: backgrounded job must not inherit tty stdin, or the label-delete"}
    ${"# prompt path sees a terminal and the job can hang on SIGTTIN."}
    (${git_ops}/bin/git_ops sync-labels </dev/null >/dev/null 2>/dev/null &)
  '' else "";

  # Convention files copied from github.com/<owner>/<owner> or github.com/<owner>/.github
  # on first rebuild for each v_flakes version. Expand this list to add more.
  conventionsFiles = [ "GIT_CONVENTION.md" ];
  # Version key: any change to the script or the file list re-pulls.
  # Tied to v_flakes via the on-disk contents of git_ops.rs (its store path
  # changes with every v_flakes revision that touches it).
  conventionsVersionKey = builtins.hashString "sha256" (
    (builtins.readFile ./git_ops.rs) + (builtins.toJSON conventionsFiles)
  );
  conventionsFileArgs = builtins.concatStringsSep " " (map (f: "--file ${f}") conventionsFiles);
  conventionsHook = if enable && conventions then ''
    (${git_ops}/bin/git_ops sync-conventions --version-key ${conventionsVersionKey} ${conventionsFileArgs} >/dev/null 2>/dev/null &)
  '' else "";
in
warnIfNeeded ({
  inherit workflows;
  inherit (workflows) errors warnings other;

  appendCustom = ./append_custom.rs;
  preCommit = import ./pre_commit.nix;

  inherit labelSyncHook;

  shellHook = utils.mkShellHook ''
    ${utils.unwrapShellHook workflows.shellHook}
    ${if enable then
       # `enable` requires the rust toolchain: the hook install runs
       # append_custom.rs via cargo, which combine guarantees on PATH only when
       # `rust` is provisioned. Assert here (forced because this branch is
       # built) so a missing `rs` fails loud rather than producing a broken hook.
       assert (rust != null) || throw
         "v_flakes.github: `enable = true` requires the rust toolchain — pass the `rs` module (which provides `rs.rust`).";
       ''
    ${"# cargo is guaranteed on PATH by utils.combine (which requires `rust`)."}
    cargo -Zscript -q ${./append_custom.rs} ./.git/hooks/pre-commit
    install -m 0755 ${(import ./pre_commit.nix) { inherit pkgs pname semverChecks excludeDirs; traceyCheck = actualTraceyCheck; styleFormat = actualStyleFormat; styleAssert = actualStyleAssert; moduleFlags = actualModuleFlags; codestyleLazyInstall = rsCodestyleLazyInstall; jsVisual = actualJsVisual; }} ./.git/hooks/custom.sh
    cp -f ${(files.gitignore { inherit pkgs; langs = effectiveLangs; extra = gitignore.extra or "";})} ./.gitignore
    ${if lfs != null then ''
    cp -f ${(files.gitattributes { inherit pkgs; inherit lfs; })} ./.gitattributes
    ${"# Register the `ours` merge driver referenced by .gitattributes (kept in"}
    ${"# local .git/config, so it must be (re)applied per clone — `true` always"}
    ${"# succeeds without touching the file, keeping our version on conflict)."}
    git config merge.ours.driver true
    '' else ""}
    ${labelSyncHook}
    ${conventionsHook}
    ''
    else ""}
  '';

  enabledPackages = if enable then
    [ git_ops code_duplication pkgs.treefmt ]
    ++ (if semverChecks then [ pkgs.cargo-semver-checks ] else [])
  else [];
} // (if enable then { inherit git_ops code_duplication; } else {}))

