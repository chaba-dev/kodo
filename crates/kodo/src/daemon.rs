//! Concurrent newline-delimited JSON transport for the local runner.
//!
//! Dispatch is bounded and request IDs are idempotent: retries share one response slot, preventing
//! duplicate mutations while allowing completed responses to be replayed.

use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex as StdMutex};

use futures_util::stream::{FuturesUnordered, StreamExt};
use sha2::{Digest, Sha256};
use tokio::io::{AsyncBufRead, AsyncBufReadExt, AsyncWrite, AsyncWriteExt};
use tokio::sync::{Mutex, Notify};
use uuid::Uuid;

use crate::authority::{AuthorityGuard, AuthorityRegistry};
use crate::protocol::{
    AuthorityLease, PROTOCOL_VERSION, RequestEnvelope, ResponseEnvelope, ToolRequest,
};
use crate::runner::Runner;

// Stdio framing and connection scheduling exist before any Phoenix policy is available.
const MAX_REQUEST_BYTES: usize = 1024 * 1024;
pub(crate) const MAX_IN_FLIGHT_REQUESTS: usize = 64;

#[derive(Clone)]
pub(crate) struct Dispatcher {
    runner: Runner,
    cache: Arc<StdMutex<ResponseCache>>,
    max_cached_requests: usize,
    max_cached_response_bytes: usize,
    max_error_bytes: usize,
    authorities: AuthorityRegistry,
}

#[derive(Default)]
struct ResponseCache {
    slots: HashMap<Uuid, Arc<ResponseSlot>>,
    // Evicted IDs remain tombstoned for this runner lifetime so a stale retry can never execute
    // the same mutation again after its response is no longer replayable.
    expired: HashMap<Uuid, [u8; 32]>,
    // Store completed response sizes here so eviction never locks a slot while holding the cache.
    order: VecDeque<(Uuid, usize)>,
    response_bytes: usize,
}

struct ResponseSlot {
    // The fingerprint prevents a caller from reusing an id for different tool input.
    fingerprint: [u8; 32],
    // Execution is elected on insertion; waiters only observe this result and may disconnect safely.
    response: Mutex<Option<String>>,
    notify: Notify,
}

impl Dispatcher {
    pub(crate) fn new(runner: Runner) -> Self {
        let max_cached_requests = runner.limits().max_cached_requests;
        let max_cached_response_bytes = runner.limits().max_cached_response_bytes;
        let max_error_bytes = runner.limits().max_output_bytes;
        Self {
            runner,
            cache: Arc::new(StdMutex::new(ResponseCache::default())),
            max_cached_requests,
            max_cached_response_bytes,
            max_error_bytes,
            authorities: AuthorityRegistry::default(),
        }
    }

    pub(crate) async fn dispatch(&self, request: RequestEnvelope) -> String {
        if request.protocol_version != PROTOCOL_VERSION {
            return unsupported_protocol_response(request.request_id, request.protocol_version);
        }
        let authority = match request.authority {
            Some(lease) => match self.authorities.grant(lease) {
                Ok(authority) => authority,
                Err(error) => return authority_error_response(request.request_id, error),
            },
            None => AuthorityGuard::unmanaged(),
        };
        self.dispatch_with_authority(request, authority).await
    }

    pub(crate) async fn dispatch_connected(&self, request: RequestEnvelope) -> String {
        if request.protocol_version != PROTOCOL_VERSION {
            return unsupported_protocol_response(request.request_id, request.protocol_version);
        }
        let Some(lease) = request.authority else {
            return missing_authority_response(request.request_id);
        };
        let authority = match self.authorities.grant(lease) {
            Ok(authority) => authority,
            Err(error) => return authority_error_response(request.request_id, error),
        };
        self.dispatch_with_authority(request, authority).await
    }

    pub(crate) fn renew_authority(
        &self,
        lease: AuthorityLease,
    ) -> Result<(), crate::authority::AuthorityError> {
        self.authorities.grant(lease).map(|_guard| ())
    }

    async fn dispatch_with_authority(
        &self,
        request: RequestEnvelope,
        authority: AuthorityGuard,
    ) -> String {
        let fingerprint = request_fingerprint(
            &request.request,
            request.authority.map(|lease| lease.session_id),
        );
        let (slot, elected) = {
            let mut cache = self.cache.lock().expect("response cache lock poisoned");
            if let Some(slot) = cache.slots.get(&request.request_id) {
                (Arc::clone(slot), false)
            } else if let Some(expired_fingerprint) = cache.expired.get(&request.request_id) {
                return expired_request_response(
                    request.request_id,
                    *expired_fingerprint == fingerprint,
                );
            } else {
                while cache.slots.len() >= self.max_cached_requests {
                    let Some((expired, response_len)) = cache.order.pop_front() else {
                        return cache_capacity_response(request.request_id);
                    };
                    remove_cached_response(&mut cache, expired, response_len);
                }
                let slot = Arc::new(ResponseSlot {
                    fingerprint,
                    response: Mutex::new(None),
                    notify: Notify::new(),
                });
                cache.slots.insert(request.request_id, Arc::clone(&slot));
                (slot, true)
            }
        };
        if slot.fingerprint != fingerprint {
            return serialize_response(ResponseEnvelope::Error {
                protocol_version: PROTOCOL_VERSION,
                request_id: Some(request.request_id),
                error: "request_id was already used for a different request".into(),
            });
        }

        if elected {
            self.spawn_execution(request, authority, Arc::clone(&slot));
        }

        wait_for_response(slot).await
    }

    fn spawn_execution(
        &self,
        request: RequestEnvelope,
        authority: AuthorityGuard,
        slot: Arc<ResponseSlot>,
    ) {
        let runner = self.runner.clone();
        let cache = Arc::clone(&self.cache);
        let max_cached_response_bytes = self.max_cached_response_bytes;
        let max_error_bytes = self.max_error_bytes;
        tokio::spawn(async move {
            // Execution outlives any transport waiter so reconnect retries cannot duplicate a
            // blocking mutation whose original WebSocket disappeared.
            let result = runner.execute_authorized(request.request, authority).await;
            let response = match result {
                Ok(response) => ResponseEnvelope::Success {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: request.request_id,
                    response,
                },
                Err(error) => ResponseEnvelope::Error {
                    protocol_version: PROTOCOL_VERSION,
                    request_id: Some(request.request_id),
                    // Request-derived paths can make errors arbitrarily large; keep failures under
                    // the same policy budget as successful tool content before caching/transport.
                    error: truncate_utf8(error.to_string(), max_error_bytes),
                },
            };

            let response = serialize_response(response);
            *slot.response.lock().await = Some(response.clone());
            slot.notify.notify_waiters();
            let mut cache = cache.lock().expect("response cache lock poisoned");
            if cache
                .slots
                .get(&request.request_id)
                .is_some_and(|current| Arc::ptr_eq(current, &slot))
            {
                cache.response_bytes += response.len();
                cache.order.push_back((request.request_id, response.len()));
                while cache.response_bytes > max_cached_response_bytes {
                    let Some((expired, response_len)) = cache.order.pop_front() else {
                        break;
                    };
                    remove_cached_response(&mut cache, expired, response_len);
                }
            }
        });
    }
}

fn truncate_utf8(mut content: String, max_bytes: usize) -> String {
    if content.len() <= max_bytes {
        return content;
    }
    let mut end = max_bytes;
    while !content.is_char_boundary(end) {
        end -= 1;
    }
    content.truncate(end);
    content
}

async fn wait_for_response(slot: Arc<ResponseSlot>) -> String {
    loop {
        let notified = slot.notify.notified();
        if let Some(response) = slot.response.lock().await.as_ref() {
            return response.clone();
        }
        notified.await;
    }
}

fn request_fingerprint(request: &ToolRequest, session_id: Option<Uuid>) -> [u8; 32] {
    Sha256::digest(
        serde_json::to_vec(&(session_id, request))
            .expect("tool request must serialize for fingerprinting"),
    )
    .into()
}

fn remove_cached_response(cache: &mut ResponseCache, request_id: Uuid, response_len: usize) {
    if let Some(slot) = cache.slots.remove(&request_id) {
        cache.expired.insert(request_id, slot.fingerprint);
    }
    cache.response_bytes = cache.response_bytes.saturating_sub(response_len);
}

fn expired_request_response(request_id: Uuid, fingerprint_matches: bool) -> String {
    let error = if fingerprint_matches {
        "request completed previously, but its response is no longer available; it was not re-executed"
    } else {
        "request_id was already used for a different request"
    };
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: Some(request_id),
        error: error.into(),
    })
}

fn cache_capacity_response(request_id: Uuid) -> String {
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: Some(request_id),
        error: "too many requests are currently in flight".into(),
    })
}

fn unsupported_protocol_response(request_id: Uuid, protocol_version: u16) -> String {
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: Some(request_id),
        error: format!(
            "unsupported protocol version {protocol_version}; expected {PROTOCOL_VERSION}"
        ),
    })
}

fn missing_authority_response(request_id: Uuid) -> String {
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: Some(request_id),
        error: "connected runner request omitted its authority lease".into(),
    })
}

fn authority_error_response(request_id: Uuid, error: crate::authority::AuthorityError) -> String {
    serialize_response(ResponseEnvelope::Error {
        protocol_version: PROTOCOL_VERSION,
        request_id: Some(request_id),
        error: error.to_string(),
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
        Ok(request) => return dispatcher.dispatch(request).await,
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
    use std::os::unix::fs::PermissionsExt;
    use std::process::Command;
    use std::time::Duration;

    use tempfile::TempDir;
    use uuid::Uuid;

    use super::*;
    use crate::protocol::{AuthorityLease, ExecutionLimits, ToolRequest, ToolResult};
    use crate::runner::PatchMutationGate;
    use crate::workspace::Workspace;

    #[tokio::test]
    async fn serves_typed_requests_and_preserves_correlation_id() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let request_id = Uuid::new_v4();
        let request = serde_json::to_string(&RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            authority: None,
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
            protocol_version: 2,
            request_id,
            authority: None,
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
    async fn connected_dispatch_rejects_requests_without_an_authority_lease() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let request_id = Uuid::new_v4();

        let response = dispatcher
            .dispatch_connected(RequestEnvelope {
                protocol_version: PROTOCOL_VERSION,
                request_id,
                authority: None,
                request: ToolRequest::GitStatus,
            })
            .await;
        let ResponseEnvelope::Error { error, .. } = serde_json::from_str(&response).unwrap() else {
            panic!("expected missing authority error");
        };

        assert!(error.contains("omitted its authority lease"));
    }

    #[tokio::test]
    async fn rejects_requests_larger_than_the_transport_limit() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let request = serde_json::to_string(&RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            authority: None,
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
            authority: None,
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
    async fn bounded_errors_remain_in_the_smallest_valid_replay_cache() {
        let repository = git_repository();
        let mut limits = ExecutionLimits::standalone();
        limits.max_output_bytes = 32;
        limits.max_results = 1;
        limits.max_process_output_chunks = 1;
        limits.max_cached_response_bytes = limits.maximum_encoded_response_bytes().unwrap();
        let runner =
            Runner::from_limits(Workspace::from_root(repository.path()).unwrap(), limits).unwrap();
        let dispatcher = Dispatcher::new(runner);
        let request_id = Uuid::new_v4();
        let request = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            authority: None,
            request: ToolRequest::ReadFile {
                path: format!("/{}", "x".repeat(10_000)),
                offset: 0,
                limit: 1,
            },
        };

        let response = dispatcher.dispatch(request.clone()).await;
        let retry = dispatcher.dispatch(request).await;
        let ResponseEnvelope::Error { error, .. } =
            serde_json::from_str::<ResponseEnvelope>(&response).unwrap()
        else {
            panic!("expected path validation error");
        };

        assert!(error.len() <= 32);
        assert_eq!(retry, response);
        assert!(
            dispatcher
                .cache
                .lock()
                .unwrap()
                .slots
                .contains_key(&request_id)
        );
    }

    #[tokio::test]
    async fn cancelling_a_waiter_does_not_cancel_or_repeat_execution() {
        let repository = git_repository();
        std::fs::write(repository.path().join("file.txt"), "before\n").unwrap();
        git(repository.path(), ["add", "file.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let request_id = Uuid::new_v4();
        let request = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            authority: None,
            request: ToolRequest::ApplyPatch {
                patch: "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".into(),
            },
        };
        let first = {
            let dispatcher = dispatcher.clone();
            let request = request.clone();
            tokio::spawn(async move { dispatcher.dispatch(request).await })
        };
        loop {
            if dispatcher
                .cache
                .lock()
                .expect("response cache lock poisoned")
                .slots
                .contains_key(&request_id)
            {
                break;
            }
            tokio::task::yield_now().await;
        }
        first.abort();

        let retry = dispatcher.dispatch(request).await;
        let response = serde_json::from_str::<ResponseEnvelope>(&retry).unwrap();

        assert!(matches!(response, ResponseEnvelope::Success { .. }));
        assert_eq!(
            std::fs::read_to_string(repository.path().join("file.txt")).unwrap(),
            "after\n"
        );
    }

    #[tokio::test]
    async fn superseding_an_authority_lease_stops_its_running_command_before_mutation() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let session_id = Uuid::new_v4();
        let request = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            authority: Some(AuthorityLease {
                session_id,
                ownership_epoch: 1,
                ttl_ms: 1_000,
            }),
            request: ToolRequest::StartCommand {
                command: "sleep 0.2; printf mutated > lease.txt".into(),
                cwd: String::new(),
                timeout_ms: 2_000,
            },
        };

        let response = dispatcher.dispatch_connected(request).await;
        assert!(matches!(
            serde_json::from_str::<ResponseEnvelope>(&response).unwrap(),
            ResponseEnvelope::Success { .. }
        ));

        dispatcher
            .renew_authority(AuthorityLease {
                session_id,
                ownership_epoch: 2,
                ttl_ms: 1_000,
            })
            .unwrap();

        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        assert!(!repository.path().join("lease.txt").exists());
    }

    #[tokio::test]
    async fn expiring_an_authority_lease_stops_its_running_command_before_mutation() {
        let repository = git_repository();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let request = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            authority: Some(AuthorityLease {
                session_id: Uuid::new_v4(),
                ownership_epoch: 1,
                ttl_ms: 50,
            }),
            request: ToolRequest::StartCommand {
                command: "sleep 0.2; printf mutated > lease.txt".into(),
                cwd: String::new(),
                timeout_ms: 2_000,
            },
        };

        let response = dispatcher.dispatch_connected(request).await;
        assert!(matches!(
            serde_json::from_str::<ResponseEnvelope>(&response).unwrap(),
            ResponseEnvelope::Success { .. }
        ));

        tokio::time::sleep(std::time::Duration::from_millis(400)).await;
        assert!(!repository.path().join("lease.txt").exists());
    }

    #[tokio::test]
    async fn superseding_authority_after_patch_preflight_aborts_the_git_mutation() {
        let repository = git_repository();
        std::fs::write(repository.path().join("file.txt"), "before\n").unwrap();
        git(repository.path(), ["add", "file.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        let gate = PatchMutationGate::new();
        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap())
            .with_patch_mutation_gate(Arc::clone(&gate));
        let dispatcher = Dispatcher::new(runner);
        let session_id = Uuid::new_v4();
        let request = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            authority: Some(AuthorityLease {
                session_id,
                ownership_epoch: 1,
                ttl_ms: 1_000,
            }),
            request: ToolRequest::ApplyPatch {
                patch: "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".into(),
            },
        };
        let execution = {
            let dispatcher = dispatcher.clone();
            tokio::spawn(async move { dispatcher.dispatch_connected(request).await })
        };

        gate.wait_until_spawned().await;
        dispatcher
            .renew_authority(AuthorityLease {
                session_id,
                ownership_epoch: 2,
                ttl_ms: 1_000,
            })
            .unwrap();
        gate.release();

        let response = execution.await.unwrap();
        assert!(matches!(
            serde_json::from_str::<ResponseEnvelope>(&response).unwrap(),
            ResponseEnvelope::Error { .. }
        ));
        assert_eq!(
            std::fs::read_to_string(repository.path().join("file.txt")).unwrap(),
            "before\n"
        );
    }

    #[tokio::test]
    async fn superseding_authority_terminates_git_apply_filter_descendants() {
        let repository = git_repository();
        std::fs::write(repository.path().join("file.txt"), "before\n").unwrap();
        std::fs::write(
            repository.path().join(".gitattributes"),
            "file.txt filter=blocking\n",
        )
        .unwrap();
        let filter = repository.path().join("blocking-filter.sh");
        std::fs::write(
            &filter,
            "#!/bin/sh\ntouch filter-started\ncat\nsleep 0.4\nprintf escaped > escaped.txt\n",
        )
        .unwrap();
        let mut permissions = std::fs::metadata(&filter).unwrap().permissions();
        permissions.set_mode(0o755);
        std::fs::set_permissions(&filter, permissions).unwrap();
        git(repository.path(), ["add", "file.txt", ".gitattributes"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        git(
            repository.path(),
            ["config", "filter.blocking.smudge", "./blocking-filter.sh"],
        );

        let runner = Runner::new(Workspace::from_root(repository.path()).unwrap());
        let dispatcher = Dispatcher::new(runner);
        let session_id = Uuid::new_v4();
        let request = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            authority: Some(AuthorityLease {
                session_id,
                ownership_epoch: 1,
                ttl_ms: 5_000,
            }),
            request: ToolRequest::ApplyPatch {
                patch: "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".into(),
            },
        };
        let execution = {
            let dispatcher = dispatcher.clone();
            tokio::spawn(async move { dispatcher.dispatch_connected(request).await })
        };

        tokio::time::timeout(Duration::from_secs(1), async {
            while !repository.path().join("filter-started").exists() {
                tokio::time::sleep(Duration::from_millis(5)).await;
            }
        })
        .await
        .expect("Git apply filter did not start");
        dispatcher
            .renew_authority(AuthorityLease {
                session_id,
                ownership_epoch: 2,
                ttl_ms: 5_000,
            })
            .unwrap();

        let response = tokio::time::timeout(Duration::from_secs(1), execution)
            .await
            .expect("cancelled patch did not return promptly")
            .unwrap();
        assert!(matches!(
            serde_json::from_str::<ResponseEnvelope>(&response).unwrap(),
            ResponseEnvelope::Error { .. }
        ));
        tokio::time::sleep(Duration::from_millis(500)).await;
        assert!(!repository.path().join("escaped.txt").exists());
    }

    #[tokio::test]
    async fn completed_cache_entries_remain_evictable_during_replay() {
        let request_id = Uuid::new_v4();
        let response = "response".to_owned();
        let slot = Arc::new(ResponseSlot {
            fingerprint: [0; 32],
            response: Mutex::new(Some(response.clone())),
            notify: Notify::new(),
        });
        let replay = slot.response.lock().await;
        let mut cache = ResponseCache::default();
        cache.slots.insert(request_id, Arc::clone(&slot));
        cache.order.push_back((request_id, response.len()));
        cache.response_bytes = response.len();

        remove_cached_response(&mut cache, request_id, response.len());

        assert!(!cache.slots.contains_key(&request_id));
        assert!(cache.expired.contains_key(&request_id));
        assert_eq!(cache.response_bytes, 0);
        assert_eq!(replay.as_deref(), Some("response"));
    }

    #[tokio::test]
    async fn evicted_request_ids_are_never_executed_again() {
        let repository = git_repository();
        std::fs::write(repository.path().join("file.txt"), "before\n").unwrap();
        git(repository.path(), ["add", "file.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        let mut limits = ExecutionLimits::standalone();
        limits.max_cached_requests = 1;
        let runner =
            Runner::from_limits(Workspace::from_root(repository.path()).unwrap(), limits).unwrap();
        let dispatcher = Dispatcher::new(runner);
        let request = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id: Uuid::new_v4(),
            authority: None,
            request: ToolRequest::ApplyPatch {
                patch: "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".into(),
            },
        };

        let first = dispatcher.dispatch(request.clone()).await;
        let ResponseEnvelope::Success { .. } = serde_json::from_str(&first).unwrap() else {
            panic!("expected the initial mutation to succeed");
        };
        dispatch(&dispatcher, ToolRequest::GitStatus).await;

        let retry = dispatcher.dispatch(request).await;
        let ResponseEnvelope::Error { error, .. } = serde_json::from_str(&retry).unwrap() else {
            panic!("expected an expired replay error");
        };
        assert!(error.contains("was not re-executed"));
        assert_eq!(
            std::fs::read_to_string(repository.path().join("file.txt")).unwrap(),
            "after\n"
        );
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
                authority: None,
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
