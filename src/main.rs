use clap::{Parser, Subcommand};
use v_flakes::{cargo_pre_ci, pyproject_merge};

#[derive(Parser)]
#[command(name = "v_flakes", version = concat!(env!("CARGO_PKG_VERSION"), " (", env!("GIT_HASH"), ")"))]
struct Cli {
	#[command(subcommand)]
	command: Command,
}

#[derive(Subcommand)]
enum Command {
	Toml {
		#[command(subcommand)]
		command: TomlCommand,
	},
}

#[derive(Subcommand)]
enum TomlCommand {
	Pyproject(pyproject_merge::Cli),
	CargoPreCi(cargo_pre_ci::Cli),
}

fn main() {
	let cli = Cli::parse();
	match cli.command {
		Command::Toml { command } => match command {
			TomlCommand::Pyproject(args) => pyproject_merge::run(args),
			TomlCommand::CargoPreCi(args) => cargo_pre_ci::run(args),
		},
	}
}
