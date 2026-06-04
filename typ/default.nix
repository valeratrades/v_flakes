{
  pkgs ? null,
  nixpkgs ? null,
  # config options
  #   lsp        : include `tinymist` (the typst language server) in the devShell.
  #   lineWidth  : typstyle `--line-width` (house style is wide, à la rustfmt
  #                max_width = 190 / ruff line-length = 210).
  #   indentWidth: typstyle `--indent-width` (spaces; typstyle has no hard-tab
  #                mode, unlike rustfmt/ruff, so `.typ` stays space-indented).
  lsp ? false,
  lineWidth ? 190,
  indentWidth ? 2,
}:
if nixpkgs != null && pkgs == null then {
  description = ''
Typst project configuration module: provides the `typst` compiler and the
`typstyle` formatter (and optionally the `tinymist` language server).

Unlike `rs`/`py`, typstyle is configured by CLI flags, not a repo config file,
so this module drops no `*.toml` — it pins the toolchain, bakes the formatter
settings into the treefmt pipeline (see files/treefmt.nix), and exposes a
ready-to-run format command.

Usage:
```nix
typ = v-utils.typ {
  inherit pkgs;
  lsp = false;        # include tinymist LSP (default: false)
  lineWidth = 190;    # typstyle --line-width (default: 190)
  indentWidth = 2;    # typstyle --indent-width (default: 2)
};
```

Then use in devShell:
```nix
devShells.default = pkgs.mkShell {
  shellHook = typ.shellHook;
  packages = [ ... ] ++ typ.enabledPackages;
};
```
'';
} else

let
  utils = import ../utils;

  # The canonical typstyle invocation for this project's settings. Reused by
  # the shellHook (exposed as `typstyle-fmt` for ad-hoc use) and consumed by
  # files/treefmt.nix via the same `lineWidth`/`indentWidth` so the editor,
  # the dev-shell command, and the pre-commit pipeline never drift.
  typstyleFlags = "--line-width ${toString lineWidth} --indent-width ${toString indentWidth}";
in
{
  inherit lineWidth indentWidth typstyleFlags;

  enabledPackages = [ pkgs.typst pkgs.typstyle ]
    ++ pkgs.lib.optional lsp pkgs.tinymist;

  # typstyle takes no config file, so there is nothing to copy. We only expose
  # a thin `typstyle-fmt` wrapper carrying this project's flags, so an ad-hoc
  # `typstyle-fmt .` matches exactly what treefmt/pre-commit would do.
  shellHook = utils.mkShellHook ''
    typstyle-fmt() { typstyle ${typstyleFlags} "$@"; }
  '';
}
