# `npm-trust`: puts every `@<scope>/*` package under <packagesDir> on npm trusted publishing from
# this repo's release-npm.yml. npm only links an existing package, never a scope, so a package
# not yet on the registry is published from here first. Every write needs 2FA: the first prompt
# offers to skip it for 5 minutes, which covers the rest of the run.
{ pkgs, scope, packagesDir }:
pkgs.writeShellApplication {
  name = "npm-trust";
  runtimeInputs = with pkgs; [ nodejs curl jq git ];
  text = ''
    root=$(git rev-parse --show-toplevel)
    repo=$(git -C "$root" remote get-url origin | sed -E 's#^(git@github\.com:|https://github\.com/)##; s#\.git$##')
    npmrc="''${XDG_STATE_HOME:-$HOME/.local/state}/v_flakes/npm-session.npmrc"
    mkdir -p "$(dirname "$npmrc")"
    touch "$npmrc"
    chmod 600 "$npmrc"
    export NPM_CONFIG_USERCONFIG="$npmrc"
    npm=(npx -y npm@latest)

    # trusted already when the latest version came from GitHub Actions with provenance from this repo
    trusted() {
      curl -fsS "https://registry.npmjs.org/''${1/\//%2f}" | jq -e --arg repo "$repo" '
        .versions[."dist-tags".latest] as $v
        | $v._npmUser.name == "GitHub Actions" and $v.dist.attestations != null
          and ($v.repository.url // "" | test("github\\.com/" + $repo + "(\\.git)?$"; "i"))
      ' >/dev/null
    }

    pending=()
    for pj in "$root/${packagesDir}"/*/package.json; do
      [ "$(jq -r '.private // false' "$pj")" = true ] && continue
      name=$(jq -r .name "$pj")
      [[ "$name" == @${scope}/* ]] || continue
      trusted "$name" || pending+=("$(dirname "$pj")")
    done
    if [ ''${#pending[@]} -eq 0 ]; then
      echo "npm-trust: every @${scope} package publishes from $repo"
      exit 0
    fi

    "''${npm[@]}" whoami >/dev/null 2>&1 || "''${npm[@]}" login --auth-type=web
    for dir in "''${pending[@]}"; do
      name=$(jq -r .name "$dir/package.json")
      if ! curl -fsS -o /dev/null "https://registry.npmjs.org/''${name/\//%2f}"; then
        echo "npm-trust: $name is not on npm yet, publishing it from here"
        (cd "$dir" && npm ci && "''${npm[@]}" publish --access public)
      fi
      echo "npm-trust: $name"
      # stderr only: npm asks for 2FA only while stdin and stdout are a terminal
      err=$(mktemp)
      "''${npm[@]}" trust github "$name" --file release-npm.yml --repo "$repo" --allow-publish -y 2> >(tee "$err" >&2) \
        || grep -qiE "already exists|E409" "$err" \
        || exit 1
      rm -f "$err"
      sleep 2 # npm's advice against its rate limit
    done
  '';
}
