# The v_flakes container standard, exposed as `v_flakes.container`. A repo can ship
# N containers; each is an entry in `implement`'s `containers` set, keyed by its
# name. The key is the one identifier — image name, package name, contract name,
# and the Flux image-policy marker all reuse it.
let
  # k8s resource names are RFC1123 — no underscores (image refs allow them). The
  # one sanctioned translation from a container's name to its k8s identity;
  # everything downstream (Deployment/Service names, ImagePolicy names, secret
  # names `kubernetes-<k8sName>`) derives through here.
  k8sName = builtins.replaceStrings [ "_" ] [ "-" ];

  # Set only by `implement`, so a container can't ship without its contract baked
  # into the image labels.
  ociLabels = c: {
    "org.opencontainers.image.title" = c.name;
    "ev.invest.contract.criticality" = c.criticality;
  } // (if c.port == null then { } else {
    "ev.invest.contract.port" = toString c.port;
    "ev.invest.contract.health-path" = c.healthPath;
  });

  # Every key `mkOne` reads. An unknown one is a typo, and a typo that is merely
  # ignored ships the default while the author reads their own line and believes
  # otherwise.
  known = [ "port" "healthPath" "entrypoint" "criticality" "env" "mounts" "contents" "imageEnv" "workingDir" "withCacert" "tag" ];
  # No default is truthful for these. Reported together, with what each is for:
  # failing on the first costs one round trip per key.
  # A worker that listens on nothing states it: `port = null; healthPath = null;`.
  required = {
    port = "TCP port the process listens on — the Service target and what the probes dial; null for a worker that listens on nothing";
    healthPath = "HTTP path answering 200 once the process is up, e.g. \"/health\"; null exactly when port is";
    entrypoint = "the image's ENTRYPOINT as a list, e.g. [ \"\${pkg}/bin/foo\" ]";
  };

  mkOne = pkgs: name: spec:
    assert (
      let unknown = builtins.attrNames (builtins.removeAttrs spec known); in
      unknown == [ ] || throw "v_flakes container '${name}': unknown keys ${builtins.toJSON unknown} — known keys are ${builtins.toJSON known}"
    );
    assert (
      let missing = builtins.filter (k: !(spec ? ${k})) (builtins.attrNames required); in
      missing == [ ] || throw "v_flakes container '${name}' is missing:\n${pkgs.lib.concatMapStringsSep "\n" (k: "  ${k} — ${required.${k}}") missing}"
    );
    assert (
      (spec.port == null) == (spec.healthPath == null)
      || throw "v_flakes container '${name}': port and healthPath are null together or not at all — a probe needs a port, and a port with no probe is never proven up"
    );
    assert (
      let c = spec.criticality or "high"; in
      builtins.elem c [ "high" "normal" ] || throw "v_flakes container '${name}': criticality is \"${c}\", must be \"high\" or \"normal\" — it orders the cluster's reconcile chain"
    );
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
      # `nobody`, which is the uid `fakeNss` already defines — so nothing needs a
      # passwd entry invented for it, and anything calling getpwuid (Rust's
      # `dirs`, Node's `os.homedir()`) resolves instead of failing on an unknown
      # uid. Declared in the IMAGE rather than left to the deployment: a manifest
      # asserting `runAsNonRoot` against an image that says nothing is refused by
      # the kubelet, and the two disagreeing is worse than either alone.
      #
      # Every port in this standard's consumers is >1024, so there is nothing a
      # non-root process cannot bind. A container that writes to a mounted volume
      # needs that volume writable by 65534 — the mount is the deployment's to
      # arrange, not the image's.
      user = "65534:65534";
      image = pkgs.dockerTools.buildLayeredImage {
        inherit name;
        tag = spec.tag or "latest";
        contents = (spec.contents or [ ]) ++ [ pkgs.fakeNss ]
          ++ lib.optional withCacert pkgs.cacert;
        config = {
          Entrypoint = spec.entrypoint;
          Env = cacertEnv ++ (spec.imageEnv or [ ]);
          ExposedPorts = if spec.port == null then { } else { "${toString spec.port}/tcp" = { }; };
          Labels = ociLabels contract;
          User = user;
        } // lib.optionalAttrs (spec ? workingDir) { WorkingDir = spec.workingDir; };
      };
    in
    { inherit image contract; };
in
{
  inherit k8sName;

  # The gitops-side complement of `implement`: a repo's `containers.<system>`
  # output → the `{ name = k8s/ImagePolicy name; image = registry path segment }`
  # pairs the Flux glue consumes. Naming flows one way — repos pick keys via
  # `implement`, gitops enumerates them here — so nothing is ever spelled twice.
  fluxContainers = containers:
    map (n: { name = k8sName n; image = n; }) (builtins.attrNames containers);

  # Repos call this with their `pname` and a set of containers keyed by
  # sub-variant ("" = the primary). The image name joins them: `pname` for "",
  # else `pname-<sub>`. A spec's keys are `known` above, `required` of them named
  # there too; anything else throws. `env`/`mounts` describe runtime requirements
  # for `toManifests` (secret env arrives via the k8s Secret gitops owns, never
  # baked in); `imageEnv` is the non-secret boot env. Returns a buildable
  # `packages.<name>-container` for each plus `containers.<name> =
  # { image; contract; }` (plain data gitops reads).
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
    assert contract.port != null
      || throw "v_flakes toManifests '${contract.name}': a worker (port = null) has no Service and no probe — its Deployment is the consumer's to write";
    let
      inherit (contract) name port healthPath env mounts;
      labels = { app = name; };
      probe = {
        httpGet = { path = healthPath; port = port; };
        initialDelaySeconds = 5;
        periodSeconds = 10;
      };
      containerEnv = builtins.attrValues (builtins.mapAttrs
        (n: value: { name = n; inherit value; })
        env);
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
          # a rollout that can't go Ready must announce itself fast — the
          # release-deprecator keys off ProgressDeadlineExceeded.
          progressDeadlineSeconds = 180;
          selector.matchLabels = labels;
          template = {
            metadata.labels = labels;
            spec = {
              containers = [{
                inherit name;
                image = "${image}:${tag}";
                ports = [{ containerPort = port; }];
                env = containerEnv;
                # optional: a container with no secret env (e.g. a static frontend)
                # still starts; a required-but-missing secret crashloops visibly.
                envFrom = [{ secretRef = { name = "kubernetes-${name}"; optional = true; }; }];
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
