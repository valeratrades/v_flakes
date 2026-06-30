args@{ pkgs ? null, nixpkgs ? null, pname ? null, lastSupportedVersion ? null, jobsErrors, jobsWarnings, jobsOther ? [], hookPre ? {}, gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb", release ? null, containerRelease ? null, gitlabSync ? null, syncFork ? false,
  # Per-section install dependencies: { packages = [ "pkg1" ]; apt = [ "pkg2" ]; }
  installErrors ? {}, installWarnings ? {}, installOther ? {},
  # Per-section `on` triggers. Default: push + pull_request.
  # workflow_dispatch is always appended unless already present in the provided value.
  hooksErrors ? null, hooksWarnings ? null, hooksOther ? null,
  # Claude Code workflows (PR assistant + auto code review). Standalone, generic across repos.
  claude ? false,
  # Loud-fallback cargo wrapper (see github/default.nix). Only required when
  # called via the description-only path below; in normal use it's threaded in.
  cargoNightly ? null,
  # CI cache mechanism, threaded to every nix-using workflow. See github/cache.nix.
  cache ? { nix-action = true; },
}:

# If called with just nixpkgs (for flake description), return description attribute
if nixpkgs != null && pkgs == null then {
  description = ''
GitHub Actions workflow generator for Nix projects.

Note: This module is typically used via github/default.nix which provides
a higher-level interface with default job selection based on langs.

Direct usage (low-level):
```nix
workflows = import ./github/workflows/nix-parts {
  inherit pkgs;
  lastSupportedVersion = "nightly-1.86";
  jobsErrors = [ "rust-tests" "rust-doc" ];
  # Or with args: { name = "rust-tests"; args.skipPatterns = [ "pattern1" "pattern2" ]; }
  jobsWarnings = [ "rust-clippy" "rust-machete" ];
  jobsOther = [ "loc-badge" ];
  # Per-section `on` triggers (default: push + pull_request; workflow_dispatch always appended):
  # hooksErrors = { push = { branches = [ "main" ]; }; pull_request = {}; };
};
```

Available jobs: rust-tests, rust-doc, rust-miri, rust-clippy, rust-machete, rust-sorted, rust-sorted-derives, rust-unused-features, rust-leptosfmt, go-tests, go-gocritic, go-security-audit, py-tests, tokei, loc-badge, code-duplication

Standalone workflows:
- release = { }  # enabled by presence, disabled with `enable = false`
    Per-target binary release for cargo-binstall. Generates one workflow file per target (release-{shortName}.yml).
    Default hooks: push.tags = ["v[0-9]+.*"] + workflow_dispatch. Override via hooks = { ... }.
    Default targets: x86_64-unknown-linux-gnu, x86_64-apple-darwin, aarch64-apple-darwin
- gitlabSync = { mirrorBaseUrl = "https://gitlab.com/user"; }
    Sync to GitLab mirror (triggers on push to any branch/tag)
    Repo name is appended from GitHub context. Requires GITLAB_TOKEN secret
- claude = true  # on by default for enabled repos
    Claude Code PR assistant (claude.yml, on @claude mentions) + auto code review
    (claude-code-review.yml, on PR open/update). Generic across repos.
    Requires the CLAUDE_CODE_OAUTH_TOKEN secret (org secret w/ "All repositories"
    visibility shares it across an entire org; personal repos need their own copy).
'';
} else

# Otherwise, generate workflows
let
  utils = import ../../../utils;

  # Generate load_nix workflow for a section if it has packages
  makeLoadNixWorkflow = installConfig:
    import ./shared/load_nix.nix { packages = installConfig.packages or []; inherit cache; };

  # Generate install steps for jobs (just cache restore, actual install done by load_nix)
  makeInstallSteps = installConfig: import ./shared/install.nix {
    packages = installConfig.packages or [];
    apt = installConfig.apt or [];
    debug = installConfig.debug or false;
    inherit cache;
  };

  # Check if section has nix packages
  hasNixPackages = installConfig: (installConfig.packages or []) != [];

  # Generate nix-shell prefix for wrapping commands (sets up PKG_CONFIG_PATH etc)
  # We need to also set LD_LIBRARY_PATH for runtime library loading
  nixShellPrefix = installConfig:
    let
      packages = installConfig.packages or [];
      pkgList = builtins.concatStringsSep " " packages;
    in
    if packages == [] then ""
    # Use --command with bash to set LD_LIBRARY_PATH from buildInputs before running
    else "nix-shell -p ${pkgList} --command ";

  files = {
		# shared {{{
    base = ./shared/base.nix;
    tokei = ./shared/tokei.nix;
    loc-badge = ./shared/loc-badge.nix;
    sync-gitlab = ./shared/sync-gitlab.nix;
    code-duplication = ./shared/code-duplication.nix;
		#,}}}

		# rust {{{
    rust-base = ./rust/base.nix;
		rust-tests = ./rust/tests.nix;
    rust-doc = ./rust/doc.nix;
    rust-miri = ./rust/miri.nix;
    rust-clippy = ./rust/clippy.nix;
    rust-machete = ./rust/machete.nix;
    rust-sorted = ./rust/sorted.nix;
    rust-sorted-derives = ./rust/sorted_derives.nix;
    rust-unused-features = ./rust/unused_features.nix;
    rust-release = ./rust/release.nix;
    container-release = ../../container/workflow.nix;
		#,}}}

		# go {{{
    go-tests = ./go/tests.nix;
    go-gocritic = ./go/gocritic.nix;
    go-security-audit = ./go/security_audit.nix;
		#,}}}

		# py {{{
    py-tests = ./py/tests.nix;
		#,}}}
  };

	importFile = installConfig: jobSpec:
    let
      # Support both string and attrset (for passing args)
      jobName = if builtins.isString jobSpec then jobSpec else jobSpec.name;
      jobArgs = if builtins.isString jobSpec then {} else (jobSpec.args or {});

      # Build the arguments to pass to the imported file
      args = if jobName == "rust-tests"
             then { lastSupportedVersion = lastSupportedVersion; } // jobArgs
             else if jobName == "loc-badge"
             then { inherit gistId; } // jobArgs
             else jobArgs;

      # Import the file
      imported = import (builtins.getAttr jobName files);

      # Check if it's a function (needs to be called) or already a value (attrset)
      baseValue = if builtins.isFunction imported
                  then imported args
                  else imported;

      # Generate install steps from section-level install config
      installSteps = makeInstallSteps installConfig;
      needsNix = hasNixPackages installConfig;

      # Apply hookPre if specified for this job
      valueWithHookPre = if builtins.hasAttr jobName hookPre
              then
                let
                  # Get the list of pre-hook commands for this job
                  preHookCmds = builtins.getAttr jobName hookPre;

                  # Convert each string command to a step attrset
                  preHookSteps = map (cmd: { run = cmd; }) preHookCmds;

                  # Prepend pre-hook steps to existing steps
                  modifiedSteps = preHookSteps ++ baseValue.steps;
                in
                baseValue // { steps = modifiedSteps; }
              else baseValue;

      # Apply install steps (after checkout, before other steps)
      # Find checkout step and insert install steps after it
      valueWithInstall = if installSteps != [] then
        let
          steps = valueWithHookPre.steps;
          # Find index of checkout step (usually first)
          checkoutIdx = pkgs.lib.lists.findFirstIndex
            (s: (s.uses or "") == "actions/checkout@v4")
            0
            steps;
          # Split steps: before+checkout, then rest
          beforeAndCheckout = pkgs.lib.lists.take (checkoutIdx + 1) steps;
          afterCheckout = pkgs.lib.lists.drop (checkoutIdx + 1) steps;
        in
        valueWithHookPre // { steps = beforeAndCheckout ++ installSteps ++ afterCheckout; }
      else valueWithHookPre;

      # Wrap run commands in nix-shell if packages are specified
      # Also set LD_LIBRARY_PATH for runtime library loading (needed on non-NixOS systems like GHA Ubuntu)
      shellPrefix = nixShellPrefix installConfig;
      packages = installConfig.packages or [];
      # Always include openssl.out (runtime libs), openssl.dev (headers), and pkg-config (so openssl-sys finds nix headers, not system ones)
      allPackages = packages ++ [ "pkg-config" "openssl.out" "openssl.dev" ]; #Q: should that include "mold"?
      pkgList = builtins.concatStringsSep " " allPackages;
      # Build LD_LIBRARY_PATH setup using nix-build to get exact store paths
      # This is needed on non-NixOS systems (like GHA Ubuntu) where runtime libraries aren't in default search paths
      ldLibPathSetup = builtins.concatStringsSep "" (map (pkg:
        "export LD_LIBRARY_PATH=\\\"\\$(nix-build '<nixpkgs>' -A ${pkg} --no-out-link)/lib\\\${LD_LIBRARY_PATH:+:}\\$LD_LIBRARY_PATH\\\" && "
      ) allPackages);
      # Escape for embedding in double-quoted nix-shell --command "...", preserving ${{ }} GHA expressions
      escapeForNixShell = s:
        let
          protected = builtins.replaceStrings ["\${{"] ["__GHA_EXPR__"] s;
          escaped = builtins.replaceStrings ["\"" "$"] ["\\\"" "\\$"] protected;
        in builtins.replaceStrings ["__GHA_EXPR__"] ["\${{"] escaped;
      wrapStep = step:
        if shellPrefix == "" then step
        else if step ? run then
          # Wrap the run command in nix-shell, but skip if it's already a nix command or echo
          if builtins.substring 0 4 step.run == "nix " then step
          else if builtins.substring 0 9 step.run == "nix-shell" then step
          else if builtins.substring 0 5 step.run == "echo " then step
          else step // { run = "nix-shell -p ${pkgList} --command \"${ldLibPathSetup}${escapeForNixShell step.run}\""; }
        else step;
      valueWithWrappedRuns = if needsNix then
        valueWithInstall // { steps = map wrapStep valueWithInstall.steps; }
      else valueWithInstall;

      # Add load_nix to needs if nix packages are required
      existingNeeds = valueWithWrappedRuns.needs or null;
      newNeeds = if needsNix then
        if existingNeeds == null then "load_nix"
        else if builtins.isList existingNeeds then [ "load_nix" ] ++ existingNeeds
        else [ "load_nix" existingNeeds ]
      else existingNeeds;

      value = if newNeeds != null
        then valueWithWrappedRuns // { needs = newNeeds; }
        else valueWithWrappedRuns;
    in
    {
      name = jobName;
      inherit value;
    };

  constructJobs = installConfig: paths:
    builtins.listToAttrs (map (importFile installConfig) paths);
  
  defaultHooks = utils.defaultHooks;

  # Build the `on` attrset for a workflow.
  # workflow_dispatch is always injected unless the caller already set it explicitly.
  makeOn = hooksOverride:
    let base = if hooksOverride != null then hooksOverride else defaultHooks;
    in if base ? workflow_dispatch then base
       else base // { workflow_dispatch = {}; };

  base = { };
  # release = { ... } is enabled by presence. Set `enable = false` to disable.
  # `release = null` (the default) means no release workflows.
  releaseEnabled = release != null && (
    if builtins.isAttrs release then (release.enable or true)
    else abort "release must be an attrset, e.g. release = { }"
  );

  # Path to the Cargo.toml of the crate being packaged for binstall.
  # In a workspace, point this at the binary crate's manifest (the workspace
  # root has no [package] section and would fail the binstall metadata check).
  releaseCargoTomlPath = if releaseEnabled then (release.cargoTomlPath or "Cargo.toml") else "Cargo.toml";

  # Per-target release workflows (one file per target)
  releaseWorkflows = if releaseEnabled then
    let
      releaseArgs = builtins.removeAttrs release [ "enable" "cargoTomlPath" ];
      spec = import files.rust-release releaseArgs;
    in builtins.mapAttrs (name: wf:
      (pkgs.formats.yaml { }).generate "" (builtins.removeAttrs wf [ "standalone" "filename" "default" ])
    ) spec.workflows
  else {};

  # Opt-in via `github { containerRelease = { registry = "ghcr.io/EV-invest"; }; }`.
  containerReleaseWorkflow = if containerRelease != null then
    (pkgs.formats.yaml { }).generate "" (builtins.removeAttrs
      (import files.container-release { inherit (pkgs) lib; inherit cache; registry = pkgs.lib.toLower containerRelease.registry; deployKeys = containerRelease.deployKeys or []; })
      [ "standalone" "filename" ])
  else null;

  # Sync fork workflow (rebase over upstream)
  syncForkWorkflow = if syncFork then
    let
      syncSpec = import ./shared/sync-fork.nix;
    in (pkgs.formats.yaml { }).generate "" (builtins.removeAttrs syncSpec [ "standalone" ])
  else null;

  # Claude Code workflows (standalone, generic). Generated as a pair when `claude` is set.
  claudeWorkflow = if claude then
    (pkgs.formats.yaml { }).generate "" (builtins.removeAttrs (import ./shared/claude.nix) [ "standalone" ])
  else null;
  claudeReviewWorkflow = if claude then
    (pkgs.formats.yaml { }).generate "" (builtins.removeAttrs (import ./shared/claude-review.nix) [ "standalone" ])
  else null;

  # GitLab sync workflow (triggers on any push)
  stripTrailingSlash = s:
    let len = builtins.stringLength s;
    in if len > 0 && builtins.substring (len - 1) 1 s == "/"
       then builtins.substring 0 (len - 1) s
       else s;
  gitlabSyncWorkflow = if gitlabSync != null then
    let
      syncSpec = import files.sync-gitlab (stripTrailingSlash gitlabSync.mirrorBaseUrl);
    in (pkgs.formats.yaml { }).generate "" (builtins.removeAttrs syncSpec [ "standalone" ])
  else null;

  # Generate load_nix job for a section if it has packages
  loadNixJob = installConfig:
    let
      wf = makeLoadNixWorkflow installConfig;
    in
    if wf != null then wf.jobs else {};

  workflows = {
    #TODO!!!!: construct all of this procedurally, as opposed to hardcoding `jobs` and `env` base to `rust-base`
    #Q: Potentially standardize each file providing a set of outs, like `jobs`, `env`, etc, then manually join on them?
    errors = if jobsErrors != [] then (pkgs.formats.yaml { }).generate "" (
      pkgs.lib.recursiveUpdate base {
        name = "Errors";
        "on" = makeOn hooksErrors;
        permissions = (import files.base).permissions;
        env = (import files.rust-base).env;
        jobs = pkgs.lib.recursiveUpdate
          (pkgs.lib.recursiveUpdate (import files.rust-base).jobs (loadNixJob installErrors))
          (constructJobs installErrors jobsErrors);
      }
    ) else null;

    warnings = if jobsWarnings != [] then (pkgs.formats.yaml { }).generate "" (
      pkgs.lib.recursiveUpdate base {
        name = "Warnings";
        "on" = makeOn hooksWarnings;
        permissions = (import files.base).permissions;
        env = (import files.rust-base).env;
        jobs = pkgs.lib.recursiveUpdate
          (pkgs.lib.recursiveUpdate (import files.rust-base).jobs (loadNixJob installWarnings))
          (constructJobs installWarnings jobsWarnings);
      }
    ) else null;

    other = if jobsOther != [] then (pkgs.formats.yaml { }).generate "" (
      pkgs.lib.recursiveUpdate base {
        name = "Other";
        "on" = makeOn hooksOther;
        permissions = (import files.base).permissions;
        jobs = pkgs.lib.recursiveUpdate
          (loadNixJob installOther)
          (constructJobs installOther jobsOther);
      }
    ) else null;
  };

  ensureBinstallScript = ../../ensure_binstall_metadata.rs;

  releaseExpectedFiles = map (name: "release-${name}.yml") (builtins.attrNames releaseWorkflows);

  releaseHook = if releaseWorkflows != {} then
    let
      copyCommands = builtins.concatStringsSep "\n" (
        pkgs.lib.mapAttrsToList (name: wf: ''
          cp -f ${wf} ./.github/workflows/release-${name}.yml
        '') releaseWorkflows
      );
    in ''
      ${copyCommands}
      ${cargoNightly} -Zscript -q ${ensureBinstallScript} ${releaseCargoTomlPath}
    ''
  else "";

  # Warn about stale files containing "release" in .github/workflows/ that we don't generate
  releaseStaleWarningHook = if releaseEnabled then
    let
      expectedBash = builtins.concatStringsSep " " (map (f: ''"${f}"'') releaseExpectedFiles);
    in ''
      _release_stale=()
      for f in ./.github/workflows/*release*; do
        [ -e "$f" ] || continue
        _base="$(basename "$f")"
        _match=0
        for _exp in ${expectedBash}; do
          [ "$_base" = "$_exp" ] && _match=1 && break
        done
        [ "$_match" -eq 0 ] && _release_stale+=("$_base")
      done
      if [ ''${#_release_stale[@]} -gt 0 ]; then
        printf '\033[33mwarning:\033[0m stale release files in .github/workflows/ (not matching selected targets):\n'
        for _s in "''${_release_stale[@]}"; do
          printf '  - %s\n' "$_s"
        done
      fi
    ''
  else "";

  containerReleaseHook = if containerReleaseWorkflow != null then ''
    cp -f ${containerReleaseWorkflow} ./.github/workflows/release-container.yml
  '' else "";

  syncForkHook = if syncForkWorkflow != null then ''
    cp -f ${syncForkWorkflow} ./.github/workflows/sync_fork.yml
  '' else "";

  gitlabSyncHook = if gitlabSyncWorkflow != null then ''
    cp -f ${gitlabSyncWorkflow} ./.github/workflows/sync_gitlab.yml
  '' else "";

  claudeHook = if claudeWorkflow != null then ''
    cp -f ${claudeWorkflow} ./.github/workflows/claude.yml
    cp -f ${claudeReviewWorkflow} ./.github/workflows/claude-code-review.yml
  '' else "";

  errorsHook = if workflows.errors != null then ''
    cp -f ${workflows.errors} ./.github/workflows/errors.yml
  '' else "";
  warningsHook = if workflows.warnings != null then ''
    cp -f ${workflows.warnings} ./.github/workflows/warnings.yml
  '' else "";
  otherHook = if workflows.other != null then ''
    cp -f ${workflows.other} ./.github/workflows/other.yml
  '' else "";
in
workflows // {
  inherit releaseWorkflows containerReleaseWorkflow gitlabSyncWorkflow syncForkWorkflow claudeWorkflow claudeReviewWorkflow;
  shellHook = utils.mkShellHook ''
    mkdir -p ./.github/workflows
    ${errorsHook}
    ${warningsHook}
    ${otherHook}
    ${releaseHook}
    ${releaseStaleWarningHook}
    ${containerReleaseHook}
    ${syncForkHook}
    ${gitlabSyncHook}
    ${claudeHook}
  '';
}
