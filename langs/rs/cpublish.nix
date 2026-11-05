# `cargo release` after `cargo diet`: the include directives are a function of the tree, so they are
# refreshed and committed before every release.
#
# `-r`: diet's input is `cargo package --list`, which honours the include already in the manifest,
# so without it diet never sees a file added outside it.
pkgs: diet: cargoRoot:
pkgs.writeShellApplication {
  name = "cpublish";
  runtimeInputs = [ diet pkgs.cargo-sort pkgs.cargo-release pkgs.git ];
  # No rust here: cargo must be the repo's own toolchain, not one we pin.
  text = ''
    cd "$(git rev-parse --show-toplevel)/${cargoRoot}"

    yes=false
    args=()
    for a in "$@"; do
      case "$a" in
        -y | --yes) yes=true ;;
        *) args+=("$a") ;;
      esac
    done

    git diff --quiet HEAD -- Cargo.toml || { echo "cpublish: Cargo.toml has uncommitted changes" >&2; exit 1; }
    cargo diet -r >/dev/null
    # diet writes `include` on one line, which the pre-commit `cargo sort` splits; diffing unsorted would see a change on every run
    cargo sort --grouped >/dev/null
    if ! git diff --quiet -- Cargo.toml; then
      git --no-pager diff -- Cargo.toml >&2
      if $yes || { read -r -p "cpublish: commit this include rewrite? [y/N] " answer && [[ "$answer" == [yY] ]]; }; then
        git commit -m "chore: cargo diet" -- Cargo.toml
      else
        git checkout -- Cargo.toml # clean against HEAD on entry, so this drops only diet's rewrite
        exit 1
      fi
    fi

    cargo release --no-confirm --execute "''${args[@]}"
    # nix consumers pin `?ref=release`, the same ref `cnix_release` maintains
    git push --force origin HEAD:refs/heads/release
  '';
}
