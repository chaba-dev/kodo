use std::path::PathBuf;

use clap::{Parser, Subcommand};
use kodo::control_plane;
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
        /// Register with a loopback Phoenix control plane and serve over its WebSocket.
        #[arg(long)]
        control_plane: Option<String>,
    },
}

#[tokio::main]
async fn main() -> std::process::ExitCode {
    // Return normally so Tokio can drop process-group guards instead of orphaning commands.
    match run().await {
        Ok(()) => std::process::ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("kodo: {error}");
            std::process::ExitCode::FAILURE
        }
    }
}

async fn run() -> Result<(), Box<dyn std::error::Error>> {
    match Cli::parse().command {
        Commands::Daemon {
            workspace,
            control_plane: control_plane_url,
        } => {
            let workspace = Workspace::discover(workspace)?;
            if let Some(url) = control_plane_url {
                control_plane::serve(&url, &workspace).await?;
            } else {
                let runner = Runner::new(workspace);
                daemon::serve_stdio(&runner).await?;
            }
        }
    }
    Ok(())
}
