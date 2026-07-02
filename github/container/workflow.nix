# Tag-driven, versioned-only push of every `#containers.<system>.<name>` to GHCR
# (aarch64). The repo's container set is enumerated at build time, so adding a
# container needs no workflow change.
#
# deployKeys: "<owner>/<repo>" list of private repos the build pulls as flake inputs
# (URLs stay plain `git+ssh://git@github.com/<owner>/<repo>` so local builds just use the
# dev's own key). A key can be a deploy key on only one repo, so per repo we write its
# read-only key, an ssh alias `gh-<repo>` selecting it (IdentitiesOnly), and a git
# `insteadOf` rewrite steering only that repo's plain github.com URL to the alias — all
# CI-only. Provision each with `git_ops init-deploy-key <owner>/<repo>`. Empty = no step.
#
# impure: add `--impure` (and `--refresh`) to the container build/eval. Needed when
# the flake pulls sources via `builtins.getFlake "…?ref=main"` (unlocked, no narHash)
# instead of flake inputs — the way to keep private content repos off flake.lock
# entirely. `--refresh` re-resolves those mutable refs every build so a release always
# bakes the latest `main`; locked inputs (nixpkgs/rust) are content-pinned and untouched.
#
# buildTiming: build verbose (-L) and pipe stderr through a gawk filter that, at
# the end, prints an ASCII bar chart of when each component (rust toolchain/deps,
# backend, wasm, docs, npm/next, packaging) was active — a per-release profile.
{ registry, deployKeys ? [], lib, cache ? { nix-action = true; }, impure ? false, buildTiming ? false }:
let
  nixCi = import ../cache.nix { inherit cache; };
  # Lean cache can't be shared between tag runs (GitHub scopes caches per ref). So under
  # lean we ALSO build on `main` (seeding a default-branch-scoped cache that tag runs can
  # read) — that build skips the GHCR push; the tag run restores it and pushes.
  hasLean = (cache.lean or false) != false;

  # buildTiming: -L for streamed, drv-prefixed build logs; --quiet otherwise.
  verbosity = if buildTiming then "-L" else "--quiet";
  # gawk filter: passes every build line through to the console (so failures stay
  # visible) and records, per component, the wall-clock window it was active in
  # (first→last log line matching it). Prints a bar chart in END. Writes only to
  # /dev/stderr — never stdout — so the captured `--print-out-paths` stays clean.
  timingAwk = ''
    function cat(n) {
      if      (n ~ /\.tar\.gz|layers\.json|stream-|customisation-layer|-conf\.json|-base\.json|excludePaths/) return "packaging"
      else if (n ~ /landing-frontend|next/)      return "frontend/next"
      else if (n ~ /-mfe|wasm/)                  return "wasm-mfe"
      else if (n ~ /(^|-)backend/)               return "backend"
      else if (n ~ /blog/)                       return "blog"
      else if (n ~ /whitepaper/)                 return "whitepaper"
      else if (n ~ /rust-std|cargo-nightly|rust-analyzer|cranelift|rust-docs/) return "rust-toolchain"
      else if (n ~ /\.tgz/)                       return "npm-deps"
      return "other-crates"
    }
    {
      print $0 > "/dev/stderr"
      n = ""
      if (match($0, /\/nix\/store\/[a-z0-9]+-[^ ]*\.drv/)) { n = substr($0, RSTART, RLENGTH) }
      else if (match($0, /^[A-Za-z0-9._-]+> /))            { n = substr($0, 1, RLENGTH-2) }
      else next
      c = cat(n); now = systime()
      if (!(c in st)) st[c] = now
      en[c] = now
      if (t0 == 0) t0 = now
    }
    END {
      if (t0 == 0) exit
      tmax = 0; for (c in en) if (en[c] > tmax) tmax = en[c]
      span = tmax - t0; if (span < 1) span = 1
      W = 50; unit = (span/W >= 1 ? int(span/W) : 1)
      printf "\n== build timeline (%dm%02ds total, each # ~ %ds) ==\n", span/60, span%60, unit > "/dev/stderr"
      PROCINFO["sorted_in"] = "@val_num_asc"
      for (c in st) {
        a = int((st[c]-t0)/span*W); b = int((en[c]-t0)/span*W); if (b <= a) b = a+1
        pad = ""; for (i=0;i<a;i++) pad = pad " "
        fill = ""; for (i=0;i<b-a;i++) fill = fill "#"
        printf "%-15s |%s%s  %dm%02ds\n", c, pad, fill, (en[c]-st[c])/60, (en[c]-st[c])%60 > "/dev/stderr"
      }
    }
  '';
  timingWrap = lib.optionalString buildTiming " 2> >(gawk '${timingAwk}' >&2)";

  # The `v[0-9]+.*` trigger is coarse; this is what refuses a malformed tag with a
  # clear error (release-gate.nix can only skip silently). Rejects v1, v1.2, vbeta.
  semverGate = ''
    TAG="''${{ github.ref_name }}"
    if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
      echo "::error::tag '$TAG' is not a strict semver vX.Y.Z[-prerelease] — refusing to release" >&2
      exit 1
    fi
  '';

  # The flake fetch runs in the client `nix` process as the runner user, so plain
  # ~/.ssh identities are enough — no agent, no daemon forwarding. keyscan pins
  # github.com's host key (non-interactive shells can't answer the trust prompt).
  secretOf = repo: "DEPLOY_KEY_" + builtins.replaceStrings [ "." "-" ] [ "_" "_" ] (lib.toUpper repo);
  mkKeyBlock = ownerRepo:
    let repo = lib.last (lib.splitString "/" ownerRepo); secret = secretOf repo; in ''
    key="''${{ secrets.${secret} }}"
    if [ -z "$key" ]; then
      echo "::error::${secret} unset — build fetches private input '${ownerRepo}'. Provision: git_ops init-deploy-key ${ownerRepo}" >&2
      exit 1
    fi
    printf '%s\n' "$key" > ~/.ssh/${repo}
    chmod 600 ~/.ssh/${repo}
    printf 'Host gh-${repo}\n  HostName github.com\n  User git\n  IdentityFile ~/.ssh/${repo}\n  IdentitiesOnly yes\n' >> ~/.ssh/config
    git config --global url."ssh://git@gh-${repo}/${ownerRepo}".insteadOf "ssh://git@github.com/${ownerRepo}"
    git config --global url."git@gh-${repo}:${ownerRepo}".insteadOf "git@github.com:${ownerRepo}"
  '';
  deployKeyStep = {
    name = "SSH auth for private flake inputs";
    shell = "bash";
    run = ''
      install -d -m 700 ~/.ssh
      ssh-keyscan -t rsa,ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
    '' + lib.concatStrings (map mkKeyBlock deployKeys);
  };
in
{
  standalone = true;
  filename = "release-container.yml";

  name = "Release containers";
  on.push = { tags = [ "v[0-9]+.*" ]; } // (if hasLean then { branches = [ "main" ]; } else { });
  permissions = {
    contents = "read";
    packages = "write";
  };
  jobs.release = {
    runs-on = "ubuntu-24.04-arm";
    # Backstop: a cold build is ~25min; cap the job so a hung step can never burn
    # runner minutes indefinitely (see the magic-nix-cache post-step hang).
    timeout-minutes = 40;
    steps = [
      # lfs: image/font assets (e.g. the frontend's PNGs) are Git-LFS tracked; without
      # this the working tree has pointer files and the image build fails decoding them.
      {
        uses = "actions/checkout@v4";
        "with".lfs = true;
      }
      {
        name = "Validate tag (strict semver)";
        # Skipped on the `main` cache-seed build (no tag to validate).
        "if" = "github.ref_type == 'tag'";
        shell = "bash";
        run = semverGate;
      }
    ]
    # setupSteps precedes installStep (lean writes its post-build-hook there); [] for other modes.
    ++ nixCi.setupSteps
    ++ [
      # Determinate Nix (lazy-trees) + binary cache (cache.nix). The cache restores the
      # expensive cold Rust/npm build store across releases — without it every tag
      # recompiles from scratch (~25min on the arm runner).
      nixCi.installStep
      (if hasLean then nixCi.cacheRestoreStep else nixCi.cacheStep)
      {
        name = "Log in to GHCR";
        # Only the tag build pushes to GHCR; the `main` seed build just warms the cache.
        "if" = "github.ref_type == 'tag'";
        uses = "docker/login-action@v3";
        "with" = {
          registry = "ghcr.io";
          username = "\${{ github.actor }}";
          password = "\${{ secrets.GITHUB_TOKEN }}";
        };
      }
    ]
    ++ (if deployKeys != [] then [ deployKeyStep ] else [])
    ++ [
      {
        name = "Build + push containers";
        shell = "bash";
        run = ''
          set -euo pipefail
          sys="$(nix eval --impure --raw --expr builtins.currentSystem)"
          # Extract to a var first: `for x in $(cmd)` swallows cmd's exit code, so a
          # failed eval (e.g. a flake error) would leave the loop empty and the job GREEN.
          names="$(nix eval ${lib.optionalString impure "--impure --refresh "}--json ".#containers.$sys" --apply builtins.attrNames | jq -r '.[]')"
          [ -n "$names" ] || { echo "::error::no containers found under .#containers.$sys" >&2; exit 1; }
          # nixpkgs skopeo rejects the GH runner's v1-format /etc/containers/registries.conf
          # ("must be in v2 format"); point it at our own minimal v2 file so it never reads the host's.
          CONTAINERS_REGISTRIES_CONF="$(mktemp)"; export CONTAINERS_REGISTRIES_CONF
          printf 'unqualified-search-registries = []\n' > "$CONTAINERS_REGISTRIES_CONF"
          for name in $names; do
            echo "::group::$name"
            RESULT="$(nix build ${lib.optionalString impure "--impure --refresh "}".#$name-container" --no-link --print-out-paths ${verbosity}${timingWrap})"
            if [ "''${{ github.ref_type }}" = "tag" ]; then
              nix run nixpkgs#skopeo -- copy \
                "docker-archive:$RESULT" \
                "docker://${registry}/$name:''${{ github.ref_name }}"
            else
              echo "cache-seed build ($name) on ''${{ github.ref_name }} — skipping GHCR push"
            fi
            echo "::endgroup::"
          done
        '';
      }
    ]
    # Persist the lean cache to the default-branch scope — only fires on `main` (its own
    # `if`); a no-op list entry on tag runs. Empty for non-lean modes.
    ++ (if hasLean then [ nixCi.cacheSaveStep ] else [ ]);
  };
}
