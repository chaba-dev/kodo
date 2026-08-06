use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex as StdMutex};

use futures_util::stream::{FuturesUnordered, StreamExt};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::protocol::{PROTOCOL_VERSION, RequestEnvelope, ResponseEnvelope, ToolRequest};
use crate::runner::Runner;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const MAX_CACHED_REQUESTS: usize = 1024;

#[derive(Clone)]
struct Dispatcher {
    runner: Runner,
    cache: Arc<StdMutex<ResponseCache>>,
}

#[derive(Default)]
struct ResponseCache {
    slots: HashMap<Uuid, Arc<Mutex<Option<CachedResponse>>>>,
    order: VecDeque<Uuid>,
}

struct CachedResponse {
    request: ToolRequest,
    response: String,
}

impl Dispatcher {
    fn new(runner: Runner) -> Self {
        Self {
            runner,
            cache: Arc::new(StdMutex::new(ResponseCache::default())),
        }
    }

    async fn dispatch(&self, request: RequestEnvelope) -> String {
        let slot = {
            let mut cache = self.cache.lock().expect("response cache lock poisoned");
            if let Some(slot) = cache.slots.get(&request.request_id) {
                Arc::clone(slot)
            } else {
                while cache.slots.len() >= MAX_CACHED_REQUESTS {
                    let Some(expired) = cache.order.pop_front() else {
                        break;
                    };
                    cache.slots.remove(&expired);
                }
                let slot = Arc::new(Mutex::new(None));
                cache.order.push_back(request.request_id);
                cache.slots.insert(request.request_id, Arc::clone(&slot));
                slot
            }
        };
        let mut cached = slot.lock().await;
        if let Some(cached) = cached.as_ref() {
            if cached.request == request.request {
                return cached.response.clone();
            }
            return serialize_response(ResponseEnvelope::Error {
                protocol_version: PROTOCOL_VERSION,
                request_id: Some(request.request_id),
                error: "request_id was already used for a different request".into(),
            });
        }

        let response = match self.runner.execute(request.request.clone()).await {
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
        };
        let response = serialize_response(response);
        *cached = Some(CachedResponse {
            request: request.request,
            response: response.clone(),
        });
        response
    }
}

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
    let dispatcher = Dispatcher::new(runner.clone());
    let mut line = String::new();
    let mut requests = FuturesUnordered::new();
    let mut input_closed = false;
    loop {
        if input_closed && requests.is_empty() {
            return Ok(());
        }

        tokio::select! {
            line_result = read_request_line(&mut input, &mut line), if !input_closed => {
                let result = line_result?;
                if matches!(result, RequestLine::Eof) {
                    input_closed = true;
                    continue;
                }
                let request_line = std::mem::take(&mut line);
                let dispatcher = dispatcher.clone();
                requests.push(async move {
                    match result {
                        RequestLine::Complete => handle_line(&dispatcher, &request_line).await,
                        RequestLine::TooLarge => oversized_request_response(),
                        RequestLine::Eof => unreachable!(),
                    }
                });
            }
            Some(response) = requests.next(), if !requests.is_empty() => {
                output.write_all(response.as_bytes()).await?;
                output.write_all(b"\n").await?;
                output.flush().await?;
            }
        }
    }
}

async fn handle_line(dispatcher: &Dispatcher, line: &str) -> String {
    if line.len() > MAX_REQUEST_BYTES {
        return oversized_request_response();
    }

    let response = match serde_json::from_str::<RequestEnvelope>(line) {
        Ok(request) if request.protocol_version == PROTOCOL_VERSION => {
            return dispatcher.dispatch(request).await;
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

    serialize_response(response)
}

enum RequestLine {
    Eof,
    Complete,
    TooLarge,
}

async fn read_request_line(
    input: &mut (impl AsyncBufRead + Unpin),
    line: &mut String,
) -> Result<RequestLine, std::io::Error> {
    let mut too_large = false;
    loop {
        let buffer = input.fill_buf().await?;
        if buffer.is_empty() {
            return Ok(if line.is_empty() {
                RequestLine::Eof
            } else if too_large {
                RequestLine::TooLarge
            } else {
                RequestLine::Complete
            });
        }

        let newline = buffer.iter().position(|byte| *byte == b'\n');
        let consumed = newline.map_or(buffer.len(), |position| position + 1);
        let content = &buffer[..newline.unwrap_or(buffer.len())];
        if !too_large && line.len() + content.len() <= MAX_REQUEST_BYTES {
            line.push_str(&String::from_utf8_lossy(content));
        } else {
            too_large = true;
        }
        input.consume(consumed);

        if newline.is_some() {
            return Ok(if too_large {
                RequestLine::TooLarge
            } else {
                RequestLine::Complete
            });
        }
    }
}

fn oversized_request_response() -> String {
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: None,
        error: format!("request exceeds {MAX_REQUEST_BYTES} byte transport limit"),
    })
}

fn serialize_response(response: ResponseEnvelope) -> String {
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
        let dispatcher = Dispatcher::new(runner);
        let request_id = Uuid::new_v4();
        let request = serde_json::to_string(&RequestEnvelope {
            protocol_version: PROTOCOL_VERSION + 1,
            request_id,
            request: ToolRequest::GitStatus,
        })
        .unwrap();

        let response = handle_line(&dispatcher, &request).await;
        let response: ResponseEnvelope = serde_json::from_str(&response).unwrap();

        assert!(matches!(
            response,
            ResponseEnvelope::Error {
                request_id: Some(id),
                ..
            } if id == request_id
        ));
    }

    #[tokio::test]
    async fn rejects_requests_larger_than_the_transport_limit() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let request = serde_json::to_string(&RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            request: ToolRequest::ApplyPatch {
                patch: "x".repeat(1_100_000),
            },
        })
        .unwrap();

        let response = handle_line(&dispatcher, &request).await;
        let ResponseEnvelope::Error { error, .. } =
            serde_json::from_str::<ResponseEnvelope>(&response).unwrap()
        else {
            panic!("expected oversized request error");
        };

        assert!(error.contains("request exceeds"));
    }

    #[tokio::test]
    async fn retrying_a_request_id_replays_the_original_response() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let request = serde_json::to_string(&RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            request: ToolRequest::StartCommand {
                command: "while true; do :; done".into(),
                cwd: String::new(),
                timeout_ms: 1_000,
            },
        })
        .unwrap();

        let first = handle_line(&dispatcher, &request).await;
        let retry = handle_line(&dispatcher, &request).await;

        assert_eq!(retry, first);
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
