# JavaScript/TypeScript (npm) project module
{ pkgs ? null
, nixpkgs ? null
, # package roots, relative to the repo root; `<dir>/*` is every package directly under <dir>
  packages ? null
, # the repo root (`./.`), read to expand a `<dir>/*`
  rootDir ? null
, node ? null
,
}:
if pkgs == null then {
  description = ''
    JavaScript/TypeScript module: npm, the fleet's package manager.

    ```nix
    js = v_flakes.js { inherit pkgs; packages = [ "frontend" "ts/*" ]; rootDir = ./.; };  # rootDir only for a `/*`
    github = v_flakes.github { inherit pkgs js; ... };   # its particles join the default jobs
    combined = v_flakes.utils.combine { modules = [ ... js ]; };  # nodejs and `js-local` in the shell
    ```

    Per package `<p>` (its path, `/` as `-`; `js` for the root), particles running its own scripts,
    `npm ci` first where node_modules is absent (a fresh checkout's `file:` dependencies built too):
      errors:   <p>-typecheck (`npm run typecheck`), <p>-test (`npm test`)
      warnings: <p>-lint (`npm run lint`)
    A missing script fails its particle: `jobs.<section>.exclude` it instead. CI keeps `~/.npm` by the lockfiles.

    `js.playwright { name; package; config; env ? { }; run ? "exec playwright test -c <config> \"$@\""; runtimeInputs ? [ ]; }`:
    a particle running playwright from nixpkgs (its browsers pinned with it) in `package`, `config`'s
    `node_modules` linked to nixpkgs' `@playwright/test`. Its `program` serves as an app too.
  '';
} else
  let
    lib = pkgs.lib;
    nodejs = if node != null then node else pkgs.nodejs;
    jsLocal = import ./local.nix { inherit pkgs; };

    expand = p:
      if lib.hasSuffix "/*" p then
        let
          dir = lib.removeSuffix "/*" p;
          entries = builtins.readDir (rootDir + "/${dir}");
        in
        assert rootDir != null || throw "v_flakes.js: `${p}` is read from the repo: pass `rootDir = ./.;`";
        map (n: "${dir}/${n}") (builtins.filter (n: entries.${n} == "directory" && builtins.pathExists (rootDir + "/${dir}/${n}/package.json")) (builtins.attrNames entries))
      else
        assert !(lib.hasInfix "*" p) || throw "v_flakes.js: only a trailing `/*` globs, got `${p}`";
        [ (lib.removeSuffix "/" p) ];
    roots = assert packages != null || throw "v_flakes.js: `packages` is required (the package roots, e.g. [ \"frontend\" ])";
      lib.concatMap expand packages;
    prefix = dir: if dir == "." then "js" else builtins.replaceStrings [ "/" ] [ "-" ] dir;
    cdInto = dir: ''cd "$(git rev-parse --show-toplevel)/${dir}"'';

    # never wipes an installed node_modules: `js-local` copies live there
    prepare = dir: pkgs.writeShellApplication {
      name = "${prefix dir}-install";
      runtimeInputs = [ nodejs jsLocal pkgs.git ];
      text = cdInto dir + ''

        # a `file:` dependency ships whatever its directory holds; a fresh one is installed and built, an installed one is the developer's
        node -e '
          const p = require("./package.json");
          for (const deps of [p.dependencies, p.devDependencies, p.peerDependencies])
            for (const v of Object.values(deps ?? {}))
              if (v.startsWith("file:")) console.log(v.slice(5));
        ' | while read -r dep; do
          [ -d "$dep/node_modules" ] || (cd "$dep" && npm ci --ignore-scripts && npm run build)
        done
        [ -d node_modules ] || npm ci
      '';
    };
    ciCache = dir: { paths = [ "~/.npm" ]; hashFiles = [ "${dir}/package-lock.json" ]; };

    script = dir: s: {
      name = "${prefix dir}-${s}";
      prepare = prepare dir;
      ciCache = ciCache dir;
      program = pkgs.writeShellApplication {
        name = "${prefix dir}-${s}";
        runtimeInputs = [ nodejs pkgs.git ];
        text = cdInto dir + "\nexec npm run ${s}\n";
      };
    };
  in
  {
    inherit nodejs;
    enabledPackages = [ nodejs jsLocal ];

    particles = {
      errors = lib.concatMap (d: [ (script d "typecheck") (script d "test") ]) roots;
      warnings = map (d: script d "lint") roots;
    };

    playwright = { name, package, config, env ? { }, run ? ''exec playwright test -c ${lib.escapeShellArg config} "$@"'', runtimeInputs ? [ ] }: {
      inherit name;
      prepare = prepare package;
      ciCache = ciCache package;
      program = pkgs.writeShellApplication {
        inherit name;
        runtimeInputs = [ nodejs pkgs.git pkgs.coreutils pkgs.playwright-test ] ++ runtimeInputs;
        runtimeEnv = env // {
          PLAYWRIGHT_BROWSERS_PATH = "${pkgs.playwright-driver.browsers}";
          PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD = "1";
        };
        # the specs import `@playwright/test`, which node resolves by walking up node_modules, never NODE_PATH
        text = cdInto package + ''

          [ -d node_modules ] || npm ci >&2
          ln -sfn ${pkgs.playwright-test}/lib/node_modules ${lib.escapeShellArg config}/node_modules
          ${run}
        '';
      };
    };
  }
