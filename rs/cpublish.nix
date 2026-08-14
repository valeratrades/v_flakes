# `cargo release` behind a gate: the include directives `cargo diet` derives are a function of the
# tree, so a release cut before they are refreshed publishes a tarball nobody reviewed.
#
# `-n -r`: diet's input is `cargo package --list`, which itself honours the include already in the
# manifest — so without `-r` diet never sees a file added outside it and reports "lean" forever.
# `-r` restores full visibility, and `-n` makes it a read: diet clears the manifest only long
# enough to take the listing, then writes the original bytes back. Deciding what to do about a
# reported change is the human's, so nothing here rewrites a manifest.
pkgs: diet:
pkgs.writeShellApplication {
  name = "cpublish";
  runtimeInputs = [ diet pkgs.cargo-release pkgs.git ];
  # No rust here: cargo must be the repo's own toolchain, not one we pin.
  text = ''
    cd "$(git rev-parse --show-toplevel)"

    report="$(cargo diet -n -r)"
    case "$report" in
      *"WOULD be made"*)
        printf '%s\n' "$report" >&2
        # `cargo diet` without -r cannot apply this: its own input is filtered through the include
        # it would be rewriting, so it reports lean and the gate blocks forever.
        echo "cpublish: cargo diet has include directives to rewrite — run 'cargo diet -r', review, commit, then re-run" >&2
        exit 1 ;;
      *"There would be no change."*) ;;
      # Neither phrase means diet's output format moved under us and the gate is no longer reading
      # anything — a gate that cannot tell must not pass.
      *) printf '%s\n' "$report" >&2
         echo "cpublish: could not read cargo diet's verdict from its output" >&2
         exit 1 ;;
    esac

    exec cargo release --no-confirm --execute "$@"
  '';
}
