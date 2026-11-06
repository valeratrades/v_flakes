{
  jobs.pre_ci = {
    uses = "valeratrades/.github/.github/workflows/pre_ci.yml@main";
  };
  env = {
    CARGO_INCREMENTAL = "0"; # on large changes this just bloats ./target
    RUST_BACKTRACE = "short";
    CARGO_NET_RETRY = "10";
    RUSTUP_MAX_RETRIES = "10";
    # `.cargo/config.toml` sets a `rustc-wrapper` for local dev that GHA runners don't have on PATH.
    # Only the Errors/Warnings workflows inherit this env.
    RUSTC_WRAPPER = "";
  };
}

