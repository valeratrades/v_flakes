{ package ? null }:
let
  # `cargo docs-rs` refuses to guess a member, so drive it once per workspace member. It also
  # errors out on a member with no lib target, which a workspace's binary crate is, so ask
  # metadata which members have something to document rather than assuming every member does.
  cargoDocsCmd =
    if package != null
    then "cargo docs-rs -p ${package}"
    else ''
      for p in $(cargo metadata --no-deps --format-version 1 | jq -r '.packages[] | select([.targets[].kind[]] | any(. == "lib" or . == "proc-macro")) | .name'); do
        cargo docs-rs -p "$p"
      done
    '';
in
{
  name = "Documentation";
  needs = "pre_ci";
  "if" = "needs.pre_ci.outputs.continue";
  runs-on = "ubuntu-latest";
  timeout-minutes = 45;
  env.RUSTDOCFLAGS = "-Dwarnings";
  steps = [
    { uses = "actions/checkout@v4"; }
    { uses = "dtolnay/rust-toolchain@nightly"; }
    {
      name = "Download modified by pre-ci Cargo.toml files";
      uses = "actions/download-artifact@v4";
      "with".name = "modified-cargo-files";
    }
    { uses = "dtolnay/install@cargo-docs-rs"; }
    { run = cargoDocsCmd; }
  ];
}
