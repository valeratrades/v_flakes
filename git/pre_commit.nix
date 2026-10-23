{ pkgs
, pname
, cargoNightly
, semverChecks ? false
, traceyCheck ? false
, styleFormat ? true
, styleAssert ? false
, moduleFlags ? ""
, # Lazy install hook for codestyle - runs at pre-commit time instead of shell entry
  codestyleLazyInstall ? ""
, # List of directory paths (relative to repo root) to exclude from sort-derives and codestyle, e.g. ["libs/nautilus_trader"]
  excludeDirs ? [ ]
, # Run `pnpm test:visual` (playwright) in the hook. Driven by the js module's
  # `preCommit.visual`. Runs outside the Cargo.toml guard — it is not rust-gated.
  jsVisual ? false
, # `git_ops` package whose `sync-labels` the hook starts detached; null when labels are off
  gitOps ? null
, # rs.cargoRoot: where the rust steps run
  cargoRoot
, # backwards compat
  styleCheck ? null
,
}:
let
  # Handle backwards compat: if styleCheck is explicitly passed, use it for both
  actualStyleFormat = if styleCheck != null then styleCheck else styleFormat;
  actualStyleAssert = if styleCheck != null then false else styleAssert;

  flag = cond: name: if cond then [ name ] else [ ];
  args = [ "--pname" pname "--cargo-root" cargoRoot ]
    ++ flag semverChecks "--semver-checks"
    ++ flag traceyCheck "--tracey-check"
    ++ flag actualStyleFormat "--style-format"
    ++ flag actualStyleAssert "--style-assert"
    ++ (if moduleFlags != "" then [ "--module-flags" moduleFlags ] else [ ])
    ++ builtins.concatMap (d: [ "--exclude-dir" d ]) excludeDirs
    ++ flag jsVisual "--js-visual"
    ++ (if gitOps != null then [ "--git-ops" "${gitOps}/bin/git_ops" ] else [ ])
    ++ (if codestyleLazyInstall != "" then [ "--codestyle-install" codestyleLazyInstall ] else [ ]);
in
pkgs.writeText "pre-commit-hook.sh" ''
  ${cargoNightly} -Zscript -q ${./pre-commit.rs} ${pkgs.lib.escapeShellArgs args} || exit 1
''
