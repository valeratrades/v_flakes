{ lastSupportedVersion ? null, skipArgs }:
let
  rustcVersions =
    if lastSupportedVersion == null then
      builtins.trace "WARNING: lastSupportedVersion not provided for rust-tests. Matrix will only contain 'nightly'."
        [ "nightly" ]
    else
      [
        "nightly"
        "${lastSupportedVersion}"
      ];
  nightly = "matrix.rust == 'nightly'";
  # `seconds` is written on the `timedIf` leg only: the legs share job outputs, last writer wins
  timed = id: cmd: {
    inherit id;
    env.TIMED = "\${{ ${nightly} }}";
    run = ''
      start=$(date +%s)
      ${cmd}
      if [ "$TIMED" = true ]; then echo "seconds=$(($(date +%s) - start))" >> "$GITHUB_OUTPUT"; fi
    '';
  };
in
{
  timedIf = nightly; # the run a local one compares with
  badges = { build = "prepare_seconds"; test = "run_seconds"; };
  job = {
    outputs = {
      prepare_seconds = "\${{ steps.prepare.outputs.seconds }}";
      run_seconds = "\${{ steps.tests.outputs.seconds }}";
    };
    name = "Rust \${{matrix.rust}}";
    needs = "pre_ci";
    "if" = "needs.pre_ci.outputs.continue";
    runs-on = "ubuntu-latest";
    strategy = {
      fail-fast = false;
      matrix.rust = rustcVersions;
    };
    timeout-minutes = 45;
    steps = [
      {
        uses = "actions/checkout@v5";
      }
      {
        uses = "dtolnay/rust-toolchain@master";
        "with".toolchain = "\${{matrix.rust}}";
      }
      {
        #DEPRECATE: when nix-env sharing is better than dtolnay's pre_ci
        name = "Install mold";
        uses = "rui314/setup-mold@v1";
      }
      {
        # test this works
        name = "Set RUSTFLAGS for release branch";
        run = "echo \"RUSTFLAGS=-Dwarnings\" >> $GITHUB_ENV";
        "if" = "github.ref == 'refs/heads/release'";
      }
      {
        # workspace crates only: dependencies may statically assert their own layouts (rowan does)
        name = "Enable type layout randomization";
        run = ''
          printf '#!/bin/sh\nexec "$@" -Zrandomize-layout --cfg=exhaustive\n' > /tmp/randomize-layout.sh
          chmod +x /tmp/randomize-layout.sh
          echo RUSTC_WORKSPACE_WRAPPER=/tmp/randomize-layout.sh >> $GITHUB_ENV
        '';
        "if" = nightly;
      }
      {
        name = "Download modified by pre-ci Cargo.toml files";
        uses = "actions/download-artifact@v7";
        "with".name = "modified-cargo-files";
      }
      { run = "cargo update"; }
      { uses = "Swatinem/rust-cache@v2"; "with".cache-on-failure = true; } # after `cargo update`: the key hashes Cargo.lock
    ];
  };
  # `--workspace`: a bare invocation covers only `default-members`
  work = [
    (timed "prepare" "cargo test --workspace --no-run")
    (timed "tests" "cargo test --workspace${skipArgs}")
  ];
}
