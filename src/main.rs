use clap::{Parser, Subcommand};
use v_flakes::pyproject_merge;

#[derive(Parser)]
#[command(name = "v_flakes")]
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
}

fn main() {
	let cli = Cli::parse();
	match cli.command {
		Command::Toml { command } => match command {
			TomlCommand::Pyproject(args) => pyproject_merge::run(args),
		},
	}
}
