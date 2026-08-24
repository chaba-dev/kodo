use std::path::PathBuf;

use clap::{Parser, Subcommand};
use kodo::control_plane;
use kodo::daemon;
use kodo::runner::Runner;
use kodo::session_cli::{self, Options, ResumeOptions, StartOptions};
use kodo::workspace::Workspace;

#[derive(Debug, Parser)]
#[command(version, about = "Kodo local coding-agent runner")]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}

#[derive(Debug, Subcommand)]
enum Commands {
    /// Start a durable agent session and host this workspace's runner.
    Start {
        /// Initial task sent to the agent.
        task: String,
        #[arg(long)]
        title: Option<String>,
        /// Override the balanced profile's primary model for this session.
        #[arg(long)]
        model: Option<String>,
        #[arg(long, default_value = "standard", value_parser = ["standard", "safe", "read-only"])]
        approval_policy: String,
        #[arg(
            long,
            env = "KODO_CONTROL_PLANE",
            default_value = "http://localhost:4451"
        )]
        control_plane: String,
        #[arg(
            long,
            env = "KODO_TOKEN",
            hide_env_values = true,
            allow_hyphen_values = true
        )]
        token: String,
        #[arg(long, default_value = ".")]
        workspace: PathBuf,
    },
    /// Resume and optionally continue a durable agent session.
    Resume {
        session_id: String,
        /// Optional follow-up message.
        message: Option<String>,
        #[arg(
            long,
            env = "KODO_CONTROL_PLANE",
            default_value = "http://localhost:4451"
        )]
        control_plane: String,
        #[arg(
            long,
            env = "KODO_TOKEN",
            hide_env_values = true,
            allow_hyphen_values = true
        )]
        token: String,
        #[arg(long, default_value = ".")]
        workspace: PathBuf,
    },
    /// Serve newline-delimited JSON tool requests over standard input and output.
    Daemon {
        /// A path inside the Git worktree to register.
        #[arg(long, default_value = ".")]
        workspace: PathBuf,
        /// Register with a loopback Phoenix control plane and serve over its WebSocket.
        #[arg(long)]
        control_plane: Option<String>,
        #[arg(
            long,
            env = "KODO_TOKEN",
            hide_env_values = true,
            allow_hyphen_values = true
        )]
        token: Option<String>,
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
        Commands::Start {
            task,
            title,
            model,
            approval_policy,
            control_plane,
            token,
            workspace,
        } => {
            session_cli::start(StartOptions {
                common: Options {
                    control_plane,
                    token,
                    workspace,
                },
                task,
                title,
                model,
                approval_policy,
            })
            .await?;
        }
        Commands::Resume {
            session_id,
            message,
            control_plane,
            token,
            workspace,
        } => {
            session_cli::resume(ResumeOptions {
                common: Options {
                    control_plane,
                    token,
                    workspace,
                },
                session_id,
                message,
            })
            .await?;
        }
        Commands::Daemon {
            workspace,
            control_plane: control_plane_url,
            token,
        } => {
            let workspace = Workspace::discover(workspace)?;
            if let Some(url) = control_plane_url {
                let token = token.ok_or("KODO_TOKEN is required with --control-plane")?;
                control_plane::serve(&url, &workspace, &token).await?;
            } else {
                let _runner_lock = workspace.lock_runner()?;
                let runner = Runner::new(workspace);
                daemon::serve_stdio(&runner).await?;
            }
        }
    }
    Ok(())
}
