# `js-local`: a JS project's own packages from their local checkouts, over what the package manager installed.
{ pkgs }:
pkgs.writeShellApplication {
  name = "js-local";
  runtimeInputs = [ pkgs.jq pkgs.coreutils ];
  text = ''
    map=_.js-local.json
    [ -e "$map" ] || exit 0
    jq -r 'to_entries[] | "\(.key)\t\(.value)"' "$map" | while IFS=$'\t' read -r name dir; do
      manifest="$dir/package.json"
      actual=$(jq -r .name "$manifest")
      [ "$actual" = "$name" ] || { echo "js-local: $map: $dir is $actual, not $name" >&2; exit 1; }
      jq -e 'has("files")' "$manifest" >/dev/null || { echo "js-local: $manifest has no \`files\`: what it publishes is unknown" >&2; exit 1; }
      [ -d node_modules ] || { echo "js-local: no node_modules; install the project first" >&2; exit 1; }
      if [ -e "node_modules/$name" ]; then
        # pnpm's is a link into its store, whose files are hard links to every project's: removed, never written through
        into=$(realpath "node_modules/$name")
        rm -rf "$into"
      else
        # not published yet, or only another of our packages depends on it: the checkout is its only copy
        into="node_modules/$name"
      fi
      mkdir -p "$into"
      cp "$manifest" "$into/"
      jq -r '.files[]' "$manifest" | while read -r f; do
        [ -e "$dir/$f" ] || { echo "js-local: $name: $dir/$f is not built (or \`files\` holds a glob)" >&2; exit 1; }
        cp -r "$dir/$f" "$into/$f"
      done
      # what npm would have linked: a package nothing installed yet has no `.bin` entries
      jq -r --arg n "''${name##*/}" 'if (.bin | type) == "string" then "\($n)\t\(.bin)" else (.bin // {} | to_entries[] | "\(.key)\t\(.value)") end' "$manifest" | while IFS=$'\t' read -r bin path; do
        mkdir -p node_modules/.bin
        ln -sfn "../$name/$path" "node_modules/.bin/$bin"
      done
      echo "js-local: $name@$(jq -r .version "$manifest") from $dir"
    done
  '';
}
