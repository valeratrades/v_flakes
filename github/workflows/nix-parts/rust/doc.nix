{ cargoDocsCmd }:
{
  job = {
    name = "Documentation";
    needs = "pre_ci";
    "if" = "needs.pre_ci.outputs.continue";
    runs-on = "ubuntu-latest";
    timeout-minutes = 45;
    env.RUSTDOCFLAGS = "-Dwarnings";
    steps = [
      { uses = "actions/checkout@v5"; }
      { uses = "dtolnay/rust-toolchain@nightly"; }
      {
        name = "Download modified by pre-ci Cargo.toml files";
        uses = "actions/download-artifact@v7";
        "with".name = "modified-cargo-files";
      }
      { uses = "dtolnay/install@cargo-docs-rs"; }
      { run = "rm -f \"$GITHUB_WORKSPACE/.cargo/config.toml\" \"$GITHUB_WORKSPACE/.cargo/config\""; } # local-dev flags (mold linker, `-Z threads`) the runner doesn't have
      { uses = "Swatinem/rust-cache@v2"; }
    ];
  };
  work = [{ run = cargoDocsCmd; }];
}
