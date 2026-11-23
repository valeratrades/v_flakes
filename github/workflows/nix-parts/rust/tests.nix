# The tests on `version`'s toolchain, on release tags only: every other push runs rust-tests in the shell's own (catalog.nix).
{ version, skipArgs }:
let
  nightly = builtins.substring 0 7 version == "nightly";
in
{
  job = {
    name = "Rust ${version}";
    needs = "pre_ci";
    "if" = "needs.pre_ci.outputs.continue && startsWith(github.ref, 'refs/tags/v')";
    runs-on = "ubuntu-latest";
    timeout-minutes = 45;
    steps = [
      { uses = "actions/checkout@v5"; }
      {
        uses = "dtolnay/rust-toolchain@master";
        "with".toolchain = version;
      }
      {
        name = "Install mold";
        uses = "rui314/setup-mold@v1";
      }
    ] ++ (if nightly then [{
      # workspace crates only: dependencies may statically assert their own layouts (rowan does)
      name = "Enable type layout randomization";
      run = ''
        printf '#!/bin/sh\nexec "$@" -Zrandomize-layout --cfg=exhaustive\n' > /tmp/randomize-layout.sh
        chmod +x /tmp/randomize-layout.sh
        echo RUSTC_WORKSPACE_WRAPPER=/tmp/randomize-layout.sh >> $GITHUB_ENV
      '';
    }] else [ ]) ++ [
      {
        name = "Download modified by pre-ci Cargo.toml files";
        uses = "actions/download-artifact@v7";
        "with".name = "modified-cargo-files";
      }
      { run = "cargo update"; }
      { uses = "Swatinem/rust-cache@v2"; "with".save-if = false; } # a tag's caches are its own: no later run reads them
    ];
  };
  # `--workspace`: a bare invocation covers only `default-members`
  work = [{ run = "cargo test --workspace${skipArgs}"; }];
}
