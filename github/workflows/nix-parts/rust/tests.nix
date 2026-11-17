{ lastSupportedVersion ? null, skipArgs, gistId }:
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
in
{
  timedIf = nightly; # the run a local one compares with
  job = {
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
      { uses = "Swatinem/rust-cache@v2"; } # after `cargo update`: the key hashes Cargo.lock
    ];
  };
  # `--workspace`: a bare invocation covers only `default-members`
  # timestamps go through `echo`, which install.nix leaves outside nix-shell
  work = [
    { run = "echo \"T0=$(date +%s)\" >> $GITHUB_ENV"; }
    { run = "cargo test --workspace --no-run"; } # before `check`, so it times the workspace build over cached deps
    { run = "echo \"T1=$(date +%s)\" >> $GITHUB_ENV"; }
    { run = "cargo check --workspace --all-targets"; }
    { run = "echo \"T2=$(date +%s)\" >> $GITHUB_ENV"; }
    { run = "cargo test --workspace${skipArgs}"; }
    { run = "echo \"T3=$(date +%s)\" >> $GITHUB_ENV"; }
  ];
  post = import ../shared/gist-badges.nix {
    inherit gistId;
    condition = "github.ref_name == github.event.repository.default_branch && ${nightly}";
    badges = {
      build = { label = "build"; message = "$(((T1-T0)/60))m $(((T1-T0)%60))s"; };
      test = { label = "test"; message = "$(((T3-T2)/60))m $(((T3-T2)%60))s"; };
    };
  };
}
