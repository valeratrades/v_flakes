# Publishes one package through npm trusted publishing (OIDC), else the `NPM_TOKEN` secret. OIDC is
# accepted only from the workflow file a package's trusted-publisher entry names (`release-npm.yml`, this repo).
# Fired by a `@<scope>/<pkg>-v<version>` tag; publishes `<packagesDir>/<pkg>`.
{ scope, packagesDir }:
let npm = import ./npm.nix; in
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
          node-version = npm.nodeVersion;
          registry-url = "https://registry.npmjs.org";
        };
      }
      # OIDC publishing needs npm >= 11.5.1
      { run = "npm install -g npm@latest"; }
      {
        name = "Build the packages it links by path";
        working-directory = "\${{ steps.tag.outputs.dir }}";
        run = npm.buildFileDeps;
      }
      {
        name = "Publish";
        working-directory = "\${{ steps.tag.outputs.dir }}";
        env = {
          VERSION = "\${{ steps.tag.outputs.version }}";
          # used only when OIDC is refused: an org-level `NPM_TOKEN` publishes packages not yet linked to this repo
          NODE_AUTH_TOKEN = "\${{ secrets.NPM_TOKEN }}";
        };
        run = ''
          test "$(node -p 'require("./package.json").version')" = "$VERSION"
          npm ci
          npm publish --access public || {
            echo "::error::npm refused $(node -p 'require("./package.json").name'): if it is new, or not yet linked to this repo, run \`npm-trust\` in the repo's dev shell"
            exit 1
          }
        '';
      }
    ];
  };
}
