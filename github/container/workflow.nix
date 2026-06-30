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
{ registry, deployKeys ? [], lib, cache ? { nix-action = true; } }:
let
  nixCi = import ../cache.nix { inherit cache; };
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
  on.push.tags = [ "v[0-9]+.*" ];
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
        shell = "bash";
        run = semverGate;
      }
      # Determinate Nix (lazy-trees) + binary cache (cache.nix). The cache restores the
      # expensive cold Rust/npm build store across releases — without it every tag
      # recompiles from scratch (~25min on the arm runner).
      nixCi.installStep
      nixCi.cacheStep
      {
        name = "Log in to GHCR";
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
          names="$(nix eval --json ".#containers.$sys" --apply builtins.attrNames | jq -r '.[]')"
          [ -n "$names" ] || { echo "::error::no containers found under .#containers.$sys" >&2; exit 1; }
          # nixpkgs skopeo rejects the GH runner's v1-format /etc/containers/registries.conf
          # ("must be in v2 format"); point it at our own minimal v2 file so it never reads the host's.
          export CONTAINERS_REGISTRIES_CONF="$(mktemp)"
          printf 'unqualified-search-registries = []\n' > "$CONTAINERS_REGISTRIES_CONF"
          for name in $names; do
            echo "::group::$name"
            RESULT="$(nix build ".#$name-container" --no-link --print-out-paths --quiet)"
            nix run nixpkgs#skopeo -- copy \
              "docker-archive:$RESULT" \
              "docker://${registry}/$name:''${{ github.ref_name }}"
            echo "::endgroup::"
          done
        '';
      }
    ];
  };
}
