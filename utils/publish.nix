# `nix run .#publish -- [-y|--yes] major|minor|patch [note]`: the next `vX.Y.Z` after the newest remote tag,
# annotated, pushed. The version lives in the tag, not in a manifest: `release-container.yml`
# ships the image on `v[0-9]+.*`, and a second copy of the number would be a second source for it.
pkgs: {
  type = "app";
  meta.description = "tag the next vX.Y.Z after the newest remote tag and push it: [-y|--yes] major|minor|patch [note]";
  program = pkgs.lib.getExe (pkgs.writeShellApplication {
    name = "publish";
    runtimeInputs = [ pkgs.git pkgs.gawk ];
    text = ''
      yes=""
      args=()
      for a in "$@"; do
        case "$a" in
          -y | --yes) yes=1 ;;
          *) args+=("$a") ;;
        esac
      done
      set -- "''${args[@]}"

      part="''${1:-}"
      case "$part" in
        major | minor | patch) ;;
        *) echo "usage: nix run .#publish -- [-y|--yes] major|minor|patch [release note]" >&2; exit 1 ;;
      esac
      [ -z "$(git status --porcelain)" ] || { echo "uncommitted changes — commit or stash first" >&2; exit 1; }
      shift
      note="$*"

      confirm() {
        [ -n "$yes" ] && return
        read -r -p "$1 [y/N] " ans # no tty → read fails → abort
        case "$ans" in y | Y | yes) ;; *) echo "aborted" >&2; exit 1 ;; esac
      }

      root="$(git rev-parse --show-toplevel)"
      if [ -f "$root/Cargo.toml" ] && [ -f "$root/.cargo/config.toml" ]; then
        # entries of `[patch.crates-io]`, plus `[patch.crates-io.<name>]` subtables
        patched="$(awk '
          /^[[:space:]]*\[/ { sec = 0 }
          /^[[:space:]]*\[patch\.crates-io\][[:space:]]*(#.*)?$/ { sec = 1; next }
          match($0, /^[[:space:]]*\[patch\.crates-io\.([^].]+)\]/, m) { print "  " m[1]; next }
          sec && /^[[:space:]]*[A-Za-z0-9_"-]+[[:space:]]*=/ { k = $0; sub(/[[:space:]]*=.*/, "", k); gsub(/[[:space:]"]/, "", k); print "  " k }
        ' "$root/.cargo/config.toml")"
        if [ -n "$patched" ]; then
          echo "[patch.crates-io] in .cargo/config.toml points these at local paths:" >&2
          echo "$patched" >&2
          echo "the build here never saw their published versions — make sure the versions this release depends on are actually published" >&2
          confirm "continue?"
        fi
      fi

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
