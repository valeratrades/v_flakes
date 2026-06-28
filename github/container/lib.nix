# The v_flakes container standard. One OCI image per repo, one machine-readable
# contract, one tag-driven release (workflow.nix). Exposed as `v_flakes.container`.
#
# A repo builds its own image however it likes (pure `dockerTools.buildLayeredImage`
# is the norm) and calls `implement` to fix the output name + emit the contract.
# `gitops` reads the contract (never the repo's build internals) via `toManifests`.
{
  # Standard OCI labels for a contract. Callers spread this into their image's
  # `config.Labels` (dockerTools can't add labels to an already-built image, so
  # this is set at build time, not by `implement`). The contract JSON is the
  # canonical source; these labels mirror it so `skopeo inspect` carries it too.
  ociLabels = { pname, port, healthPath, criticality ? "high", ... }: {
    "org.opencontainers.image.title" = pname;
    "ev.invest.contract.port" = toString port;
    "ev.invest.contract.health-path" = healthPath;
    "ev.invest.contract.criticality" = criticality;
  };

  # Repos call this. Fixes the output attr name (`packages.container`) and emits
  # the contract; it does NOT touch build internals — `image` is whatever the
  # repo built. `env`/`mounts` describe runtime requirements for `toManifests`.
  implement =
    { pkgs
    , image
    , pname
    , port
    , env ? { }
    , mounts ? [ ]
    , healthPath
    , criticality ? "high"
    }:
    assert pkgs.lib.elem criticality [ "high" "normal" ];
    let
      contract = { inherit pname port env mounts healthPath criticality; };
    in
    {
      packages.container = image;
      packages.container-contract =
        pkgs.writeText "${pname}-contract.json" (builtins.toJSON contract);
    };

  # workflow + manual use: build a repo's `#container`, with a clear error if the
  # repo never implemented one. `nix build` alone fails cryptically on a missing
  # attr; the eval probe turns it into one actionable line.
  build = { pkgs, flakeRef }:
    pkgs.writeShellApplication {
      name = "build-container";
      runtimeInputs = [ pkgs.nix ];
      text = ''
        ref="${flakeRef}"
        if ! nix eval "$ref#container" --apply 'x: true' >/dev/null 2>&1; then
          echo "::error::$ref does not expose packages.container — add v_flakes.container.implement to its flake" >&2
          exit 1
        fi
        nix build "$ref#container" --no-link --print-out-paths
      '';
    };

  # gitops: contract + pushed image ref → k8s manifests (pure data; gitops adds
  # namespace/PVC/ConfigMap/Ingress per repo and serialises to YAML). `image` is
  # the registry ref WITHOUT a tag; Flux image-automation pins `:vX.Y.Z`.
  toManifests = { contract, image, tag ? "v0.0.0" }:
    let
      inherit (contract) pname port healthPath env mounts;
      labels = { app = pname; };
      probe = {
        httpGet = { path = healthPath; port = port; };
        initialDelaySeconds = 5;
        periodSeconds = 10;
      };
      containerEnv = builtins.attrValues (builtins.mapAttrs
        (name: value: { inherit name value; }) env);
      volumeMounts = map (m: { name = "data"; mountPath = m; }) mounts;
      volumes = if mounts == [ ] then [ ] else [{
        name = "data";
        persistentVolumeClaim.claimName = "${pname}-data";
      }];
    in
    {
      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = { name = pname; inherit labels; };
        spec = {
          replicas = 1;
          selector.matchLabels = labels;
          template = {
            metadata.labels = labels;
            spec = {
              containers = [{
                name = pname;
                image = "${image}:${tag}";
                ports = [{ containerPort = port; }];
                env = containerEnv;
                # Secret-sourced env (DATABASE_URL, tokens, …) lives in a k8s
                # Secret `<pname>-env` that gitops owns — never in the contract.
                envFrom = [{ secretRef = { name = "${pname}-env"; }; }];
                livenessProbe = probe;
                readinessProbe = probe;
                volumeMounts = volumeMounts;
              }];
              inherit volumes;
            };
          };
        };
      };
      service = {
        apiVersion = "v1";
        kind = "Service";
        metadata = { name = pname; inherit labels; };
        spec = {
          selector = labels;
          ports = [{ port = port; targetPort = port; }];
        };
      };
    };
}
