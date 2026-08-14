# `cargo release` behind a gate: the include directives `cargo diet` derives are a function of the
# tree, so a release cut before they are refreshed publishes a tarball nobody reviewed. Diet writes
# them, we refuse to release while that write is uncommitted.
pkgs:
pkgs.writeShellApplication {
  name = "cpublish";
  runtimeInputs = with pkgs; [ cargo-diet cargo-release git jq ];
  # No rust here: cargo must be the repo's own toolchain, not one we pin.
  text = ''
    cd "$(git rev-parse --show-toplevel)"

    changed=()
    while read -r dir; do
      before="$(sha256sum <"$dir/Cargo.toml")"
      (cd "$dir" && cargo diet -q -r)
      [ "$before" = "$(sha256sum <"$dir/Cargo.toml")" ] || changed+=("$dir/Cargo.toml")
    done < <(cargo metadata --no-deps --format-version 1 \
      | jq -r '.workspace_default_members[]' | sed 's/#.*//; s|^path+file://||')

    if [ ''${#changed[@]} -gt 0 ]; then
      echo "cpublish: cargo diet rewrote ''${changed[*]} — review and commit, then re-run" >&2
      exit 1
    fi

    exec cargo release --no-confirm --execute "$@"
  '';
}
