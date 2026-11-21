# Nix install + binary-cache steps for generated workflows that use the nix env.
#
# THE DEFAULT LIVES HERE AND NOWHERE ELSE. Every other module takes `cache ? { }` and
# threads it down; an unset `cache` resolves to lean right here. Repeating a literal
# default in each caller is how `asset-gate` spent its life ignoring the repo's setting.
#
# `cache` selects at most one mechanism:
#   unset / { lean = true; } → cache ONLY paths built locally (i.e. NOT on cache.nixos.org).
#                             A post-build-hook copies each freshly-built path into a
#                             file:// binary cache; actions/cache persists just that
#                             (your own outputs; a toolchain valeratrades.cachix lacks). Everything
#                             substitutable is re-fetched from cache.nixos.org or valeratrades.cachix — faster than
#                             a GH-cache restore — and never counts against the 10 GB limit.
#                             Private, free, no external service. The default because it is
#                             the only mode that stays inside the budget on a nix-heavy
#                             closure, and the one nobody has to know to ask for.
#   { nix-action = true; }  → nix-community/cache-nix-action — private GH-Actions cache,
#                             free, safe for private repos. Tarballs the WHOLE /nix/store
#                             (~5 GB, incl. paths already on cache.nixos.org) →
#                             thrash-evicts against the 10 GB repo limit on churny keys.
#                             Worth it only when substituter round-trips dominate and the
#                             closure is small enough to fit with room to spare.
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
{ cache ? { } }:
let
  hasCachix = cache ? cachix;
  leanRequested = (cache.lean or false) != false;
  hasNixAction = (cache.nix-action or false) != false;
  modeCount = (if hasCachix then 1 else 0) + (if leanRequested then 1 else 0) + (if hasNixAction then 1 else 0);
  hasLean = leanRequested || modeCount == 0;

  # Lean file:// binary cache lives in /tmp: the post-build-hook runs as the nix daemon
  # (root) and writes here; actions/cache (runner user) reads it back — a 0777 dir plus
  # nix's world-readable cache files bridge the uid gap. require-sigs=false since we don't
  # sign this ephemeral local cache.
  upstream = "https://valeratrades.cachix.org";
  leanDir = "/tmp/nix-lean-cache";
  leanHook = "/tmp/nix-lean-pbh.sh";
  leanSetupStep = {
    name = "Lean cache setup";
    shell = "bash";
    # post-build-hook fires per locally-built derivation with $OUT_PATHS: copied with their closure, as a binary cache takes no path
    # without its references, and listed in `built`, for a scoped cache to keep them alone.
    # `|| true`: a cache-copy hiccup must never fail a release build.
    run = ''
      mkdir -p ${leanDir}
      chmod 0777 ${leanDir}
      printf '#!/bin/sh\nexport PATH=/nix/var/nix/profiles/default/bin:$PATH\necho $OUT_PATHS >> ${leanDir}/built\nnix copy --to "file://${leanDir}?compression=zstd&parallel-compression=true" $OUT_PATHS || true\n' > ${leanHook}
      chmod 0755 ${leanHook}
    '';
  };
  leanPrune = {
    name = "Prune lean nix cache to what this run used";
    shell = "bash";
    # what was built, and what of it this run needed (substitution is lazy: a restored path never asked for isn't valid); a narinfo's
    # references are fetched from the other substituters, as a cache read doesn't need its closure
    run = ''
      cd ${leanDir}
      shopt -s nullglob
      narinfos=(*.narinfo)
      ((''${#narinfos[@]})) || exit 0
      [ -e built ] || : > built
      sed -n 's/^StorePath: //p' "''${narinfos[@]}" | sort -u > /tmp/lean-all
      tr -s ' ' '\n' < built | sed '/^$/d' | sort -u | comm -12 - /tmp/lean-all > /tmp/lean-built
      xargs -r nix-store --check-validity --print-invalid < /tmp/lean-built | sort -u | comm -23 /tmp/lean-built - > /tmp/lean-keep
      comm -23 /tmp/lean-all /tmp/lean-keep | while read -r p; do
        n=$(basename "$p") && n=''${n%%-*}.narinfo
        echo "$n" && sed -n 's/^URL: //p' "$n"
      done | sudo xargs -r rm -f
      sudo rm -f built && cp /tmp/lean-keep built
    '';
  };

in
assert (modeCount <= 1) || throw
  "v_flakes cache: set at most one of `cache.nix-action = true`, `cache.lean = true`, or `cache.cachix = \"<name>\"` (unset = lean)";
{
  installStep = {
    name = "Install Nix";
    uses = "DeterminateSystems/nix-installer-action@main";
    # valeratrades.cachix: the canonical toolchains, which are built (assembled from rust-overlay's components) rather than on
    # cache.nixos.org, so lean would otherwise carry one per particle
    "with".extra-conf = ''
      lazy-trees = true
      extra-substituters = ${upstream}${if hasLean then " file://${leanDir}" else ""}
      extra-trusted-public-keys = valeratrades.cachix.org-1:gXVwhzO5YB+BaiEJYT48qZgzdaErGQew6xtZcz4Fo1Q=
    '' + (if hasLean then ''
      post-build-hook = ${leanHook}
      extra-trusted-substituters = file://${leanDir}
      require-sigs = false
    '' else "");
  };

  setupSteps = if hasLean then [ leanSetupStep ] else [ ];
  leanDir = if hasLean then leanDir else null;

  # Lean only: `scope`'s own cache, which a lock bump doesn't empty (self-pinned paths survive it): the newest of any
  # lock is restored. `save` goes last, failed job or not: it prunes to what this run used, then saves.
  scopedCache = scope:
    assert hasLean;
    let
      prefix = "nix-lean3-${scope}-\${{ runner.os }}-"; # 3: earlier entries held the built paths' whole closures
      # not per run: each save is a new entry, which evicts other caches from the 10 GB budget.
      # A non-nix input changing (a script a particle wraps) only rebuilds that trivial derivation.
      key = "${prefix}\${{ hashFiles('flake.lock') }}-\${{ hashFiles('**/*.nix') }}";
      onDefault = "always() && github.ref_name == github.event.repository.default_branch"; # every ref reads the default branch's
    in
    {
      restore = { id = "lean-restore"; name = "Restore lean nix cache"; uses = "actions/cache/restore@v5"; "with" = { path = leanDir; inherit key; restore-keys = "${prefix}\${{ hashFiles('flake.lock') }}-\n${prefix}"; }; };
      # the job needs `actions: write` for the drop
      save = let ifMiss = "${onDefault} && steps.lean-restore.outputs.cache-hit != 'true'"; in [
        (leanPrune // { "if" = ifMiss; })
        { name = "Save lean nix cache"; "if" = ifMiss; uses = "actions/cache/save@v5"; "with" = { path = leanDir; inherit key; }; }
        {
          name = "Drop older lean nix caches";
          "if" = ifMiss;
          env = { GH_TOKEN = "\${{ github.token }}"; FAMILY = prefix; KEY = "\${{ steps.lean-restore.outputs.cache-primary-key }}"; };
          # only once the new entry is listed: a save that found nothing saved nothing
          run = ''gh cache list -R "$GITHUB_REPOSITORY" -L 100 --key "$FAMILY" --json id,key -q 'if any(.[]; .key == $ENV.KEY) then .[] | select(.key != $ENV.KEY) | .id else empty end' | xargs -r -n1 gh cache delete -R "$GITHUB_REPOSITORY"'';
        }
      ];
    };
  # the flake inputs' tarball cache, which `nix run .#flake` otherwise unpacks anew; the job needs `actions: write` for the drop
  evalCache =
    let
      prefix = "nix-eval2-\${{ runner.os }}-"; # 2: earlier entries lacked what cache.nixos.org has
      key = "${prefix}\${{ hashFiles('flake.lock') }}";
      ifMiss = "always() && steps.eval-cache.outputs.cache-hit != 'true' && github.ref_name == github.event.repository.default_branch";
    in
    {
      restore = { id = "eval-cache"; name = "Restore nix eval cache"; uses = "actions/cache/restore@v5"; "with" = { path = "~/.cache/nix"; inherit key; }; };
      save = [
        {
          # an input cache.nixos.org has (nixpkgs) is substituted unless the tarball cache holds it, and substituting never puts
          # it there: fetched into an empty store, substituters off, every input lands in it
          name = "Fetch the flake's inputs into the tarball cache";
          "if" = ifMiss;
          run = ''nix flake archive --store "$RUNNER_TEMP/inputs" --option substitute false > /dev/null && chmod -R u+w "$RUNNER_TEMP/inputs" && rm -rf "$RUNNER_TEMP/inputs"'';
        }
        { name = "Save nix eval cache"; "if" = ifMiss; uses = "actions/cache/save@v5"; "with" = { path = "~/.cache/nix"; inherit key; }; }
        {
          name = "Drop older nix eval caches";
          "if" = ifMiss;
          env = { GH_TOKEN = "\${{ github.token }}"; FAMILY = prefix; KEY = "\${{ steps.eval-cache.outputs.cache-primary-key }}"; };
          run = ''gh cache list -R "$GITHUB_REPOSITORY" -L 100 --key "$FAMILY" --json id,key -q 'if any(.[]; .key == $ENV.KEY) then .[] | select(.key != $ENV.KEY) | .id else empty end' | xargs -r -n1 gh cache delete -R "$GITHUB_REPOSITORY"'';
        }
      ];
    };

  cacheSteps =
    if hasCachix then [{
      name = "Setup Cachix";
      uses = "cachix/cachix-action@v17";
      "with" = {
        name = cache.cachix;
        authToken = "\${{ secrets.CACHIX_AUTH_TOKEN }}";
      };
    }] else if hasLean then
      let
        # Keyed on the lock: a save restores, adds to and saves again, so without it a toolchain the lock dropped is carried forever.
        prefix = "nix-lean-\${{ runner.os }}-\${{ hashFiles('flake.lock') }}-";
        cacheWith = {
          path = leanDir;
          key = "${prefix}\${{ github.run_id }}";
          restore-keys = prefix;
        };
      in
      [
        # GitHub scopes caches per ref and lets every ref read the default branch's: anywhere else, a save would only spend the 10 GB budget.
        {
          name = "Restore lean nix cache";
          "if" = "github.ref_name != github.event.repository.default_branch";
          uses = "actions/cache/restore@v5";
          "with" = cacheWith;
        }
        {
          name = "Lean nix cache (built-only paths)";
          "if" = "github.ref_name == github.event.repository.default_branch"; # its post step saves
          uses = "actions/cache@v5";
          "with" = cacheWith;
        }
      ]
    else [{
      name = "Setup Nix cache";
      uses = "nix-community/cache-nix-action@v7";
      "with" = {
        primary-key = "nix-\${{ runner.os }}-\${{ hashFiles('**/flake.lock') }}";
        restore-prefixes-first-match = "nix-\${{ runner.os }}-";
      };
    }];
}
