# Shared by release-npm.yml and js-tests: both run inside a package dir under `packagesDir`.
{
  nodeVersion = "24";
  # a `file:` dependency ships whatever `dist/` its directory holds
  buildFileDeps = ''
    node -e '
      const p = require("./package.json");
      for (const deps of [p.dependencies, p.devDependencies, p.peerDependencies])
        for (const v of Object.values(deps ?? {}))
          if (v.startsWith("file:")) console.log(v.slice(5));
    ' | while read -r dep; do
      (cd "$dep" && npm ci --ignore-scripts && npm run build) || exit 1
    done'';
}
