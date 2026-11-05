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

    git diff --quiet HEAD -- Cargo.toml || { echo "cpublish: Cargo.toml has uncommitted changes" >&2; exit 1; }
    report="$(cargo diet -r)"
    # diet writes `include` on one line, which the pre-commit `cargo sort` splits; diffing unsorted would see a change on every run
    cargo sort --grouped >/dev/null
    if ! git diff --quiet -- Cargo.toml; then
      printf '%s\n' "$report" >&2
      git commit -m "chore: cargo diet" -- Cargo.toml
    fi

    cargo release --no-confirm --execute "$@"
    # nix consumers pin `?ref=release`, the same ref `cnix_release` maintains
    git push --force origin HEAD:refs/heads/release
  '';
}
