//! Concurrent newline-delimited JSON transport for the local runner.
//!
//! Dispatch is bounded and request IDs are idempotent: retries share one response slot, preventing
//! duplicate mutations while allowing completed responses to be replayed.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex as StdMutex};

use futures_util::stream::{FuturesUnordered, StreamExt};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::protocol::{PROTOCOL_VERSION, RequestEnvelope, ResponseEnvelope, ToolRequest};
use crate::runner::Runner;

const MAX_REQUEST_BYTES: usize = 1024 * 1024;
const MAX_CACHED_REQUESTS: usize = 1024;
const MAX_CACHED_RESPONSE_BYTES: usize = 16 * 1024 * 1024;
const MAX_IN_FLIGHT_REQUESTS: usize = 64;

#[derive(Clone)]
struct Dispatcher {
    runner: Runner,
    cache: Arc<StdMutex<ResponseCache>>,
}

#[derive(Default)]
struct ResponseCache {
    slots: HashMap<Uuid, Arc<ResponseSlot>>,
    // Store completed response sizes here so eviction never locks a slot while holding the cache.
    order: VecDeque<(Uuid, usize)>,
    response_bytes: usize,
}

struct ResponseSlot {
    // The fingerprint prevents a caller from reusing an id for different tool input.
    fingerprint: [u8; 32],
    // Holding this lock elects exactly one execution for concurrent retries of the same request.
    response: Mutex<Option<String>>,
}

impl Dispatcher {
    fn new(runner: Runner) -> Self {
        Self {
            runner,
            cache: Arc::new(StdMutex::new(ResponseCache::default())),
        }
    }

    async fn dispatch(&self, request: RequestEnvelope) -> String {
        let fingerprint = request_fingerprint(&request.request);
        let slot = {
            let mut cache = self.cache.lock().expect("response cache lock poisoned");
            if let Some(slot) = cache.slots.get(&request.request_id) {
                Arc::clone(slot)
            } else {
                while cache.slots.len() >= MAX_CACHED_REQUESTS {
                    let Some((expired, response_len)) = cache.order.pop_front() else {
                        return cache_capacity_response(request.request_id);
                    };
                    remove_cached_response(&mut cache, expired, response_len);
                }
                let slot = Arc::new(ResponseSlot {
                    fingerprint,
                    response: Mutex::new(None),
                });
                cache.slots.insert(request.request_id, Arc::clone(&slot));
                slot
            }
        };
        if slot.fingerprint != fingerprint {
            return serialize_response(ResponseEnvelope::Error {
                protocol_version: PROTOCOL_VERSION,
                request_id: Some(request.request_id),
                error: "request_id was already used for a different request".into(),
            });
        }

        let mut cached = slot.response.lock().await;
        if let Some(response) = cached.as_ref() {
            return response.clone();
        }

        let response = match self.runner.execute(request.request).await {
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
        *cached = Some(response.clone());
        // Never acquire the cache mutex while holding a slot: eviction follows the opposite order.
        drop(cached);
        let mut cache = self.cache.lock().expect("response cache lock poisoned");
        if cache
            .slots
            .get(&request.request_id)
            .is_some_and(|current| Arc::ptr_eq(current, &slot))
        {
            cache.response_bytes += response.len();
            cache.order.push_back((request.request_id, response.len()));
            while cache.response_bytes > MAX_CACHED_RESPONSE_BYTES {
                let Some((expired, response_len)) = cache.order.pop_front() else {
                    break;
                };
                remove_cached_response(&mut cache, expired, response_len);
            }
        }
        response
    }
}

fn request_fingerprint(request: &ToolRequest) -> [u8; 32] {
    Sha256::digest(
        serde_json::to_vec(request).expect("tool request must serialize for fingerprinting"),
    )
    .into()
}

fn remove_cached_response(cache: &mut ResponseCache, request_id: Uuid, response_len: usize) {
    cache.slots.remove(&request_id);
    cache.response_bytes = cache.response_bytes.saturating_sub(response_len);
}

fn cache_capacity_response(request_id: Uuid) -> String {
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: Some(request_id),
        error: "too many requests are currently in flight".into(),
    })
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
    let mut line = Vec::new();
    let mut requests = FuturesUnordered::new();
    let mut input_closed = false;
    loop {
        if input_closed && requests.is_empty() {
            return Ok(());
        }

        tokio::select! {
            line_result = read_request_line(&mut input, &mut line),
                if !input_closed && requests.len() < MAX_IN_FLIGHT_REQUESTS => {
                let result = line_result?;
                if matches!(result, RequestLine::Eof) {
                    // Stop accepting input but flush every already accepted request before exit.
                    input_closed = true;
                    continue;
                }
                let request_line = std::mem::take(&mut line);
                let dispatcher = dispatcher.clone();
                requests.push(async move {
                    match result {
                        RequestLine::Complete => match String::from_utf8(request_line) {
                            Ok(request_line) => handle_line(&dispatcher, &request_line).await,
                            Err(_) => invalid_utf8_response(),
                        },
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
    line: &mut Vec<u8>,
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
            line.extend_from_slice(content);
        } else {
            // Discard through the newline to preserve framing without retaining attacker input.
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

fn invalid_utf8_response() -> String {
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: None,
        error: "request is not valid UTF-8".into(),
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

    #[tokio::test]
    async fn completed_cache_entries_remain_evictable_during_replay() {
        let request_id = Uuid::new_v4();
        let response = "response".to_owned();
        let slot = Arc::new(ResponseSlot {
            fingerprint: [0; 32],
            response: Mutex::new(Some(response.clone())),
        });
        let replay = slot.response.lock().await;
        let mut cache = ResponseCache::default();
        cache.slots.insert(request_id, Arc::clone(&slot));
        cache.order.push_back((request_id, response.len()));
        cache.response_bytes = response.len();

        remove_cached_response(&mut cache, request_id, response.len());

        assert!(!cache.slots.contains_key(&request_id));
        assert_eq!(cache.response_bytes, 0);
        assert_eq!(replay.as_deref(), Some("response"));
    }

    #[tokio::test]
    async fn completes_the_model_free_fixture_workflow() {
        let repository = git_repository();
        std::fs::write(repository.path().join("file.txt"), "before\n").unwrap();
        git(repository.path(), ["add", "file.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);

        let read = dispatch(
            &dispatcher,
            ToolRequest::ReadFile {
                path: "file.txt".into(),
                offset: 0,
                limit: 10,
            },
        )
        .await;
        assert!(matches!(read, ToolResult::File { content, .. } if content == "before"));

        let changed = dispatch(
            &dispatcher,
            ToolRequest::ApplyPatch {
                patch: "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".into(),
            },
        )
        .await;
        assert_eq!(
            changed,
            ToolResult::FilesChanged {
                paths: vec!["file.txt".into()]
            }
        );

        let ToolResult::CommandStarted { process_id } = dispatch(
            &dispatcher,
            ToolRequest::StartCommand {
                command: "test \"$(cat file.txt)\" = after && printf verified".into(),
                cwd: String::new(),
                timeout_ms: 1_000,
            },
        )
        .await
        else {
            panic!("expected command process");
        };
        let mut after_sequence = 0;
        let mut command_output = String::new();
        tokio::time::timeout(std::time::Duration::from_secs(2), async {
            loop {
                let result = dispatch(
                    &dispatcher,
                    ToolRequest::PollCommand {
                        process_id,
                        after_sequence,
                    },
                )
                .await;
                let ToolResult::CommandPoll {
                    status,
                    output,
                    next_sequence,
                    ..
                } = result
                else {
                    panic!("expected command poll");
                };
                command_output.extend(output.into_iter().map(|chunk| chunk.content));
                after_sequence = next_sequence.saturating_sub(1);
                if status != crate::protocol::ProcessStatus::Running {
                    assert_eq!(
                        status,
                        crate::protocol::ProcessStatus::Exited { code: Some(0) }
                    );
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("verification command did not finish");
        assert_eq!(command_output, "verified");

        let diff = dispatch(&dispatcher, ToolRequest::GitDiff { paths: vec![] }).await;
        assert!(matches!(
            diff,
            ToolResult::Output { content, .. }
                if content.contains("-before") && content.contains("+after")
        ));
    }

    async fn dispatch(dispatcher: &Dispatcher, request: ToolRequest) -> ToolResult {
        let response = dispatcher
            .dispatch(RequestEnvelope {
                protocol_version: PROTOCOL_VERSION,
                request_id: Uuid::new_v4(),
                request,
            })
            .await;
        let ResponseEnvelope::Success { response, .. } =
            serde_json::from_str::<ResponseEnvelope>(&response).unwrap()
        else {
            panic!("expected successful response: {response}");
        };
        response
    }

    fn git_repository() -> TempDir {
        let directory = TempDir::new().unwrap();
        git(directory.path(), ["init", "--quiet"]);
        // Fixture commits must not depend on developer or CI runner global Git configuration.
        git(
            directory.path(),
            ["config", "user.email", "test@example.com"],
        );
        git(directory.path(), ["config", "user.name", "Test"]);
        directory
    }

    fn git<const N: usize>(directory: &std::path::Path, args: [&str; N]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(directory)
            .status()
            .unwrap();
        assert!(status.success());
    }
}
