#!/usr/bin/env -S cargo -Zscript -q
---cargo
[package]
edition = "2024"

[dependencies]
clap = { version = "4", features = ["derive"] }
v_flakes = { path = "../..", features = ["toml"] }
---

use clap::Parser;

#[derive(Parser)]
struct Cli {
	#[command(flatten)]
	args: v_flakes::cargo_pre_ci::Cli,
}

fn main() {
	v_flakes::cargo_pre_ci::run(Cli::parse().args);
}
