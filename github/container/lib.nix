# The v_flakes container standard, exposed as `v_flakes.container`. One image per
# repo (`implement`), one contract, one tag-driven release (workflow.nix).
let
  # Set only by `implement`, so a repo can't ship a container without the contract
  # baked into its labels.
  ociLabels = { pname, port, healthPath, criticality ? "high", ... }: {
    "org.opencontainers.image.title" = pname;
    "ev.invest.contract.port" = toString port;
    "ev.invest.contract.health-path" = healthPath;
    "ev.invest.contract.criticality" = criticality;
  };
in
{
  # The standard owns the image build, so labels + contract-derived ExposedPorts
  # can't drift. The repo hands it an entrypoint + closure; `env`/`mounts` describe
  # runtime requirements for `toManifests` (secret env arrives via the k8s Secret
  # gitops owns, never baked in). `imageEnv` is the non-secret boot env.
  implement =
    { pkgs
    , pname
    , port
    , healthPath
    , entrypoint
    , env ? { }
    , mounts ? [ ]
    , criticality ? "high"
    , contents ? [ ]
    , imageEnv ? [ ]
    , workingDir ? null
    , withCacert ? true
    , tag ? "latest"
    }:
    assert pkgs.lib.elem criticality [ "high" "normal" ];
    let
      lib = pkgs.lib;
      contract = { inherit pname port env mounts healthPath criticality; };
      cacertEnv = lib.optional withCacert
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      image = pkgs.dockerTools.buildLayeredImage {
        name = pname;
        inherit tag;
        contents = contents ++ lib.optional withCacert pkgs.cacert;
        config = {
          Entrypoint = entrypoint;
          Env = cacertEnv ++ imageEnv;
          ExposedPorts = { "${toString port}/tcp" = { }; };
          Labels = ociLabels contract;
        } // lib.optionalAttrs (workingDir != null) { WorkingDir = workingDir; };
      };
    in
    {
      packages.container = image;
      packages.container-contract =
        pkgs.writeText "${pname}-contract.json" (builtins.toJSON contract);
    };

  # The eval probe turns a missing `packages.container` into one actionable line
  # instead of nix build's cryptic attr error.
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

  # contract + registry ref → k8s Deployment/Service (pure data; gitops adds
  # namespace/PVC/Ingress and serialises). `image` carries no tag — Flux
  # image-automation pins `:vX.Y.Z`.
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
