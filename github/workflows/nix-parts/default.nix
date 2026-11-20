args@{ pkgs ? null
, nixpkgs ? null
, pname ? null
, lastSupportedVersion ? null
, # resolved particles (github/particles), one workflow per section
  particlesErrors ? [ ]
, particlesWarnings ? [ ]
, jobsOther ? [ ]
, gistId ? "b48e6f02c61942200e7d1e3eeabf9bcb"
, release ? null
, containerRelease ? null
, # { scope; packagesDir; }: npm trusted publishing of `@<scope>/<pkg>-v<version>` tags. See shared/npm-release.nix.
  npmRelease ? null
, # { dir; render; gate ? null; paths ? null; rustCache ? null; }: visual-baselines.yml. See shared/visual-baselines.nix.
  visualBaselines ? null
, # { on; folder ? null; }: figma.yml when on = "gha". See shared/figma.nix.
  figma ? null
, # { html; }: release-typst.yml, the typ module's document on release tags. See shared/release-typst.nix.
  typstRelease ? null
, # checkout fetches LFS objects
  lfs ? false
, gitlabSync ? null
, # { skargo; }: skills.yml, `skargo check` / `publish` of a skills repo. See shared/skills.nix.
  skills ? null
, syncFork ? false
, # Per-section install dependencies: { packages = [ "pkg1" ]; apt = [ "pkg2" ]; }
  installErrors ? { }
, installWarnings ? { }
, installOther ? { }
, # Per-section `on` triggers. Default: push.
  # workflow_dispatch is always appended unless already present in the provided value.
  hooksErrors ? null
, hooksWarnings ? null
, hooksOther ? null
, # Claude Code workflows (PR assistant + auto code review). Standalone, generic across repos.
  claude ? false
, # Loud-fallback cargo wrapper (see github/default.nix). Only required when
  # called via the description-only path below; in normal use it's threaded in.
  cargoNightly ? null
, # CI cache mechanism, threaded to every nix-using workflow. See github/cache.nix.
  cache ? { }
, # Cargo manifests may name sibling checkouts by path; jobs that run cargo outside Errors/Warnings then need pre_ci's rewritten copies.
  rustRepo ? false
, # Cachix cache name to publish `packages.default` to. See shared/cachix.nix.
  publishCachix ? null
, # rs.cargoRoot: rust jobs run there
  cargoRoot ? "."
, # rs.webUnstable: jobs that drop `.cargo/config.toml` get its `--cfg` back through RUSTFLAGS
  webUnstable ? false
,
}:

# If called with just nixpkgs (for flake description), return description attribute
if nixpkgs != null && pkgs == null then {
  description = ''
    GitHub Actions workflow generator for Nix projects.

    Note: This module is typically used via github/default.nix which provides
    a higher-level interface with default job selection based on langs.

    Errors and Warnings run the particles of `jobs.errors` / `jobs.warnings` (github/particles): each
    as a job: a `ci` body's own, or `nix run .#test -- --severity <s> <name>` over its own lean nix cache,
    then a `report` job writing the section's badge (`<repo>-errors.json` / `-warnings.json` in the badge gist).

    Other jobs: loc-badge, asset-gate (`jobs.other`), the latter with args:
      jobsOther = [ { name = "asset-gate"; args = { asset = "docs/x.svg"; command = "nix run .#film"; everySeconds = 86400; }; } ];

    Standalone workflows:
    - release = { }  # enabled by presence, disabled with `enable = false`
        Per-target binary release for cargo-binstall. Generates one workflow file per target (release-{shortName}.yml).
        Default hooks: push.tags = ["v[0-9]+.*"] + workflow_dispatch. Override via hooks = { ... }.
        Default targets: x86_64-unknown-linux-gnu, x86_64-apple-darwin, aarch64-apple-darwin
    - npmRelease = { scope = "evinvest"; packagesDir = "ts"; }
        release-npm.yml: a pushed `@evinvest/<pkg>-v<version>` tag publishes `ts/<pkg>` through npm
        trusted publishing (OIDC), building its `file:` dependencies first. Each package's trusted
        publisher on npmjs.com must name this repo and `release-npm.yml`: the shell's `npm-trust` sets that up.
    - visualBaselines = { dir = "tests/__screenshots__"; render = "accept-test"; gate = "test"; paths = [ "frontend/**" ]; }
        visual-baselines.yml: renders every baseline under `dir` on ubuntu-latest, uploads them as the
        `visual-snapshots` artifact and fails when they differ from the committed ones. Contract in github/description.md.
    - figma = { on = "gha" | "publish"; folder = "https://www.figma.com/files/team/<team>/folder/<id>"; }
        `nix run .#figma` renders into the file named after the repo in the folder (`folder`, else the FIGMA_FOLDER
        variable): "gha", figma.yml on a release tag or a `[figma]` comment; "publish", github's `publish` app after
        the tag is pushed. Contract in github/description.md.
    - typstRelease = { html = true; }  # set by `github { typ = ...; }` from a typ module with `main`
        release-typst.yml: on a release tag, `nix build .#default` and attach each `output.<ext>` to the Release as
        `<repo>.<ext>`; with `html`, also deploy output.html to GitHub Pages.
    - skills = { skargo = "github:EV-Main/skills/<rev>"; }
        skills.yml: `skargo check` on PRs, `skargo publish` (tags `<name>--v<version>`) on main, and
        `claude plugin validate --strict` when the repo has a marketplace.
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

    # lean caches only what a job builds, and load_nix only fetches: there it saves nothing, and would only gate the jobs
    prefetches = (import ../../cache.nix { inherit cache; }).leanDir == null;
    makeLoadNixWorkflow = installConfig:
      if prefetches then import ./shared/load_nix.nix { packages = installConfig.packages or [ ]; inherit cache; } else null;

    # Generate install steps for jobs (just cache restore, actual install done by load_nix)
    makeInstallSteps = installConfig: import ./shared/install.nix {
      packages = installConfig.packages or [ ];
      apt = installConfig.apt or [ ];
      debug = installConfig.debug or false;
      inherit cache;
    };

    # Check if section has nix packages
    hasNixPackages = installConfig: (installConfig.packages or [ ]) != [ ];

    # job-level, not workflow-level: the shared jobs alongside need the repo root
    inCargoRoot = job:
      if cargoRoot == "." then job
      else pkgs.lib.recursiveUpdate job { defaults.run.working-directory = cargoRoot; };

    # every bash `run` must parse, so a broken one fails shell entry instead of CI.
    # Not `pkgs.formats.yaml`: its remarshal folded a long `run` right after a `\\`, which reads back with a space in it.
    # A `"#"` key becomes the file's leading comment.
    yaml = value:
      let
        yq = if pkgs.stdenv.hostPlatform.isFreeBSD then pkgs.yq-go.overrideAttrs { nativeBuildInputs = [ ]; postInstall = ""; } else pkgs.yq-go; # its man page needs pandoc, i.e. GHC, which nixpkgs can't bootstrap on FreeBSD
        json = pkgs.writeText "workflow.json" (builtins.toJSON (builtins.removeAttrs value [ "#" ]));
        header = pkgs.lib.optionalString (value ? "#") (pkgs.lib.concatMapStrings (l: if l == "" then "#\n" else "# ${l}\n") (pkgs.lib.splitString "\n" (pkgs.lib.removeSuffix "\n" value."#")));
      in
      pkgs.runCommand "workflow.yml" { nativeBuildInputs = [ yq pkgs.bash ]; } ''
        generated=workflow.yml
        yq -p json -o yaml '(.. style="") | (.. | select(tag == "!!str" and test("\t"))) style="double"' ${json} > $generated # yq writes a tab into a block scalar, which no parser reads
        [ "$(yq -p json -o json -I0 'sort_keys(..)' ${json})" = "$(yq -o json -I0 'sort_keys(..)' $generated)" ] \
          || { echo "v_flakes: a generated workflow doesn't read back as what it was generated from" >&2; exit 1; }
        yq -o json '[(.jobs[].steps[]?, .runs.steps[]?) | select(.run != null and (.shell == null or .shell == "bash")) | .run]' $generated > runs.json
        for i in $(seq 0 $(($(yq -p json 'length' runs.json) - 1))); do
          yq -p json -r ".[$i]" runs.json > run.sh
          bash -n run.sh || { echo "v_flakes: a generated workflow's \`run\` doesn't parse:"; cat run.sh; exit 1; } >&2
        done
        { printf '%s' ${pkgs.lib.escapeShellArg header}; cat $generated; } > $out
      '';

    # The jobs that `rm` `.cargo/config.toml`; the rest read the cfg from it.
    withWebCfg = job:
      if webUnstable then pkgs.lib.recursiveUpdate job { env.RUSTFLAGS = "--cfg web_sys_unstable_apis"; }
      else job;

    files = {
      # shared {{{
      base = ./shared/base.nix;
      loc-badge = ./shared/loc-badge.nix;
      sync-gitlab = ./shared/sync-gitlab.nix;
      cachix = ./shared/cachix.nix;
      asset-gate = ./shared/asset-gate.nix;
      #,}}}

      container-release = ../../container/workflow.nix;
      rust-release = ./rust/release.nix;
      rust-base = ./rust/base.nix;
    };

    # A section's `install`: its nix packages around every `run` (nix-shell), apt ones installed first
    withInstall = installConfig: baseValue:
      let
        installSteps = makeInstallSteps installConfig;
        needsNix = hasNixPackages installConfig;

        # after checkout, before other steps
        valueWithInstall =
          if installSteps != [ ] then
            let
              steps = baseValue.steps;
              checkoutIdx = pkgs.lib.lists.findFirstIndex
                (s: pkgs.lib.hasPrefix "actions/checkout@" (s.uses or ""))
                0
                steps;
              beforeAndCheckout = pkgs.lib.lists.take (checkoutIdx + 1) steps;
              afterCheckout = pkgs.lib.lists.drop (checkoutIdx + 1) steps;
            in
            baseValue // { steps = beforeAndCheckout ++ installSteps ++ afterCheckout; }
          else baseValue;

        # LD_LIBRARY_PATH too: runtime libraries aren't in the default search paths on non-NixOS runners
        packages = installConfig.packages or [ ];
        # Always include openssl.out (runtime libs), openssl.dev (headers), and pkg-config (so openssl-sys finds nix headers, not system ones)
        allPackages = packages ++ [ "pkg-config" "openssl.out" "openssl.dev" ]; #Q: should that include "mold"?
        # git: cargo shells out to it, and the runner's own git can't load under a nix LD_LIBRARY_PATH (nix glibc libs vs system libc)
        pkgList = builtins.concatStringsSep " " (allPackages ++ [ "git" ]);
        ldLibPathSetup = builtins.concatStringsSep "" (map
          (pkg:
            "export LD_LIBRARY_PATH=\\\"\\$(nix-build '<nixpkgs>' -A ${pkg} --no-out-link)/lib\\\${LD_LIBRARY_PATH:+:}\\$LD_LIBRARY_PATH\\\" && "
          )
          allPackages);
        # Escape for embedding in double-quoted nix-shell --command "...", preserving ${{ }} GHA expressions.
        # All four characters bash treats specially inside double quotes have to survive the trip, and
        # the backslash is one of them: a script that already writes \` to escape a backtick for its own
        # shell otherwise arrives with a bare backtick and runs as a command substitution.
        escapeForNixShell = s:
          let
            protected = builtins.replaceStrings [ "\${{" ] [ "__GHA_EXPR__" ] s;
            escaped = builtins.replaceStrings [ "\\" "\"" "$" "`" ] [ "\\\\" "\\\"" "\\$" "\\`" ] protected;
          in
          builtins.replaceStrings [ "__GHA_EXPR__" ] [ "\${{" ] escaped;
        setupSteps = (import ../../cache.nix { inherit cache; }).setupSteps;
        wrapStep = step:
          if builtins.elem step setupSteps then step # runs before Nix is installed
          else if step ? run then
          # skip what is already a nix command, and `echo`s (the timing steps among them)
            if builtins.substring 0 4 step.run == "nix " then step
            else if builtins.substring 0 9 step.run == "nix-shell" then step
            else if builtins.substring 0 5 step.run == "echo " then step
            else step // { run = "nix-shell -p ${pkgList} --command \"set -e; ${ldLibPathSetup}${escapeForNixShell step.run}\""; }
          else step;
        valueWithWrappedRuns =
          if needsNix then
            valueWithInstall // { steps = map wrapStep valueWithInstall.steps; }
          else valueWithInstall;

        existingNeeds = valueWithWrappedRuns.needs or null;
        newNeeds =
          if needsNix && prefetches then
            if existingNeeds == null then "load_nix"
            else if builtins.isList existingNeeds then [ "load_nix" ] ++ existingNeeds
            else [ "load_nix" existingNeeds ]
          else existingNeeds;
      in
      if newNeeds != null
      then valueWithWrappedRuns // { needs = newNeeds; }
      else valueWithWrappedRuns;

    importFile = installConfig: jobSpec:
      let
        jobName = if builtins.isString jobSpec then jobSpec else jobSpec.name;
        jobArgs = if builtins.isString jobSpec then { } else (jobSpec.args or { });
        args =
          if jobName == "loc-badge"
          then { inherit gistId; } // jobArgs
          # installs nix itself rather than going through load_nix, so it needs the repo's cache mode
          else if jobName == "asset-gate"
          then { inherit cache; preCi = rustRepo; } // jobArgs
          else jobArgs;
        imported = import (builtins.getAttr jobName files);
      in
      {
        name = jobName;
        value = withInstall installConfig (if builtins.isFunction imported then imported args else imported);
      };

    constructJobs = installConfig: paths:
      builtins.listToAttrs (map (importFile installConfig) paths);

    defaultHooks = utils.defaultHooks;

    # Build the `on` attrset for a workflow.
    # workflow_dispatch is always injected unless the caller already set it explicitly.
    makeOn = hooksOverride:
      let base = if hooksOverride != null then hooksOverride else defaultHooks;
      in if base ? workflow_dispatch then base
      else base // { workflow_dispatch = { }; };

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
    releaseCargoTomlPath = release.cargoTomlPath or (if cargoRoot == "." then "Cargo.toml" else "${cargoRoot}/Cargo.toml");

    # Per-target release workflows (one file per target)
    releaseWorkflows =
      if releaseEnabled then
        let
          releaseArgs = builtins.removeAttrs release [ "enable" "cargoTomlPath" ];
          spec = import files.rust-release (releaseArgs // { inherit gistId; sizeBadge = publishCachix == null; });
        in
        builtins.mapAttrs
          (name: wf:
            yaml (builtins.removeAttrs (wf // { jobs = wf.jobs // { build = withWebCfg (inCargoRoot wf.jobs.build); }; }) [ "standalone" "filename" "default" ])
          )
          spec.workflows
      else { };

    # Opt-in via `github { containerRelease = { registry = "ghcr.io/ev-invest"; }; }`.
    containerReleaseWorkflow =
      if containerRelease != null then
      # Unknown keys must fail loudly: an option this version doesn't know (or a typo)
      # would otherwise silently vanish from the generated workflow.
        assert (
          let unknown = builtins.removeAttrs containerRelease [ "registry" "deployKeys" "impure" "refresh" "buildTiming" "lfs" ]; in
          unknown == { } || throw "v_flakes containerRelease: unknown keys ${builtins.toJSON (builtins.attrNames unknown)}"
        );
        yaml (builtins.removeAttrs
          (import files.container-release { inherit (pkgs) lib; inherit cache; registry = pkgs.lib.toLower containerRelease.registry; deployKeys = containerRelease.deployKeys or [ ]; impure = containerRelease.impure or false; refresh = containerRelease.refresh or false; buildTiming = containerRelease.buildTiming or false; lfs = containerRelease.lfs or true; })
          [ "standalone" "filename" ])
      else null;

    npmReleaseWorkflow =
      if npmRelease != null then
        assert (
          let unknown = builtins.removeAttrs npmRelease [ "scope" "packagesDir" ]; in
          unknown == { } || throw "v_flakes npmRelease: unknown keys ${builtins.toJSON (builtins.attrNames unknown)}"
        );
        yaml (builtins.removeAttrs (import ./shared/npm-release.nix { inherit (npmRelease) scope packagesDir; }) [ "standalone" ])
      else null;

    visualBaselinesWorkflow =
      if visualBaselines != null then
        assert (
          let unknown = builtins.removeAttrs visualBaselines [ "dir" "render" "gate" "paths" "rustCache" ]; in
          unknown == { } || throw "v_flakes visualBaselines: unknown keys ${builtins.toJSON (builtins.attrNames unknown)}"
        );
        yaml (builtins.removeAttrs (import ./shared/visual-baselines.nix (visualBaselines // { inherit lfs; cachix = cache ? cachix; })) [ "standalone" ])
      else null;

    figmaWorkflow =
      if figma != null && figma.on == "gha" then
        yaml (builtins.removeAttrs (import ./shared/figma.nix ((builtins.removeAttrs figma [ "on" ]) // { inherit lfs cache; })) [ "standalone" ])
      else null;

    typstReleaseWorkflow =
      if typstRelease != null then
        yaml (builtins.removeAttrs (import ./shared/release-typst.nix { inherit (typstRelease) html; inherit lfs cache; }) [ "standalone" ])
      else null;

    nixEnvAction = yaml (import ./shared/nix-env-action.nix { inherit cache; });

    skillsWorkflow =
      if skills != null then
        assert (
          let unknown = builtins.removeAttrs skills [ "skargo" ]; in
          unknown == { } || throw "v_flakes skills: unknown keys ${builtins.toJSON (builtins.attrNames unknown)}"
        );
        yaml (builtins.removeAttrs (import ./shared/skills.nix { inherit (skills) skargo; inherit cache; }) [ "standalone" ])
      else null;

    cachixWorkflow =
      if publishCachix != null then
        yaml
          (builtins.removeAttrs
            (import files.cachix ({ inherit gistId; } // (if builtins.isString publishCachix then { name = publishCachix; } else publishCachix))) [ "standalone" ])
      else null;

    # Sync fork workflow (rebase over upstream)
    syncForkWorkflow =
      if syncFork then
        let
          syncSpec = import ./shared/sync-fork.nix;
        in
        yaml (builtins.removeAttrs syncSpec [ "standalone" ])
      else null;

    # Claude Code workflows (standalone, generic). Generated as a pair when `claude` is set.
    claudeWorkflow =
      if claude then
        yaml (builtins.removeAttrs (import ./shared/claude.nix) [ "standalone" "label" ])
      else null;
    claudeReviewWorkflow =
      if claude then
        yaml (builtins.removeAttrs (import ./shared/claude-review.nix) [ "standalone" ])
      else null;

    # GitLab sync workflow (triggers on any push)
    stripTrailingSlash = s:
      let len = builtins.stringLength s;
      in if len > 0 && builtins.substring (len - 1) 1 s == "/"
      then builtins.substring 0 (len - 1) s
      else s;
    gitlabSyncWorkflow =
      if gitlabSync != null then
        let
          syncSpec = import files.sync-gitlab (stripTrailingSlash gitlabSync.mirrorBaseUrl);
        in
        yaml (builtins.removeAttrs syncSpec [ "standalone" ])
      else null;

    # Generate load_nix job for a section if it has packages
    loadNixJob = installConfig:
      let
        wf = makeLoadNixWorkflow installConfig;
      in
      if wf != null then wf.jobs else { };

    # A section's particles, a job each: a `ci` body's own, or `nix run .#test` over that particle's own lean cache; and on the default branch a `report` job writing the section's
    # badge from their outcomes and their own run seconds (setup, nix install and cache restore left out).
    particleWorkflow = { title, severity, particles, installConfig, hooks }:
      let
        lib = pkgs.lib;
        nixCi = import ../../cache.nix { inherit cache; };
        bespoke = builtins.filter (p: p.ci != null) particles;
        generic = builtins.filter (p: p.ci == null) particles;
        # outside `jobs`: the report tallies every push's, and these are skipped on all but release tags
        releaseJobs = builtins.listToAttrs (map
          (p: { name = "${p.name}-release"; value = withInstall installConfig (p.release.job // { steps = p.release.job.steps ++ p.release.work; }); })
          (builtins.filter (p: p.release != null) particles));

        bespokeJob = p: withInstall installConfig (p.ci.job // {
          outputs = (p.ci.job.outputs or { }) // { seconds = "\${{ steps.particle.outputs.seconds }}"; };
          steps = p.ci.job.steps
            ++ [{ run = "echo \"T_PARTICLE=$(date +%s)\" >> \"$GITHUB_ENV\""; }]
            ++ p.ci.work
            ++ [{
            id = "particle";
            "if" = if p.ci.timedIf or null == null then "always()" else "always() && (${p.ci.timedIf})";
            run = "echo \"seconds=$((T_PARTICLE ? $(date +%s) - T_PARTICLE : 0))\" >> \"$GITHUB_OUTPUT\""; # unset when setup failed first
          }]
            ++ (p.ci.post or [ ]);
        });

        checkout = { uses = "actions/checkout@v5"; } // lib.optionalAttrs lfs { "with".lfs = true; };
        # Every ref reads the default branch's, so only it saves: after the run, failed or not, on a miss, then drops the entry it
        # replaces (one per cache). flake.lock in the key: the toolchains come from it; in the prefix too unless a `sweep` bounds what a
        # rolled-forward entry gathers, so a lock bump restores the last entry instead of starting empty.
        ciCaches = p: lib.imap0
          (i: c:
            let
              family = "particles-${severity}-${p.name}-${toString i}-\${{ runner.os }}-";
              prefix = "${family}\${{ hashFiles('flake.lock') }}-";
              id = "particle-cache-${toString i}";
              path = lib.concatStringsSep "\n" c.paths;
              ifMiss = "always() && github.ref_name == github.event.repository.default_branch && steps.${id}.outputs.cache-hit != 'true'";
            in
            {
              restore = { inherit id; name = "Restore particle's cache"; uses = "actions/cache/restore@v5"; "with" = { inherit path; key = "${prefix}\${{ hashFiles(${lib.concatMapStringsSep ", " (f: "'${f}'") c.hashFiles}) }}"; restore-keys = if c ? sweep then family else prefix; }; };
              stamp = lib.optional (c ? stamp) { name = "Stamp particle's cache"; "if" = ifMiss; shell = "bash"; run = c.stamp; };
              save = lib.optional (c ? sweep) { name = "Sweep particle's cache"; "if" = ifMiss; shell = "bash"; run = c.sweep; } ++ [
                { name = "Save particle's cache"; "if" = ifMiss; uses = "actions/cache/save@v5"; "with" = { inherit path; key = "\${{ steps.${id}.outputs.cache-primary-key }}"; }; }
                {
                  name = "Drop particle's older caches";
                  "if" = ifMiss;
                  env = { GH_TOKEN = "\${{ github.token }}"; FAMILY = family; KEY = "\${{ steps.${id}.outputs.cache-primary-key }}"; };
                  # only once the new entry is listed: a save that found none of its paths saved nothing
                  run = ''gh cache list -R "$GITHUB_REPOSITORY" -L 100 --key "$FAMILY" --json id,key -q 'if any(.[]; .key == $ENV.KEY) then .[] | select(.key != $ENV.KEY) | .id else empty end' | xargs -r -n1 gh cache delete -R "$GITHUB_REPOSITORY"'';
                }
              ];
            })
          p.ciCache;
        genericJob = p:
          let lean = nixCi.scopedCache "particle-${p.name}"; caches = ciCaches p; in {
            inherit (p) name;
            runs-on = "ubuntu-latest";
            timeout-minutes = 90;
            outputs = builtins.listToAttrs (map (o: { name = o; value = "\${{ steps.run.outputs['${p.name}_${o}'] }}"; })
              ([ "seconds" ] ++ lib.optional (p.prepare != null) "prepare_seconds"));
            steps = [ checkout ]
              ++ nixCi.setupSteps
              ++ [ nixCi.installStep ]
              ++ (if nixCi.leanDir != null then [ lean.restore ] else nixCi.cacheSteps)
              ++ [ nixCi.evalCache.restore ]
              ++ map (c: c.restore) caches
              ++ lib.concatMap (c: c.stamp) caches
              ++ [{ id = "run"; run = "nix run .#test -- --severity ${severity} ${lib.escapeShellArg p.name}"; }]
              ++ lib.concatMap (c: c.save) caches
              ++ [ nixCi.evalCache.save ]
              ++ lib.optionals (nixCi.leanDir != null) lean.save;
          } // lib.optionalAttrs (caches != [ ] || nixCi.leanDir != null) { permissions = (import files.base).permissions // { actions = "write"; }; }; # dropping older caches

        jobs = builtins.listToAttrs
          (map (p: { inherit (p) name; value = bespokeJob p; }) bespoke
            ++ map (p: { inherit (p) name; value = genericJob p; }) generic);
        needingPreCi = js: builtins.any (j: builtins.elem "pre_ci" (lib.toList (j.needs or [ ]))) (builtins.attrValues js);
        needsPreCi = needingPreCi (jobs // releaseJobs);

        timed = lib.concatMap (p: lib.mapAttrsToList (key: output: { inherit key output; particle = p.name; }) p.badges) particles;
        timedVar = t: "BADGE_${lib.toUpper t.key}";

        report = {
          name = "Report";
          needs = builtins.attrNames jobs;
          "if" = "always() && github.ref_name == github.event.repository.default_branch";
          runs-on = "ubuntu-latest";
          steps = [{
            name = "Tally the particles";
            env = {
              NEEDS = "\${{ toJSON(needs) }}";
              PARTICLES = builtins.toJSON (map (p: p.name) particles);
              TIMED = builtins.toJSON timed;
            };
            run = ''
              read -r failed total seconds incomplete < <(jq -rn --argjson needs "$NEEDS" --argjson spec "$PARTICLES" '
                def secs: if . == null or . == "" then 0 else tonumber end;
                [ $spec[] | $needs[.] as $j | { ok: ($j.result == "success"), t: ($j.outputs.seconds | secs), r: $j.result } ]
                | "\(map(select(.ok | not)) | length) \(length) \(map(.t) | add) \(map(select(.r == "skipped" or .r == "cancelled")) | length)"')
              if [ "$incomplete" != 0 ]; then
                echo "::notice::a particle's job was skipped or cancelled: the badge keeps its last complete run"
                exit 0
              fi
              # only a succeeded job's numbers: a failed run's are partial
              jq -rn --argjson needs "$NEEDS" --argjson timed "$TIMED" '
                $timed[] | select($needs[.particle].result == "success")
                | ($needs[.particle].outputs[.output] | tonumber) as $s
                | "BADGE_\(.key | ascii_upcase)=\($s / 60 | floor)m \($s % 60)s"' >> "$GITHUB_ENV"
              time="$((seconds / 60))m $((seconds % 60))s"
              if [ "$failed" = 0 ]; then msg="✓ $time" color=brightgreen; else msg="✗ $((total - failed))/$total · $time" color=red; fi
              { echo "BADGE_MESSAGE=$msg"; echo "BADGE_COLOR=$color"; } >> "$GITHUB_ENV"
            '';
          }] ++ import ./shared/gist-badges.nix {
            inherit gistId;
            condition = "env.BADGE_MESSAGE != ''";
            badges.${severity} = {
              label = severity;
              message = "$BADGE_MESSAGE";
              color = "$BADGE_COLOR";
              labelColor = { errors = "420d09"; warnings = "d16002"; }.${severity};
            };
          } ++ lib.optionals (timed != [ ]) (import ./shared/gist-badges.nix {
            inherit gistId;
            condition = lib.concatMapStringsSep " && " (t: "env.${timedVar t} != ''") timed;
            badges = builtins.listToAttrs (map (t: { name = t.key; value = { label = t.key; message = "$" + timedVar t; }; }) timed);
          });
        };
      in
      if particles == [ ] then null else
      yaml {
        name = title;
        "on" = makeOn hooks;
        permissions = (import files.base).permissions;
        env = (import files.rust-base).env;
        jobs = lib.optionalAttrs needsPreCi { pre_ci = (import files.rust-base).jobs.pre_ci // lib.optionalAttrs (!needingPreCi jobs) { "if" = "startsWith(github.ref, 'refs/tags/v')"; }; }
          // lib.optionalAttrs (bespoke != [ ]) (loadNixJob installConfig)
          // jobs
          // releaseJobs
          // { inherit report; };
      };

    workflows = {
      errors = particleWorkflow { title = "Errors"; severity = "errors"; particles = particlesErrors; installConfig = installErrors; hooks = hooksErrors; };
      warnings = particleWorkflow { title = "Warnings"; severity = "warnings"; particles = particlesWarnings; installConfig = installWarnings; hooks = hooksWarnings; };

      other =
        if jobsOther != [ ] then
          yaml
            (
              pkgs.lib.recursiveUpdate base {
                name = "Other";
                "on" = makeOn hooksOther;
                permissions = (import files.base).permissions;
                jobs =
                  let
                    own = pkgs.lib.recursiveUpdate (loadNixJob installOther) (constructJobs installOther jobsOther);
                    needsPreCi = builtins.any (j: (j.needs or null) == "pre_ci") (builtins.attrValues own);
                  in
                  (if needsPreCi then { inherit ((import files.rust-base).jobs) pre_ci; } else { }) // own;
              }
            ) else null;
    };

    ensureBinstallScript = ../../ensure-binstall-metadata.rs;

    releaseExpectedFiles = map (name: "release-${name}.yml") (builtins.attrNames releaseWorkflows)
      ++ pkgs.lib.optional (containerReleaseWorkflow != null) "release-container.yml"
      ++ pkgs.lib.optional (npmReleaseWorkflow != null) "release-npm.yml"
      ++ pkgs.lib.optional (typstReleaseWorkflow != null) "release-typst.yml";

    releaseHook =
      if releaseWorkflows != { } then
        let
          copyCommands = builtins.concatStringsSep "\n" (
            pkgs.lib.mapAttrsToList
              (name: wf: ''
                _vf_cp ${wf} ./.github/workflows/release-${name}.yml
              '')
              releaseWorkflows
          );
        in
        ''
          ${copyCommands}
          _vf_fresh binstall-metadata "${ensureBinstallScript}" ${releaseCargoTomlPath} || { ${cargoNightly} -Zscript -q ${ensureBinstallScript} ${releaseCargoTomlPath} && _vf_stamp binstall-metadata "${ensureBinstallScript}" ${releaseCargoTomlPath}; }
        ''
      else "";

    # Warn about stale files containing "release" in .github/workflows/ that we don't generate
    releaseStaleWarningHook =
      if releaseEnabled then
        let
          expectedBash = builtins.concatStringsSep " " (map (f: ''"${f}"'') releaseExpectedFiles);
        in
        ''
          _release_stale=()
          for f in ./.github/workflows/*release*; do
            [ -e "$f" ] || continue
            _base="''${f##*/}"
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

    containerReleaseHook =
      if containerReleaseWorkflow != null then ''
        _vf_cp ${containerReleaseWorkflow} ./.github/workflows/release-container.yml
      '' else "";

    npmReleaseHook =
      if npmReleaseWorkflow != null then ''
        _vf_cp ${npmReleaseWorkflow} ./.github/workflows/release-npm.yml
      '' else "";

    visualBaselinesHook =
      if visualBaselinesWorkflow != null then ''
        _vf_cp ${visualBaselinesWorkflow} ./.github/workflows/visual-baselines.yml
      '' else "";

    figmaHook =
      if figmaWorkflow != null then ''
        _vf_cp ${figmaWorkflow} ./.github/workflows/figma.yml
      '' else ''
        [ -e ./.github/workflows/figma.yml ] && rm -f ./.github/workflows/figma.yml && echo "v_flakes: removed .github/workflows/figma.yml, figma.on is not \"gha\"" >&2
      '';

    typstReleaseHook =
      if typstReleaseWorkflow != null then ''
        _vf_cp ${typstReleaseWorkflow} ./.github/workflows/release-typst.yml
      '' else "";

    skillsHook =
      if skillsWorkflow != null then ''
        _vf_cp ${skillsWorkflow} ./.github/workflows/skills.yml
      '' else "";

    cachixHook =
      if cachixWorkflow != null then ''
        _vf_cp ${cachixWorkflow} ./.github/workflows/cachix.yml
      '' else "";

    syncForkHook =
      if syncForkWorkflow != null then ''
        _vf_cp ${syncForkWorkflow} ./.github/workflows/sync_fork.yml
      '' else "";

    gitlabSyncHook =
      if gitlabSyncWorkflow != null then ''
        _vf_cp ${gitlabSyncWorkflow} ./.github/workflows/sync_gitlab.yml
      '' else "";

    claudeHook =
      if claudeWorkflow != null then ''
        _vf_cp ${claudeWorkflow} ./.github/workflows/claude.yml
        _vf_cp ${claudeReviewWorkflow} ./.github/workflows/claude-code-review.yml
      '' else "";

    # these names are ours: one no longer configured is a stale leftover of an earlier generation
    jobsHook = name:
      let path = "./.github/workflows/${name}.yml"; in
      if workflows.${name} != null then ''
        _vf_cp ${workflows.${name}} ${path}
      '' else ''
        [ -e ${path} ] && rm -f ${path} && echo "v_flakes: removed ${path}, no ${name} jobs are configured" >&2
      '';
  in
  workflows // {
    inherit releaseWorkflows containerReleaseWorkflow npmReleaseWorkflow visualBaselinesWorkflow figmaWorkflow typstReleaseWorkflow nixEnvAction skillsWorkflow gitlabSyncWorkflow syncForkWorkflow claudeWorkflow claudeReviewWorkflow cachixWorkflow;
    shellHook = utils.mkShellHook ''
      [ -d ./.github/workflows ] || mkdir -p ./.github/workflows
      ${jobsHook "errors"}
      ${jobsHook "warnings"}
      ${jobsHook "other"}
      ${releaseHook}
      ${releaseStaleWarningHook}
      ${containerReleaseHook}
      ${npmReleaseHook}
      ${visualBaselinesHook}
      ${figmaHook}
      ${typstReleaseHook}
      ${skillsHook}
      ${syncForkHook}
      ${gitlabSyncHook}
      ${claudeHook}
      ${cachixHook}
    '';
  }
