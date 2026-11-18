{ cmd }:
{
  job = {
    name = "Miri";
    needs = "pre_ci";
    "if" = "needs.pre_ci.outputs.continue";
    runs-on = "ubuntu-latest";
    timeout-minutes = 45;
    steps = [
      { uses = "actions/checkout@v5"; }
      { uses = "dtolnay/rust-toolchain@miri"; }
      {
        name = "Download modified by pre-ci Cargo.toml files";
        uses = "actions/download-artifact@v7";
        "with".name = "modified-cargo-files";
      }
      { uses = "Swatinem/rust-cache@v2"; "with".cache-on-failure = true; } # a failing check is a normal run; its deps stay warm
      { run = "cargo miri setup"; }
    ];
  };
  work = [{ run = cmd; env.MIRIFLAGS = "-Zmiri-strict-provenance"; }];
}
