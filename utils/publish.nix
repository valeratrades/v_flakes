# `nix run .#publish -- major|minor|patch [note]`: the next `vX.Y.Z` after the newest remote tag,
# annotated, pushed. The version lives in the tag, not in a manifest: `release-container.yml`
# ships the image on `v[0-9]+.*`, and a second copy of the number would be a second source for it.
pkgs: {
  type = "app";
  program = pkgs.lib.getExe (pkgs.writeShellApplication {
    name = "publish";
    runtimeInputs = [ pkgs.git ];
    text = ''
      part="''${1:-}"
      case "$part" in
        major | minor | patch) ;;
        *) echo "usage: nix run .#publish -- major|minor|patch [release note]" >&2; exit 1 ;;
      esac
      [ -z "$(git status --porcelain)" ] || { echo "uncommitted changes — commit or stash first" >&2; exit 1; }
      shift
      note="$*"

      git fetch --tags --force origin >/dev/null # not silenced: a stale tag list reuses a version
      last="$(git tag -l 'v*' --sort=-v:refname | head -n1)"
      ver="''${last#v}"; [ -n "$ver" ] || ver="0.0.0"
      ma="''${ver%%.*}"; rest="''${ver#*.}"; mi="''${rest%%.*}"; pa="''${rest##*.}"
      case "$part" in
        major) ma=$((ma + 1)); mi=0; pa=0 ;;
        minor) mi=$((mi + 1)); pa=0 ;;
        patch) pa=$((pa + 1)) ;;
      esac
      next="v$ma.$mi.$pa"
      echo "''${last:-<no tag>} → $next"

      # annotated: a lightweight tag has nowhere to put a note, and `push --follow-tags` skips it
      if [ -n "$note" ]; then
        printf '%s\n\n%s\n' "$next" "$note" | git tag -a "$next" -F -
      else
        git tag -a "$next" -m "$next"
      fi
      git push origin "$next"
    '';
  });
}
