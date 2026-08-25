//! Authenticated Phoenix Channels transport for a loopback control plane.

use std::net::IpAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt, stream::FuturesUnordered};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;
use tokio::sync::oneshot;
use tokio::time::{Instant, interval_at, sleep};
use tokio_tungstenite::{MaybeTlsStream, WebSocketStream, connect_async_with_config, tungstenite};
use url::{Host, Url};

use crate::daemon::{Dispatcher, MAX_IN_FLIGHT_REQUESTS};
use crate::protocol::{AuthorityLease, ExecutionLimits, PROTOCOL_VERSION, RequestEnvelope};
use crate::runner::Runner;
use crate::workspace::Workspace;

// Keep this protocol boundary synchronized with Kodo.RunnerProtocol on the Phoenix side.
const MAX_WIRE_BYTES: usize = 4 * 1024 * 1024;
// Registration metadata is tiny; this generous cap bounds a compromised local control plane.
const MAX_REGISTRATION_BYTES: usize = 256 * 1024;
// Reconnects back off enough to avoid a hot loop while still recovering promptly for local use.
const INITIAL_RECONNECT_DELAY: Duration = Duration::from_secs(1);
const MAX_RECONNECT_DELAY: Duration = Duration::from_secs(30);
const HEARTBEAT_INTERVAL: Duration = Duration::from_secs(30);
const PHOENIX_SERIALIZER_VERSION: &str = "2.0.0";
// The join consumes the first Phoenix ref; heartbeat refs then remain unique on this connection.
const JOIN_REFERENCE: &str = "1";
const FIRST_HEARTBEAT_REFERENCE: u64 = 2;
const REGISTRATION_PATH: &str = "api/runners";
const RUNNER_CAPABILITIES: [&str; 10] = [
    "list_files",
    "search_code",
    "read_file",
    "git_status",
    "git_diff",
    "apply_patch",
    "replace_text",
    "start_command",
    "poll_command",
    "stop_command",
];

#[derive(Debug, Error)]
pub enum ControlPlaneError {
    #[error("invalid control-plane URL: {0}")]
    InvalidUrl(String),
    #[error("control-plane registration failed: {0}")]
    Registration(String),
    #[error("control-plane transport failed: {0}")]
    Transport(String),
    #[error("control-plane supplied invalid runner limits: {0}")]
    Configuration(String),
    #[error("runner limits changed; restart the daemon to begin a new policy epoch")]
    PolicyChanged,
}

/// Identity of a runner after registration and channel authentication have completed.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct RunnerReady {
    pub runner_id: String,
}

#[derive(Serialize)]
struct RegistrationRequest<'a> {
    workspace_root: &'a str,
    name: &'static str,
    platform: &'static str,
    architecture: &'static str,
    runner_version: &'static str,
    protocol_version: u16,
    capabilities: &'static [&'static str],
}

#[derive(Clone, Debug, Deserialize)]
struct Registration {
    runner_id: String,
    token: String,
    socket_path: String,
    topic: String,
    protocol_version: u16,
    token_expires_in: u64,
}

/// Phoenix V2's five-element JSON frame; channel refs are transport-only correlation.
#[derive(Debug)]
struct Frame {
    join_ref: Option<String>,
    reference: Option<String>,
    topic: String,
    event: String,
    payload: Value,
}

impl Frame {
    fn parse(text: &str) -> Result<Self, ControlPlaneError> {
        if text.len() > MAX_WIRE_BYTES {
            return Err(ControlPlaneError::Transport(
                "WebSocket message exceeds 4 MiB".into(),
            ));
        }
        let [join_ref, reference, topic, event, payload]: [Value; 5] =
            serde_json::from_str(text)
                .map_err(|e| ControlPlaneError::Transport(format!("invalid Phoenix frame: {e}")))?;
        Ok(Self {
            join_ref: optional_string(join_ref)?,
            reference: optional_string(reference)?,
            topic: required_string(topic, "topic")?,
            event: required_string(event, "event")?,
            payload,
        })
    }

    fn serialize(&self) -> Result<String, ControlPlaneError> {
        let text = serde_json::to_string(&json!([
            self.join_ref,
            self.reference,
            self.topic,
            self.event,
            self.payload
        ]))
        .map_err(|e| ControlPlaneError::Transport(e.to_string()))?;
        if text.len() > MAX_WIRE_BYTES {
            return Err(ControlPlaneError::Transport(
                "outbound frame exceeds 4 MiB".into(),
            ));
        }
        Ok(text)
    }
}

fn optional_string(value: Value) -> Result<Option<String>, ControlPlaneError> {
    match value {
        Value::Null => Ok(None),
        Value::String(s) => Ok(Some(s)),
        _ => Err(ControlPlaneError::Transport(
            "Phoenix reference must be a string or null".into(),
        )),
    }
}

fn required_string(value: Value, field: &str) -> Result<String, ControlPlaneError> {
    value
        .as_str()
        .map(str::to_owned)
        .ok_or_else(|| ControlPlaneError::Transport(format!("Phoenix {field} must be a string")))
}

/// Register the workspace and maintain its authenticated loopback control-plane connection.
pub async fn serve(
    base: &str,
    workspace: &Workspace,
    agent_token: &str,
) -> Result<(), ControlPlaneError> {
    serve_inner(base, workspace, agent_token, None).await
}

/// Serve like [`serve`], notifying an in-process client once sessions can target this runner.
pub async fn serve_with_ready(
    base: &str,
    workspace: &Workspace,
    agent_token: &str,
    ready: oneshot::Sender<RunnerReady>,
) -> Result<(), ControlPlaneError> {
    serve_inner(base, workspace, agent_token, Some(ready)).await
}

async fn serve_inner(
    base: &str,
    workspace: &Workspace,
    agent_token: &str,
    mut ready: Option<oneshot::Sender<RunnerReady>>,
) -> Result<(), ControlPlaneError> {
    let base = validate_base_url(base)?;
    let _runner_lock = workspace
        .lock_runner()
        .map_err(|error| ControlPlaneError::Configuration(error.to_string()))?;
    let root = workspace.root().to_str().ok_or_else(|| {
        ControlPlaneError::Registration("canonical workspace root is not UTF-8".into())
    })?;
    let client = reqwest::Client::builder()
        .https_only(base.scheme() == "https")
        .build()
        .map_err(|e| ControlPlaneError::Registration(e.to_string()))?;
    // Registration and policy are separate: credentials may refresh without discarding running
    // commands, request elections, or cached mutation responses from the current policy epoch.
    let mut registration = None;
    let mut runtime: Option<(ExecutionLimits, Dispatcher)> = None;
    let mut backoff = INITIAL_RECONNECT_DELAY;
    loop {
        if registration.is_none() {
            match register(&client, &base, root, agent_token).await {
                Ok(registered) => {
                    registration = Some(registered);
                    backoff = INITIAL_RECONNECT_DELAY;
                }
                Err(error) => {
                    eprintln!("kodo: control-plane registration failed: {error}");
                    sleep(backoff).await;
                    backoff = (backoff * 2).min(MAX_RECONNECT_DELAY);
                    continue;
                }
            }
        }
        let registered = registration
            .as_ref()
            .expect("registration is established above");
        let (socket, limits) = match connect_and_join(&base, registered).await {
            Ok(joined) => joined,
            Err(ConnectError::AuthRejected) => {
                registration = None;
                backoff = INITIAL_RECONNECT_DELAY;
                // Avoid a tight register/auth loop if the control plane persistently rejects tokens.
                sleep(backoff).await;
                continue;
            }
            Err(ConnectError::Other(error @ ControlPlaneError::Configuration(_))) => {
                return Err(error);
            }
            Err(ConnectError::Other(error)) => {
                eprintln!("kodo: control-plane connection lost: {error}");
                sleep(backoff).await;
                backoff = (backoff * 2).min(MAX_RECONNECT_DELAY);
                continue;
            }
        };
        let dispatcher = match &runtime {
            Some((current, dispatcher)) if current == &limits => dispatcher.clone(),
            Some(_) => return Err(ControlPlaneError::PolicyChanged),
            None => {
                let runner = Runner::from_limits(workspace.clone(), limits.clone())
                    .map_err(ControlPlaneError::Configuration)?;
                let dispatcher = Dispatcher::new(runner);
                runtime = Some((limits, dispatcher.clone()));
                dispatcher
            }
        };
        if let Some(sender) = ready.take() {
            let _ = sender.send(RunnerReady {
                runner_id: registered.runner_id.clone(),
            });
        }
        if let Err(error) = channel_loop(socket, registered, dispatcher).await {
            eprintln!("kodo: control-plane connection lost: {error}");
        }
        backoff = INITIAL_RECONNECT_DELAY;
        sleep(backoff).await;
        backoff = (backoff * 2).min(MAX_RECONNECT_DELAY);
    }
}

fn validate_base_url(input: &str) -> Result<Url, ControlPlaneError> {
    let url = Url::parse(input).map_err(|e| ControlPlaneError::InvalidUrl(e.to_string()))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.cannot_be_a_base()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(ControlPlaneError::InvalidUrl(
            "expected an http(s) base URL without query or fragment".into(),
        ));
    }
    // Registration is an unauthenticated bootstrap, so a remote URL is never an acceptable typo.
    let loopback = match url.host() {
        Some(Host::Domain("localhost")) => true,
        Some(Host::Ipv4(ip)) => IpAddr::V4(ip).is_loopback(),
        Some(Host::Ipv6(ip)) => IpAddr::V6(ip).is_loopback(),
        Some(Host::Domain(_)) | None => false,
    };
    if !loopback {
        return Err(ControlPlaneError::InvalidUrl(
            "host must be loopback".into(),
        ));
    }
    Ok(url)
}

async fn register(
    client: &reqwest::Client,
    base: &Url,
    root: &str,
    agent_token: &str,
) -> Result<Registration, ControlPlaneError> {
    let endpoint = base
        .join(&format!(
            "{}/{REGISTRATION_PATH}",
            base.path().trim_end_matches('/')
        ))
        .map_err(|e| ControlPlaneError::InvalidUrl(e.to_string()))?;
    let request = RegistrationRequest {
        workspace_root: root,
        name: "kodo",
        platform: std::env::consts::OS,
        architecture: std::env::consts::ARCH,
        runner_version: env!("CARGO_PKG_VERSION"),
        protocol_version: PROTOCOL_VERSION,
        capabilities: &RUNNER_CAPABILITIES,
    };
    let mut response = client
        .post(endpoint)
        .bearer_auth(agent_token)
        .json(&request)
        .send()
        .await
        .map_err(|e| ControlPlaneError::Registration(e.to_string()))?;
    if !response.status().is_success() {
        return Err(ControlPlaneError::Registration(format!(
            "HTTP {}",
            response.status()
        )));
    }
    if response
        .content_length()
        .is_some_and(|n| n > MAX_REGISTRATION_BYTES as u64)
    {
        return Err(ControlPlaneError::Registration(
            "response exceeds size limit".into(),
        ));
    }
    let mut bytes = Vec::new();
    while let Some(chunk) = response
        .chunk()
        .await
        .map_err(|e| ControlPlaneError::Registration(e.to_string()))?
    {
        if bytes.len().saturating_add(chunk.len()) > MAX_REGISTRATION_BYTES {
            return Err(ControlPlaneError::Registration(
                "response exceeds size limit".into(),
            ));
        }
        bytes.extend_from_slice(&chunk);
    }
    let registration: Registration = serde_json::from_slice(&bytes)
        .map_err(|e| ControlPlaneError::Registration(format!("invalid response: {e}")))?;
    validate_registration(&registration)?;
    Ok(registration)
}

fn validate_registration(r: &Registration) -> Result<(), ControlPlaneError> {
    if r.runner_id.is_empty()
        || r.token.is_empty()
        || r.topic.is_empty()
        || r.socket_path.is_empty()
        || r.token_expires_in == 0
        || r.protocol_version != PROTOCOL_VERSION
        || !r.socket_path.starts_with('/')
        || r.topic != format!("runner:{}", r.runner_id)
        || uuid::Uuid::parse_str(&r.runner_id).is_err()
    {
        return Err(ControlPlaneError::Registration(
            "response contains invalid or unsupported fields".into(),
        ));
    }
    Ok(())
}

enum ConnectError {
    AuthRejected,
    Other(ControlPlaneError),
}

type ControlSocket = WebSocketStream<MaybeTlsStream<tokio::net::TcpStream>>;

async fn connect_and_join(
    base: &Url,
    registration: &Registration,
) -> Result<(ControlSocket, ExecutionLimits), ConnectError> {
    let mut socket_url = base.clone();
    socket_url
        .set_scheme(if base.scheme() == "https" {
            "wss"
        } else {
            "ws"
        })
        .map_err(|()| {
            ConnectError::Other(ControlPlaneError::InvalidUrl(
                "invalid socket scheme".into(),
            ))
        })?;
    socket_url.set_path(&registration.socket_path);
    socket_url.set_query(None);
    socket_url
        .query_pairs_mut()
        .append_pair("token", &registration.token)
        .append_pair("vsn", PHOENIX_SERIALIZER_VERSION);
    let config = tungstenite::protocol::WebSocketConfig::default()
        .max_message_size(Some(MAX_WIRE_BYTES))
        .max_frame_size(Some(MAX_WIRE_BYTES));
    let connected = connect_async_with_config(socket_url.as_str(), Some(config), false).await;
    let (socket, _) = match connected {
        Ok(value) => value,
        Err(tungstenite::Error::Http(response))
            if matches!(
                response.status(),
                StatusCode::UNAUTHORIZED | StatusCode::FORBIDDEN
            ) =>
        {
            return Err(ConnectError::AuthRejected);
        }
        Err(e) => {
            return Err(ConnectError::Other(ControlPlaneError::Transport(
                redact_error(e, &registration.token),
            )));
        }
    };
    join(socket, registration)
        .await
        .map_err(ConnectError::Other)
}

fn redact_error(error: impl std::fmt::Display, token: &str) -> String {
    error.to_string().replace(token, "[REDACTED]")
}

async fn join<S>(
    mut socket: WebSocketStream<S>,
    registration: &Registration,
) -> Result<(WebSocketStream<S>, ExecutionLimits), ControlPlaneError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    send(
        &mut socket,
        Frame {
            join_ref: Some(JOIN_REFERENCE.into()),
            reference: Some(JOIN_REFERENCE.into()),
            topic: registration.topic.clone(),
            event: "phx_join".into(),
            payload: json!({"protocol_version": PROTOCOL_VERSION}),
        },
    )
    .await?;

    while let Some(message) = socket.next().await {
        let message = message.map_err(|error| ControlPlaneError::Transport(error.to_string()))?;
        if let tungstenite::Message::Text(text) = message {
            let frame = Frame::parse(&text)?;
            if frame.topic == registration.topic
                && frame.event == "phx_reply"
                && frame.reference.as_deref() == Some(JOIN_REFERENCE)
            {
                return Ok((socket, parse_join_limits(frame.payload)?));
            }
            if matches!(frame.event.as_str(), "phx_error" | "phx_close") {
                return Err(ControlPlaneError::Transport("channel join rejected".into()));
            }
        }
    }
    Err(ControlPlaneError::Transport(
        "connection closed before channel join completed".into(),
    ))
}

fn parse_join_limits(payload: Value) -> Result<ExecutionLimits, ControlPlaneError> {
    if payload.get("status").and_then(Value::as_str) != Some("ok") {
        return Err(ControlPlaneError::Transport("channel join rejected".into()));
    }
    let value = payload
        .pointer("/response/limits")
        .cloned()
        .ok_or_else(|| ControlPlaneError::Configuration("join response omitted limits".into()))?;
    let limits: ExecutionLimits = serde_json::from_value(value)
        .map_err(|error| ControlPlaneError::Configuration(error.to_string()))?;
    limits
        .validate()
        .map_err(ControlPlaneError::Configuration)?;
    Ok(limits)
}

async fn channel_loop<S>(
    mut socket: tokio_tungstenite::WebSocketStream<S>,
    registration: &Registration,
    dispatcher: Dispatcher,
) -> Result<(), ControlPlaneError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let join_ref = JOIN_REFERENCE.to_owned();
    let mut next_ref = FIRST_HEARTBEAT_REFERENCE;
    let mut heartbeat = interval_at(Instant::now() + HEARTBEAT_INTERVAL, HEARTBEAT_INTERVAL);
    let mut requests = FuturesUnordered::new();
    loop {
        tokio::select! {
            // Stop reading at capacity so TCP backpressure replaces silent request loss.
            message = socket.next(), if requests.len() < MAX_IN_FLIGHT_REQUESTS => {
                let Some(message) = message else { return Ok(()); };
                let message = message.map_err(|e| ControlPlaneError::Transport(e.to_string()))?;
                if let tungstenite::Message::Text(text) = message {
                    let frame = Frame::parse(&text)?;
                    if matches!(frame.event.as_str(), "phx_error" | "phx_close") { return Ok(()); }
                    else if frame.topic == registration.topic && frame.event == "tool_request" {
                        // The protocol request ID, not the Phoenix ref, provides idempotent replay.
                        let request: RequestEnvelope = serde_json::from_value(frame.payload).map_err(|e| ControlPlaneError::Transport(format!("invalid tool request: {e}")))?;
                        let dispatcher = dispatcher.clone();
                        let reference = frame.reference;
                        requests.push(async move { (reference, dispatcher.dispatch_connected(request).await) });
                    } else if frame.topic == registration.topic && frame.event == "authority_lease" {
                        let lease: AuthorityLease = serde_json::from_value(frame.payload).map_err(|e| ControlPlaneError::Transport(format!("invalid authority lease: {e}")))?;
                        // A delayed stale renewal must not disconnect the runner from a newer owner.
                        let _ = dispatcher.renew_authority(lease);
                    }
                }
            }
            Some((reference, response)) = requests.next(), if !requests.is_empty() => {
                let payload = serde_json::from_str(&response).map_err(|e| ControlPlaneError::Transport(e.to_string()))?;
                send(&mut socket, Frame { join_ref: Some(join_ref.clone()), reference, topic: registration.topic.clone(), event: "tool_response".into(), payload }).await?;
            }
            // Heartbeats continue while tools run so long-running commands do not look disconnected.
            _ = heartbeat.tick() => {
                let reference = next_ref.to_string(); next_ref += 1;
                send(&mut socket, Frame { join_ref: None, reference: Some(reference), topic: "phoenix".into(), event: "heartbeat".into(), payload: json!({}) }).await?;
            }
        }
    }
}

async fn send<S>(
    socket: &mut tokio_tungstenite::WebSocketStream<S>,
    frame: Frame,
) -> Result<(), ControlPlaneError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    socket
        .send(tungstenite::Message::Text(frame.serialize()?.into()))
        .await
        .map_err(|e| ControlPlaneError::Transport(e.to_string()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_loopback_http_urls_are_accepted() {
        for good in [
            "http://localhost:4000",
            "https://127.9.8.7/base",
            "http://[::1]:4000",
        ] {
            assert!(validate_base_url(good).is_ok(), "{good}");
        }
        for bad in [
            "http://example.com",
            "ftp://localhost",
            "http://192.168.1.2",
            "http://localhost/?token=x",
        ] {
            assert!(validate_base_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn phoenix_frame_round_trips() {
        let input = r#"["1","2","runner:abc","tool_request",{"protocol_version":4}]"#;
        let frame = Frame::parse(input).unwrap();
        assert_eq!(frame.topic, "runner:abc");
        assert_eq!(frame.event, "tool_request");
        assert_eq!(
            Frame::parse(&frame.serialize().unwrap())
                .unwrap()
                .reference
                .as_deref(),
            Some("2")
        );
    }

    #[test]
    fn join_requires_a_complete_valid_limits_contract() {
        let expected = ExecutionLimits::standalone();
        let payload = json!({
            "status": "ok",
            "response": {"limits": expected}
        });
        assert_eq!(parse_join_limits(payload).unwrap(), expected);

        let missing = json!({"status": "ok", "response": {}});
        assert!(matches!(
            parse_join_limits(missing),
            Err(ControlPlaneError::Configuration(_))
        ));

        let mut invalid = serde_json::to_value(ExecutionLimits::standalone()).unwrap();
        invalid["max_output_bytes"] = 0.into();
        let invalid = json!({"status": "ok", "response": {"limits": invalid}});
        assert!(matches!(
            parse_join_limits(invalid),
            Err(ControlPlaneError::Configuration(_))
        ));
    }

    #[test]
    fn registration_is_validated() {
        let runner_id = uuid::Uuid::new_v4().to_string();
        let mut r = Registration {
            runner_id: runner_id.clone(),
            token: "secret".into(),
            socket_path: "/socket/websocket".into(),
            topic: format!("runner:{runner_id}"),
            protocol_version: PROTOCOL_VERSION,
            token_expires_in: 60,
        };
        assert!(validate_registration(&r).is_ok());
        r.protocol_version = 1;
        assert!(validate_registration(&r).is_err());
    }

    #[test]
    fn registration_json_matches_the_phoenix_contract() {
        let request = serde_json::to_value(RegistrationRequest {
            workspace_root: "/workspace",
            name: "kodo",
            platform: "linux",
            architecture: "x86_64",
            runner_version: "0.1.0",
            protocol_version: PROTOCOL_VERSION,
            capabilities: &RUNNER_CAPABILITIES,
        })
        .unwrap();
        assert_eq!(request["runner_version"], "0.1.0");
        assert!(request.get("version").is_none());

        let runner_id = uuid::Uuid::new_v4().to_string();
        let response = json!({
            "runner_id": runner_id,
            "token": "signed",
            "socket_path": "/runner/websocket",
            "topic": format!("runner:{runner_id}"),
            "protocol_version": PROTOCOL_VERSION,
            "token_expires_in": 86_400
        });
        let registration: Registration = serde_json::from_value(response).unwrap();
        assert!(validate_registration(&registration).is_ok());
    }

    #[test]
    fn oversized_frame_is_rejected() {
        assert!(Frame::parse(&"x".repeat(MAX_WIRE_BYTES + 1)).is_err());
        let frame = Frame {
            join_ref: None,
            reference: None,
            topic: "t".into(),
            event: "e".into(),
            payload: Value::String("x".repeat(MAX_WIRE_BYTES)),
        };
        assert!(frame.serialize().is_err());
    }
}
