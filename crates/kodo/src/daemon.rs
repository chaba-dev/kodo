use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};

use crate::protocol::{PROTOCOL_VERSION, RequestEnvelope, ResponseEnvelope};
use crate::runner::Runner;

pub async fn serve_stdio(runner: &Runner) -> Result<(), std::io::Error> {
    serve(
        runner,
        tokio::io::BufReader::new(tokio::io::stdin()),
        tokio::io::stdout(),
    )
    .await
}

pub async fn serve(
    runner: &Runner,
    mut input: impl AsyncBufRead + Unpin,
    mut output: impl AsyncWrite + Unpin,
) -> Result<(), std::io::Error> {
    let mut line = String::new();
    while input.read_line(&mut line).await? != 0 {
        let response = handle_line(runner, line.trim_end()).await;
        output.write_all(response.as_bytes()).await?;
        output.write_all(b"\n").await?;
        output.flush().await?;
        line.clear();
    }
    Ok(())
}

async fn handle_line(runner: &Runner, line: &str) -> String {
    let response = match serde_json::from_str::<RequestEnvelope>(line) {
        Ok(request) if request.protocol_version == PROTOCOL_VERSION => {
            match runner.execute(request.request).await {
                Ok(response) => ResponseEnvelope::Success {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: request.request_id,
                    response,
                },
                Err(error) => ResponseEnvelope::Error {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: Some(request.request_id),
                    error: error.to_string(),
                },
            }
        }
        Ok(request) => ResponseEnvelope::Error {
            protocol_version: PROTOCOL_VERSION,
            request_id: Some(request.request_id),
            error: format!(
                "unsupported protocol version {}; expected {PROTOCOL_VERSION}",
                request.protocol_version
            ),
        },
        Err(error) => ResponseEnvelope::Error {
            protocol_version: PROTOCOL_VERSION,
            request_id: None,
            error: format!("invalid request: {error}"),
        },
    };

    serde_json::to_string(&response).expect("response envelope must serialize")
}

#[cfg(test)]
mod tests {
    use std::process::Command;

    use tempfile::TempDir;
    use uuid::Uuid;

    use super::*;
    use crate::protocol::{ToolRequest, ToolResult};
    use crate::workspace::Workspace;

    #[tokio::test]
    async fn serves_typed_requests_and_preserves_correlation_id() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let request_id = Uuid::new_v4();
        let request = serde_json::to_string(&RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            request: ToolRequest::GitStatus,
        })
        .unwrap();
        let mut input = request.into_bytes();
        input.push(b'\n');
        let mut output = Vec::new();

        serve(&runner, input.as_slice(), &mut output).await.unwrap();

        assert_eq!(
            serde_json::from_slice::<ResponseEnvelope>(&output).unwrap(),
            ResponseEnvelope::Success {
                protocol_version: PROTOCOL_VERSION,
                request_id,
                response: ToolResult::Output {
                    content: String::new(),
                    truncated: false,
                },
            }
        );
    }

    #[tokio::test]
    async fn rejects_unknown_protocol_versions() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let request_id = Uuid::new_v4();
        let request = serde_json::to_string(&RequestEnvelope {
            protocol_version: PROTOCOL_VERSION + 1,
            request_id,
            request: ToolRequest::GitStatus,
        })
        .unwrap();

        let response = handle_line(&runner, &request).await;
        let response: ResponseEnvelope = serde_json::from_str(&response).unwrap();

        assert!(matches!(
            response,
            ResponseEnvelope::Error {
                request_id: Some(id),
                ..
            } if id == request_id
        ));
    }

    fn git_repository() -> TempDir {
        let directory = TempDir::new().unwrap();
        let status = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(directory.path())
            .status()
            .unwrap();
        assert!(status.success());
        directory
    }
}
