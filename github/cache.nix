# Nix install + binary-cache steps for generated workflows that use the nix env.
# `cache` selects exactly one mechanism:
#   { nix-action = true; }  → nix-community/cache-nix-action — private GH-Actions cache,
#                             free, safe for private repos (default). Tarballs the WHOLE
#                             /nix/store (~5 GB, incl. paths already on cache.nixos.org) →
#                             thrash-evicts against the 10 GB repo limit on churny keys.
#   { lean = true; }        → cache ONLY paths built locally (i.e. NOT on cache.nixos.org).
#                             A post-build-hook copies each freshly-built path into a
#                             file:// binary cache; actions/cache persists just that
#                             (~1 GB: rust-overlay toolchain + your own outputs). Everything
#                             substitutable is re-fetched from cache.nixos.org — faster than
#                             a GH-cache restore — and never counts against the 10 GB limit.
#                             Private, free, no external service.
#   { cachix = "<name>"; }  → cachix/cachix-action — public/org cache; pushing needs the
#                             CACHIX_AUTH_TOKEN secret. Use only for PUBLIC repos: a public
#                             cache publishes every pushed path.
#
# installStep pins lazy-trees so generated CI agrees with the lazy-trees flake.lock a
# Determinate dev produces — otherwise private git inputs NAR-mismatch (the whole reason
# combine.determinate_nix exists).
#
# Consumers MUST splice `setupSteps` (possibly empty) in BEFORE installStep — lean writes
# its post-build-hook + cache dir there; the other modes leave it empty (a no-op).
{ cache ? { nix-action = true; } }:
let
  hasCachix = cache ? cachix;
  hasLean = (cache.lean or false) != false;
  hasNixAction = (cache.nix-action or false) != false;
  modeCount = (if hasCachix then 1 else 0) + (if hasLean then 1 else 0) + (if hasNixAction then 1 else 0);

  # Lean file:// binary cache lives in /tmp: the post-build-hook runs as the nix daemon
  # (root) and writes here; actions/cache (runner user) reads it back — a 0777 dir plus
  # nix's world-readable cache files bridge the uid gap. require-sigs=false since we don't
  # sign this ephemeral local cache.
  leanDir = "/tmp/nix-lean-cache";
  leanHook = "/tmp/nix-lean-pbh.sh";
  leanSetupStep = {
    name = "Lean cache setup";
    shell = "bash";
    # post-build-hook fires per locally-built derivation with $OUT_PATHS — copy those
    # (and only those; substitutable paths are never "built") into the file cache.
    # `|| true`: a cache-copy hiccup must never fail a release build.
    run = ''
      mkdir -p ${leanDir}
      chmod 0777 ${leanDir}
      printf '#!/bin/sh\nexport PATH=/nix/var/nix/profiles/default/bin:$PATH\nnix copy --to "file://${leanDir}?compression=zstd&parallel-compression=true" $OUT_PATHS || true\n' > ${leanHook}
      chmod 0755 ${leanHook}
    '';
  };
in
assert (modeCount == 1) || throw
  "v_flakes cache: set exactly one of `cache.nix-action = true`, `cache.lean = true`, or `cache.cachix = \"<name>\"`";
{
  installStep = {
    name = "Install Nix";
    uses = "DeterminateSystems/nix-installer-action@main";
    "with".extra-conf =
      if hasLean then ''
        lazy-trees = true
        post-build-hook = ${leanHook}
        extra-substituters = file://${leanDir}
        extra-trusted-substituters = file://${leanDir}
        require-sigs = false
      '' else "lazy-trees = true";
  };

  setupSteps = if hasLean then [ leanSetupStep ] else [ ];

  cacheStep =
    if hasCachix then {
      name = "Setup Cachix";
      uses = "cachix/cachix-action@v15";
      "with" = {
        name = cache.cachix;
        authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
      };
    } else if hasLean then {
      name = "Lean nix cache (built-only paths)";
      uses = "actions/cache@v4";
      "with" = {
        path = leanDir;
        key = "nix-lean-\${{ runner.os }}-\${{ github.run_id }}";
        restore-keys = "nix-lean-\${{ runner.os }}-";
      };
    } else {
      name = "Setup Nix cache";
      uses = "nix-community/cache-nix-action@v7";
      "with" = {
        primary-key = "nix-\${{ runner.os }}-\${{ hashFiles('**/flake.lock') }}";
        restore-prefixes-first-match = "nix-\${{ runner.os }}-";
      };
    };

  # Split restore/save, for tag-triggered workflows: GitHub scopes caches per ref, so a
  # tag run can't read another tag's cache — only its own ref or the default branch. So
  # restore always (this picks up the default-branch cache), but save ONLY on `main`
  # (a tag-scoped save is unshareable and would evict main's). null unless lean.
  cacheRestoreStep = if hasLean then {
    name = "Restore lean nix cache";
    uses = "actions/cache/restore@v4";
    "with" = {
      path = leanDir;
      key = "nix-lean-\${{ runner.os }}-\${{ github.run_id }}";
      restore-keys = "nix-lean-\${{ runner.os }}-";
    };
  } else null;
  cacheSaveStep = if hasLean then {
    name = "Save lean nix cache";
    "if" = "github.ref == 'refs/heads/main'";
    uses = "actions/cache/save@v4";
    "with" = {
      path = leanDir;
      key = "nix-lean-\${{ runner.os }}-\${{ github.run_id }}";
    };
  } else null;
}
