{
  jobs.pre_ci = {
    uses = "valeratrades/.github/.github/workflows/pre_ci.yml@main";
  };
  env = {
    CARGO_INCREMENTAL = "0"; # on large changes this just bloats ./target
    RUST_BACKTRACE = "short";
    CARGO_NET_RETRY = "10";
    RUSTUP_MAX_RETRIES = "10";
    # the devshell exports kache as RUSTC_WRAPPER unless one is set; its store isn't kept on runners.
    # Only the Errors/Warnings workflows inherit this env.
    RUSTC_WRAPPER = "";
  };
}

