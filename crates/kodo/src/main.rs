use std::path::PathBuf;

use clap::{Parser, Subcommand};
use kodo::daemon;
use kodo::runner::Runner;
use kodo::workspace::Workspace;

#[derive(Debug, Parser)]
#[command(version, about = "Kodo local coding-agent runner")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Serve newline-delimited JSON tool requests over standard input and output.
    Daemon {
        /// A path inside the Git worktree to register.
        #[arg(long, default_value = ".")]
        workspace: PathBuf,
    },
}

#[tokio::main]
async fn main() {
    if let Err(error) = run().await {
        eprintln!("kodo: {error}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    match Cli::parse().command {
        Commands::Daemon { workspace } => {
            let workspace = Workspace::discover(workspace)?;
            daemon::serve_stdio(&Runner::new(workspace)).await?;
        }
    }
    Ok(())
}
