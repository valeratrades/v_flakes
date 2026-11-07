# `npm test` in every `<packagesDir>/*` package that has a `test` script.
{ packagesDir }:
let npm = import ../shared/npm.nix; in
{
  name = "npm test";
  runs-on = "ubuntu-latest";
  timeout-minutes = 30;
  steps = [
    { uses = "actions/checkout@v5"; }
    {
      uses = "actions/setup-node@v5";
      "with" = {
        node-version = npm.nodeVersion;
        cache = "npm"; # ~/.npm, not node_modules: `npm ci` deletes node_modules first
        cache-dependency-path = "${packagesDir}/*/package-lock.json";
      };
    }
    {
      name = "Run tests";
      run = ''
        build_file_deps() {
        ${npm.buildFileDeps}
        }
        shopt -s nullglob
        ran=0
        failed=()
        for manifest in ${packagesDir}/*/package.json; do
          node -e 'process.exit(require(process.argv[1]).scripts?.test ? 0 : 1)' "$PWD/$manifest" || continue
          dir="$(dirname "$manifest")"
          ran=$((ran + 1))
          echo "::group::$dir"
          (cd "$dir" && build_file_deps && npm ci && npm test) || failed+=("$dir")
          echo "::endgroup::"
        done
        [ "$ran" -gt 0 ] || { echo "::error::no package under ${packagesDir}/ has a \`test\` script"; exit 1; }
        for dir in "''${failed[@]}"; do echo "::error::$dir: npm test failed"; done
        [ ''${#failed[@]} -eq 0 ]
      '';
    }
  ];
}
