use std::path::PathBuf;

use clap::{Parser, Subcommand};
use kodo::control_plane;
use kodo::session_cli::{self, Options, ResumeOptions, StartOptions};
use kodo::workspace::Workspace;

#[derive(Debug, Parser)]
#[command(version, about = "Kodo local coding-agent runner")]
struct Cli {
    /// Connect this workspace's runner without starting an interactive client.
    #[arg(long)]
    headless: bool,
    /// Workspace hosted by a headless runner.
    #[arg(long, default_value = ".")]
    workspace: PathBuf,
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
    token: Option<String>,
    #[command(subcommand)]
    command: Option<Commands>,
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
    let cli = Cli::parse();
    if cli.headless {
        if cli.command.is_some() {
            return Err("--headless cannot be combined with an interactive command".into());
        }
        let token = cli
            .token
            .filter(|token| !token.trim().is_empty())
            .ok_or("KODO_TOKEN is required (or pass --token) with --headless")?;
        let workspace = Workspace::discover(cli.workspace)?;
        control_plane::serve_headless(&cli.control_plane, &workspace, &token).await?;
        return Ok(());
    }

    match cli.command {
        Some(Commands::Start {
            task,
            title,
            model,
            approval_policy,
            control_plane,
            token,
            workspace,
        }) => {
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
        Some(Commands::Resume {
            session_id,
            message,
            control_plane,
            token,
            workspace,
        }) => {
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
        None => {
            return Err(
                "the interactive TUI is not implemented yet; use start, resume, or --headless"
                    .into(),
            );
        }
    }
    Ok(())
}
