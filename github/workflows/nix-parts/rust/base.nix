{
  jobs.pre_ci = {
    uses = "valeratrades/.github/.github/workflows/pre_ci.yml@main";
  };
  env = {
    CARGO_INCREMENTAL = "0"; # on large changes this just bloats ./target
    RUST_BACKTRACE = "short";
    CARGO_NET_RETRY = "10";
    RUSTUP_MAX_RETRIES = "10";
    # `.cargo/config.toml` sets `rustc-wrapper = "sccache"` for local dev; GHA runners have no
    # sccache on PATH, so empty this to disable the wrapper in CI (the nix-based container release
    # keeps sccache). Only the Errors/Warnings workflows inherit this env.
    RUSTC_WRAPPER = "";
  };
}

