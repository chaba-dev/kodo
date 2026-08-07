//! Authenticated Phoenix Channels transport for a loopback control plane.

use std::net::IpAddr;
use std::time::Duration;

use futures_util::{SinkExt, StreamExt, stream::FuturesUnordered};
use reqwest::StatusCode;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use thiserror::Error;
use tokio::time::{Instant, interval_at, sleep};
use tokio_tungstenite::{connect_async_with_config, tungstenite};
use url::{Host, Url};

use crate::daemon::{Dispatcher, MAX_IN_FLIGHT_REQUESTS};
use crate::protocol::{PROTOCOL_VERSION, RequestEnvelope};
use crate::runner::Runner;
use crate::workspace::Workspace;

const MAX_WIRE_BYTES: usize = 4 * 1024 * 1024;
const MAX_REGISTRATION_BYTES: usize = 256 * 1024;

#[derive(Debug, Error)]
pub enum ControlPlaneError {
    #[error("invalid control-plane URL: {0}")]
    InvalidUrl(String),
    #[error("control-plane registration failed: {0}")]
    Registration(String),
    #[error("control-plane transport failed: {0}")]
    Transport(String),
}

#[derive(Serialize)]
struct RegistrationRequest<'a> {
    workspace_root: &'a str,
    name: &'static str,
    platform: &'static str,
    architecture: &'static str,
    runner_version: &'static str,
    protocol_version: u16,
    capabilities: [&'static str; 9],
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

pub async fn serve(
    base: &str,
    workspace: &Workspace,
    runner: Runner,
) -> Result<(), ControlPlaneError> {
    let base = validate_base_url(base)?;
    let root = workspace.root().to_str().ok_or_else(|| {
        ControlPlaneError::Registration("canonical workspace root is not UTF-8".into())
    })?;
    let client = reqwest::Client::builder()
        .https_only(base.scheme() == "https")
        .build()
        .map_err(|e| ControlPlaneError::Registration(e.to_string()))?;
    let dispatcher = Dispatcher::new(runner);
    let mut registration = None;
    let mut backoff = Duration::from_secs(1);
    loop {
        if registration.is_none() {
            match register(&client, &base, root).await {
                Ok(registered) => {
                    registration = Some(registered);
                    backoff = Duration::from_secs(1);
                }
                Err(error) => {
                    eprintln!("kodo: control-plane registration failed: {error}");
                    sleep(backoff).await;
                    backoff = (backoff * 2).min(Duration::from_secs(30));
                    continue;
                }
            }
        }
        let registered = registration
            .as_ref()
            .expect("registration is established above");
        match connect_once(&base, registered, dispatcher.clone()).await {
            Ok(()) => backoff = Duration::from_secs(1),
            Err(ConnectError::AuthRejected) => {
                registration = None;
                backoff = Duration::from_secs(1);
            }
            Err(ConnectError::Other(error)) => {
                eprintln!("kodo: control-plane connection lost: {error}")
            }
        }
        sleep(backoff).await;
        backoff = (backoff * 2).min(Duration::from_secs(30));
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
) -> Result<Registration, ControlPlaneError> {
    let endpoint = base
        .join(&format!(
            "{}/api/runners",
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
        capabilities: [
            "list_files",
            "search_code",
            "read_file",
            "git_status",
            "git_diff",
            "apply_patch",
            "start_command",
            "poll_command",
            "stop_command",
        ],
    };
    let mut response = client
        .post(endpoint)
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

async fn connect_once(
    base: &Url,
    registration: &Registration,
    dispatcher: Dispatcher,
) -> Result<(), ConnectError> {
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
        .append_pair("vsn", "2.0.0");
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
    channel_loop(socket, registration, dispatcher)
        .await
        .map_err(ConnectError::Other)
}

fn redact_error(error: impl std::fmt::Display, token: &str) -> String {
    error.to_string().replace(token, "[REDACTED]")
}

async fn channel_loop<S>(
    mut socket: tokio_tungstenite::WebSocketStream<S>,
    registration: &Registration,
    dispatcher: Dispatcher,
) -> Result<(), ControlPlaneError>
where
    S: tokio::io::AsyncRead + tokio::io::AsyncWrite + Unpin,
{
    let join_ref = "1".to_owned();
    send(
        &mut socket,
        Frame {
            join_ref: Some(join_ref.clone()),
            reference: Some("1".into()),
            topic: registration.topic.clone(),
            event: "phx_join".into(),
            payload: json!({"protocol_version": PROTOCOL_VERSION}),
        },
    )
    .await?;
    let mut joined = false;
    let mut next_ref = 2_u64;
    let mut heartbeat = interval_at(
        Instant::now() + Duration::from_secs(30),
        Duration::from_secs(30),
    );
    let mut requests = FuturesUnordered::new();
    loop {
        tokio::select! {
            message = socket.next(), if requests.len() < MAX_IN_FLIGHT_REQUESTS => {
                let Some(message) = message else { return Ok(()); };
                let message = message.map_err(|e| ControlPlaneError::Transport(e.to_string()))?;
                if let tungstenite::Message::Text(text) = message {
                    let frame = Frame::parse(&text)?;
                    if frame.topic == registration.topic && frame.event == "phx_reply" && frame.reference.as_deref() == Some("1") {
                        joined = frame.payload.get("status").and_then(Value::as_str) == Some("ok");
                        if !joined { return Err(ControlPlaneError::Transport("channel join rejected".into())); }
                    } else if matches!(frame.event.as_str(), "phx_error" | "phx_close") { return Ok(()); }
                    else if joined && frame.topic == registration.topic && frame.event == "tool_request" {
                        let request: RequestEnvelope = serde_json::from_value(frame.payload).map_err(|e| ControlPlaneError::Transport(format!("invalid tool request: {e}")))?;
                        let dispatcher = dispatcher.clone();
                        let reference = frame.reference;
                        requests.push(async move { (reference, dispatcher.dispatch(request).await) });
                    }
                }
            }
            Some((reference, response)) = requests.next(), if !requests.is_empty() => {
                let payload = serde_json::from_str(&response).map_err(|e| ControlPlaneError::Transport(e.to_string()))?;
                send(&mut socket, Frame { join_ref: Some(join_ref.clone()), reference, topic: registration.topic.clone(), event: "tool_response".into(), payload }).await?;
            }
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
        let input = r#"["1","2","runner:abc","tool_request",{"protocol_version":2}]"#;
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
    fn registration_is_validated() {
        let runner_id = uuid::Uuid::new_v4().to_string();
        let mut r = Registration {
            runner_id: runner_id.clone(),
            token: "secret".into(),
            socket_path: "/socket/websocket".into(),
            topic: format!("runner:{runner_id}"),
            protocol_version: 2,
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
            protocol_version: 2,
            capabilities: [
                "list_files",
                "search_code",
                "read_file",
                "git_status",
                "git_diff",
                "apply_patch",
                "start_command",
                "poll_command",
                "stop_command",
            ],
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
            "protocol_version": 2,
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
