{ pkgs ? null
, nixpkgs ? null
, # config options
  #   lsp        : include `tinymist` (the typst language server) in the devShell.
  #   lineWidth  : typstyle `--line-width` (house style is wide, à la rustfmt
  #                max_width = 190 / ruff line-length = 210).
  #   indentWidth: typstyle `--indent-width` (spaces; typstyle has no hard-tab
  #                mode, unlike rustfmt/ruff, so `.typ` stays space-indented).
  #   src          : project root. Its `@preview/<name>:<version>` imports are
  #                  vendored into the `typst` this module ships, so `nix build` works
  #                  in the network-less sandbox.
  #   extraPackages: sources of imported packages absent from nixpkgs' typstPackages;
  #                  name/version come from their typst.toml, deps from their imports.
  #   main         : document entrypoint relative to `src`; enables `document`.
  #   html         : `document` also emits output.html.
  lsp ? false
, lineWidth ? 190
, indentWidth ? 2
, src ? null
, extraPackages ? [ ]
, main ? null
, html ? false
,
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

    With a document to build:
    ```nix
    typ = v-utils.typ {
      inherit pkgs;
      src = ./.;
      main = "src_typ/__main__.typ";
      html = true;
      extraPackages = [ inputs.some_unpublished_typst_pkg ];
    };
    packages.default = typ.document;   # $out/output.pdf (+ output.html)
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

  assert main != null -> src != null;
  assert html -> main != null;
  let
    inherit (pkgs) lib;
    utils = import ../../utils;

    # shortcut: a regex over the source, so an import whose spec is built at runtime is missed (the build then fails on download).
    previewImports = dir: lib.unique (lib.concatMap
      (f: builtins.filter builtins.isList (builtins.split "@preview/([a-z0-9-]+):([0-9]+\\.[0-9]+\\.[0-9]+)" (builtins.readFile f)))
      (builtins.filter (lib.hasSuffix ".typ") (lib.filesystem.listFilesRecursive dir)));

    extra = map (s: (builtins.fromTOML (builtins.readFile "${s}/typst.toml")).package // { src = s; }) extraPackages;

    resolve = imp:
      let
        name = builtins.elemAt imp 0;
        version = builtins.elemAt imp 1;
        e = lib.findFirst (e: e.name == name && e.version == version) null extra;
        attr = "${name}_${lib.replaceStrings [ "." ] [ "_" ] version}";
      in
      if e != null then
        pkgs.buildTypstPackage
          {
            pname = name;
            inherit version;
            inherit (e) src;
            typstDeps = map resolve (builtins.filter (i: builtins.head i != name) (previewImports e.src));
          }
      else
        pkgs.typstPackages.${attr} or (throw "typ: @preview/${name}:${version} is not in nixpkgs' typstPackages; pass its source via `extraPackages`");

    # TYPST_PACKAGE_PATH is searched before the download cache, so a freshly added import still downloads in the devShell.
    packagePath = lib.optionalString (src != null)
      "${pkgs.typst.passthru.wrapper { packages = _: map resolve (previewImports src); }}/lib/typst/packages";

    typst = pkgs.symlinkJoin {
      name = "typst-wrapped";
      paths = [ pkgs.typst ];
      nativeBuildInputs = [ pkgs.makeWrapper ];
      postBuild = ''
        wrapProgram $out/bin/typst --set-default TYPST_FEATURES html ${lib.optionalString (src != null) "--set TYPST_PACKAGE_PATH ${packagePath}"}
      '';
    };

    # The canonical typstyle invocation for this project's settings. Reused by
    # the shellHook (exposed as `typstyle-fmt` for ad-hoc use) and consumed by
    # files/treefmt.nix via the same `lineWidth`/`indentWidth` so the editor,
    # the dev-shell command, and the pre-commit pipeline never drift.
    typstyleFlags = "--line-width ${toString lineWidth} --indent-width ${toString indentWidth}";
  in
  {
    inherit lineWidth indentWidth typstyleFlags typst;

    enabledPackages = [ typst pkgs.typstyle ]
    ++ pkgs.lib.optional lsp pkgs.tinymist;

    # typstyle takes no config file, so there is nothing to copy. We only expose
    # a thin `typstyle-fmt` wrapper carrying this project's flags, so an ad-hoc
    # `typstyle-fmt .` matches exactly what treefmt/pre-commit would do.
    # Exported too for tinymist, which doesn't go through the typst wrapper.
    shellHook = utils.mkShellHook ''
      typstyle-fmt() { typstyle ${typstyleFlags} "$@"; }
      export TYPST_FEATURES=html
      ${lib.optionalString (src != null) "export TYPST_PACKAGE_PATH=${packagePath}"}
    '';
  } // lib.optionalAttrs (main != null) {
    document = pkgs.stdenvNoCC.mkDerivation {
      name = "typst-document";
      inherit src;
      nativeBuildInputs = [ typst ];
      buildPhase = ''
        typst compile ${main} output.pdf
        ${lib.optionalString html "typst compile ${main} output.html"}
      '';
      installPhase = "install -Dm444 -t $out output.pdf ${lib.optionalString html "output.html"}";
    };
  }
