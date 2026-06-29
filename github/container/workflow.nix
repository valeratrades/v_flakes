# Tag-driven, versioned-only push of every `#containers.<system>.<name>` to GHCR
# (aarch64). The repo's container set is enumerated at build time, so adding a
# container needs no workflow change.
{ registry }:
let
  # The `v[0-9]+.*` trigger is coarse; this is what refuses a malformed tag with a
  # clear error (release-gate.nix can only skip silently). Rejects v1, v1.2, vbeta.
  semverGate = ''
    TAG="''${{ github.ref_name }}"
    if [[ ! "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$ ]]; then
      echo "::error::tag '$TAG' is not a strict semver vX.Y.Z[-prerelease] — refusing to release" >&2
      exit 1
    fi
  '';
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
      # Determinate Nix + magic-nix-cache: the cache restores the (expensive, cold)
      # Rust/npm build store across releases — without it every tag recompiles from
      # scratch (~25min on the arm runner). lazy-trees is safe now that no flake
      # input carries Git-LFS content (LFS made input narHashes non-deterministic;
      # see the de-LFS commit) — both nix implementations agree on the lock.
      {
        uses = "DeterminateSystems/nix-installer-action@main";
        "with".extra-conf = "lazy-trees = true";
      }
      { uses = "DeterminateSystems/magic-nix-cache-action@main"; }
      {
        name = "Log in to GHCR";
        uses = "docker/login-action@v3";
        "with" = {
          registry = "ghcr.io";
          username = "\${{ github.actor }}";
          password = "\${{ secrets.GITHUB_TOKEN }}";
        };
      }
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
            RESULT="$(nix build ".#$name-container" --no-link --print-out-paths)"
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
