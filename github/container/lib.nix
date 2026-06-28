# The v_flakes container standard, exposed as `v_flakes.container`. A repo can ship
# N containers; each is an entry in `implement`'s `containers` set, keyed by its
# name. The key is the one identifier — image name, package name, contract name,
# and the Flux image-policy marker all reuse it.
let
  # Set only by `implement`, so a container can't ship without its contract baked
  # into the image labels.
  ociLabels = c: {
    "org.opencontainers.image.title" = c.name;
    "ev.invest.contract.port" = toString c.port;
    "ev.invest.contract.health-path" = c.healthPath;
    "ev.invest.contract.criticality" = c.criticality;
  };

  mkOne = pkgs: name: spec:
    assert pkgs.lib.elem (spec.criticality or "high") [ "high" "normal" ];
    let
      lib = pkgs.lib;
      contract = {
        inherit name;
        inherit (spec) port healthPath;
        criticality = spec.criticality or "high";
        env = spec.env or { };
        mounts = spec.mounts or [ ];
      };
      withCacert = spec.withCacert or true;
      cacertEnv = lib.optional withCacert
        "SSL_CERT_FILE=${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      image = pkgs.dockerTools.buildLayeredImage {
        inherit name;
        tag = spec.tag or "latest";
        contents = (spec.contents or [ ]) ++ lib.optional withCacert pkgs.cacert;
        config = {
          Entrypoint = spec.entrypoint;
          Env = cacertEnv ++ (spec.imageEnv or [ ]);
          ExposedPorts = { "${toString spec.port}/tcp" = { }; };
          Labels = ociLabels contract;
        } // lib.optionalAttrs (spec ? workingDir) { WorkingDir = spec.workingDir; };
      };
    in
    { inherit image contract; };
in
{
  # Repos call this with their `pname` and a set of containers keyed by
  # sub-variant ("" = the primary). The image name joins them: `pname` for "",
  # else `pname-<sub>`. Each spec: { port; healthPath; entrypoint;
  # criticality ? "high"; env ? {}; mounts ? []; contents ? []; imageEnv ? [];
  # workingDir ? null; withCacert ? true; tag ? "latest"; }. `env`/`mounts`
  # describe runtime requirements for `toManifests` (secret env arrives via the
  # k8s Secret gitops owns, never baked in); `imageEnv` is the non-secret boot
  # env. Returns a buildable `packages.<name>-container` for each plus
  # `containers.<name> = { image; contract; }` (plain data gitops reads).
  implement = { pkgs, pname, containers }:
    let
      lib = pkgs.lib;
      fullName = sub: if sub == "" then pname else "${pname}-${sub}";
      built = lib.mapAttrs'
        (sub: spec: lib.nameValuePair (fullName sub) (mkOne pkgs (fullName sub) spec))
        containers;
    in
    {
      containers = built;
      packages = builtins.listToAttrs (map
        (name: { name = "${name}-container"; value = built.${name}.image; })
        (builtins.attrNames built));
    };

  # The eval probe turns a missing container into one actionable line instead of
  # nix build's cryptic attr error.
  build = { pkgs, flakeRef, name }:
    pkgs.writeShellApplication {
      name = "build-container";
      runtimeInputs = [ pkgs.nix ];
      text = ''
        ref="${flakeRef}#${name}-container"
        if ! nix eval "$ref" --apply 'x: true' >/dev/null 2>&1; then
          echo "::error::$ref not found — add it to v_flakes.container.implement's containers" >&2
          exit 1
        fi
        nix build "$ref" --no-link --print-out-paths
      '';
    };

  # contract + registry ref → k8s Deployment/Service (pure data; gitops adds
  # namespace/PVC/Ingress and serialises). `image` carries no tag — Flux
  # image-automation pins `:vX.Y.Z`.
  toManifests = { contract, image, tag ? "v0.0.0" }:
    let
      inherit (contract) name port healthPath env mounts;
      labels = { app = name; };
      probe = {
        httpGet = { path = healthPath; port = port; };
        initialDelaySeconds = 5;
        periodSeconds = 10;
      };
      containerEnv = builtins.attrValues (builtins.mapAttrs
        (n: value: { name = n; inherit value; }) env);
      volumeMounts = map (m: { name = "data"; mountPath = m; }) mounts;
      volumes = if mounts == [ ] then [ ] else [{
        name = "data";
        persistentVolumeClaim.claimName = "${name}-data";
      }];
    in
    {
      deployment = {
        apiVersion = "apps/v1";
        kind = "Deployment";
        metadata = { inherit name; inherit labels; };
        spec = {
          replicas = 1;
          selector.matchLabels = labels;
          template = {
            metadata.labels = labels;
            spec = {
              containers = [{
                inherit name;
                image = "${image}:${tag}";
                ports = [{ containerPort = port; }];
                env = containerEnv;
                envFrom = [{ secretRef = { name = "${name}-env"; }; }];
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
        metadata = { inherit name; inherit labels; };
        spec = {
          selector = labels;
          ports = [{ port = port; targetPort = port; }];
        };
      };
    };
}
