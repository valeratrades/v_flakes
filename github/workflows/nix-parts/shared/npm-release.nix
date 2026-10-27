# Publishes one package through npm trusted publishing (OIDC): no token, no 2FA. npm accepts it
# only from the workflow file its trusted-publisher entry names (`release-npm.yml`, this repo).
# Fired by a `@<scope>/<pkg>-v<version>` tag; publishes `<packagesDir>/<pkg>`.
{ scope, packagesDir }:
{
  standalone = true;

  name = "release-npm";
  on = {
    push.tags = [ "@${scope}/*-v*" ];
    workflow_dispatch.inputs.tag = {
      description = "release tag, e.g. @${scope}/<pkg>-v1.2.3";
      required = true;
    };
  };
  permissions = {
    contents = "read";
    id-token = "write";
  };
  jobs.publish = {
    name = "\${{ inputs.tag || github.ref_name }}";
    runs-on = "ubuntu-latest";
    steps = [
      {
        name = "Read the tag";
        id = "tag";
        env.TAG = "\${{ inputs.tag || github.ref_name }}";
        run = ''
          name="''${TAG%-v*}"
          echo "tag=$TAG" >> "$GITHUB_OUTPUT"
          echo "dir=${packagesDir}/''${name#@${scope}/}" >> "$GITHUB_OUTPUT"
          echo "version=''${TAG##*-v}" >> "$GITHUB_OUTPUT"
        '';
      }
      {
        name = "Checkout the tag";
        uses = "actions/checkout@v5";
        "with".ref = "refs/tags/\${{ steps.tag.outputs.tag }}";
      }
      {
        name = "Set up Node";
        uses = "actions/setup-node@v5";
        "with" = {
          node-version = "24";
          registry-url = "https://registry.npmjs.org";
        };
      }
      # OIDC publishing needs npm >= 11.5.1
      { run = "npm install -g npm@latest"; }
      {
        # a `file:` dependency ships whatever `dist/` its directory holds
        name = "Build the packages it links by path";
        working-directory = "\${{ steps.tag.outputs.dir }}";
        run = ''
          node -e '
            const p = require("./package.json");
            for (const deps of [p.dependencies, p.devDependencies, p.peerDependencies])
              for (const v of Object.values(deps ?? {}))
                if (v.startsWith("file:")) console.log(v.slice(5));
          ' | while read -r dep; do
            (cd "$dep" && npm ci --ignore-scripts && npm run build)
          done
        '';
      }
      {
        name = "Publish";
        working-directory = "\${{ steps.tag.outputs.dir }}";
        env.VERSION = "\${{ steps.tag.outputs.version }}";
        run = ''
          test "$(node -p 'require("./package.json").version')" = "$VERSION"
          npm ci
          npm publish --access public
        '';
      }
    ];
  };
}
