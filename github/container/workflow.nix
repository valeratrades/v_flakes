# release-container.yml: tag-driven, versioned-only push of `nix build .#container`
# to GHCR. Mirrors rust/release.nix's shape but single-file and arch-native
# (the cluster is aarch64). No `latest`.
#
# Gate: the `v[0-9]+.*` trigger is coarse; this strict check is what actually
# refuses a malformed tag with a clear `::error::`. release-gate.nix only flips a
# run=true/false flag (silent skip), so the gate is inlined here. The plan locks
# `vX.Y.Z`; the optional pre-release suffix is what lets a `v0.0.1-rc1` staging
# tag through (verification step 4) while still rejecting `v1`, `v1.2`, `vbeta`.
{ registry, pname }:
let
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

  name = "Release container";
  on.push.tags = [ "v[0-9]+.*" ];
  permissions = {
    contents = "read";
    packages = "write";
  };
  jobs.release = {
    runs-on = "ubuntu-24.04-arm";
    steps = [
      { uses = "actions/checkout@v4"; }
      {
        name = "Validate tag (strict semver)";
        shell = "bash";
        run = semverGate;
      }
      { uses = "DeterminateSystems/nix-installer-action@main"; }
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
        name = "Build + push container";
        shell = "bash";
        run = ''
          RESULT="$(nix build .#container --no-link --print-out-paths)"
          nix run nixpkgs#skopeo -- copy \
            "docker-archive:$RESULT" \
            "docker://${registry}/${pname}:''${{ github.ref_name }}"
        '';
      }
    ];
  };
}
