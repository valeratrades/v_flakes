# The render itself: figma.yml runs this text as is, and so does `publish` with `figma.on = "publish"`.
# Needs FIGMA_FOLDER, and the bin's oauth.json and a folders:read token in its state dir.
''
  state="''${XDG_STATE_HOME:-$HOME/.local/state}/evinvest-figma-render"
  FIGMA_TOKEN="$(cat "$state/token")" nix run .#figma -- --folder "$FIGMA_FOLDER" --name "$(basename "$(git remote get-url origin)" .git)"
''
