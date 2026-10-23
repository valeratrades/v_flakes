# `commit-msg` stage, not `pre-commit`: the message does not exist yet when
# pre-commit hooks run, so custom.sh cannot reach it.
{ pkgs }:
pkgs.writeShellApplication {
  name = "strip-claude-signature";
  runtimeInputs = [ pkgs.gnused ];
  text = ''
    if [ "$#" -eq 0 ]; then
      echo "strip-claude-signature: expected the commit-msg file path(s) as arguments" >&2
      exit 1
    fi

    for msg_file in "$@"; do
      if [ ! -f "$msg_file" ]; then
        echo "strip-claude-signature: $msg_file is not a file" >&2
        exit 1
      fi

      sed -i -E \
        -e '/^[[:space:]]*Co-authored-by:.*(Claude|noreply@anthropic\.com)/Id' \
        -e '/Generated with \[?Claude Code/Id' \
        "$msg_file"

      # command substitution eats the trailing blank lines the deletions left behind
      body=$(cat "$msg_file")
      printf '%s\n' "$body" > "$msg_file"
    done
  '';
}
