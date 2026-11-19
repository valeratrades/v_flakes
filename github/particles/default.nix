# A repo's checks. A particle is one by being listed in `jobs.errors` or `jobs.warnings`, the list its
# severity: `nix run .#test` runs it, that section's workflow runs it, and the section's badge counts it.
#   "rust-tests" | { name = "rust-doc"; args.package = "x"; }   one of ./catalog.nix
#   { name; program; prepare ? null; ci ? null; ciCache ? null; } a repo's own; `program` an executable derivation
#   { name; builds = self.checks.${system}; }                    building derivations is the work
# `prepare` sets up what `program` needs; its time is reported apart from `program`'s; `ciCache` is `{ paths; hashFiles; }`, or a
# list of them, for the section's CI job to keep between runs.
{ pkgs, catalogs, sections }:
let
  lib = pkgs.lib;
  reserved = [ "particles" "report" "pre_ci" "load_nix" ]; # the workflows' own job ids
  fields = [ "name" "args" "program" "builds" "prepare" "ci" "ciCache" ];

  builds = name: drvs: pkgs.writeShellApplication {
    name = "build-${name}";
    text = "nix build --no-link --print-build-logs ${lib.concatMapStringsSep " " (d: lib.escapeShellArg "${builtins.unsafeDiscardOutputDependency d.drvPath}^*") (if builtins.isList drvs then drvs else builtins.attrValues drvs)}";
  };

  resolve = severity: spec:
    let
      s = if builtins.isString spec then { name = spec; } else spec;
      own = s ? program || s ? builds;
      catalog = catalogs.${severity};
      p =
        if own then s
        else (catalog.${s.name} or (throw "v_flakes.github: no particle `${s.name}`; v_flakes ships ${lib.concatStringsSep ", " (builtins.attrNames catalog)}")) (s.args or { });
    in
    assert lib.subtractLists fields (builtins.attrNames s) == [ ] || throw "v_flakes.github: particle `${s.name}` has unknown keys ${toString (lib.subtractLists fields (builtins.attrNames s))}";
    assert !(own && s ? args) || throw "v_flakes.github: `args` are for v_flakes' own particles; `${s.name}` brings its program";
    assert own || builtins.attrNames (removeAttrs s [ "name" "args" ]) == [ ] || throw "v_flakes.github: `${s.name}` is v_flakes' own: it takes only `args`";
    assert builtins.match "[A-Za-z_][A-Za-z0-9_-]*" s.name != null || throw "v_flakes.github: particle name `${s.name}` isn't a GitHub output id";
    assert !(builtins.elem s.name reserved) || throw "v_flakes.github: `${s.name}` is a workflow job id; name the particle otherwise";
    {
      inherit (s) name;
      inherit severity;
      program = if s ? builds then builds s.name s.builds else p.program;
      prepare = p.prepare or null;
      ci = p.ci or null;
      ciCache = lib.toList (p.ciCache or [ ]);
    };

  bySection = builtins.mapAttrs (severity: map (resolve severity)) sections;
  all = bySection.errors ++ bySection.warnings;
  duplicates = lib.filter (n: lib.count (m: m == n) (map (p: p.name) all) > 1) (lib.unique (map (p: p.name) all));

  # .drv paths only: a particle builds when selected, not when the runner does
  drv = d: builtins.unsafeDiscardOutputDependency d.drvPath;
  bin = d: "bin/${d.meta.mainProgram or (throw "v_flakes.github: a particle's program `${d.name}` has no meta.mainProgram")}";
  spec = pkgs.writeText "particles.json" (builtins.toJSON (map
    (p: {
      inherit (p) name severity;
      program = drv p.program;
      bin = bin p.program;
      prepare = if p.prepare == null then null else drv p.prepare;
      prepareBin = if p.prepare == null then null else bin p.prepare;
    })
    all));
in
assert duplicates == [ ] || throw "v_flakes.github: particles listed twice: ${toString duplicates}";
{
  inherit (bySection) errors warnings;
  runner = pkgs.writeShellApplication {
    name = "particles";
    runtimeInputs = [ pkgs.jq pkgs.gitMinimal pkgs.coreutils ];
    text = "spec=${spec}\n" + builtins.readFile ./runner.sh;
    passthru.vFlakesParticles = true; # how v_flakes' flake-utils finds it in a devShell, for `apps.test`
    meta.description = "the repo's checks (particles), in parallel, with their times; `-- --help`";
  };
}
