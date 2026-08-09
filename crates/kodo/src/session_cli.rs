//! Authenticated, line-oriented client for durable Phoenix sessions.

use std::collections::HashSet;
use std::io::{self, Write};
use std::path::PathBuf;
use std::time::Duration;

use reqwest::{Client, Response};
use serde::Deserialize;
use serde_json::{Value, json};
use thiserror::Error;
use tokio::io::{AsyncBufReadExt, BufReader};
use tokio::sync::oneshot;
use url::Url;
use uuid::Uuid;

use crate::control_plane::{self, RunnerReady};
use crate::workspace::Workspace;

const MAX_RESPONSE_BYTES: usize = 4 * 1024 * 1024;
const API_TIMEOUT: Duration = Duration::from_secs(30);
const RUNNER_BOOTSTRAP_TIMEOUT: Duration = Duration::from_secs(30);

#[derive(Debug, Error)]
pub enum SessionCliError {
    #[error("invalid control-plane URL: {0}")]
    InvalidUrl(String),
    #[error("KODO_TOKEN is required (or pass --token)")]
    MissingToken,
    #[error("API request failed: {0}")]
    Api(String),
    #[error("workspace runner stopped before becoming ready: {0}")]
    Runner(String),
    #[error("terminal input failed: {0}")]
    Input(#[from] io::Error),
}

#[derive(Clone, Debug)]
pub struct Options {
    pub control_plane: String,
    pub token: String,
    pub workspace: PathBuf,
}

#[derive(Clone, Debug)]
pub struct StartOptions {
    pub common: Options,
    pub task: String,
    pub title: Option<String>,
    pub model: String,
    pub approval_policy: String,
}

#[derive(Clone, Debug)]
pub struct ResumeOptions {
    pub common: Options,
    pub session_id: String,
    pub message: Option<String>,
}

#[derive(Debug, Deserialize)]
struct Session {
    id: String,
    runner_id: String,
    status: String,
}

#[derive(Debug, Deserialize)]
struct Event {
    sequence: u64,
    #[serde(rename = "type")]
    kind: String,
    payload: Value,
}

#[derive(Debug, Deserialize)]
struct SessionResponse {
    session: Session,
    #[serde(default)]
    events: Vec<Event>,
}

pub async fn start(options: StartOptions) -> Result<(), SessionCliError> {
    let (client, base, runner, runner_task) = host_runner(&options.common).await?;
    let title = options.title.as_deref().unwrap_or(&options.task);
    let response = request_json(
        client
            .post(endpoint(&base, "api/sessions")?)
            .bearer_auth(&options.common.token)
            .json(&json!({
                "runner_id": runner.runner_id,
                "title": title,
                "model": options.model,
                "approval_policy": options.approval_policy
            })),
        &options.common.token,
    )
    .await?;
    let session: Session = serde_json::from_value(response["session"].clone())
        .map_err(|e| SessionCliError::Api(format!("invalid create response: {e}")))?;
    submit_message(
        &client,
        &base,
        &options.common.token,
        &session.id,
        &options.task,
    )
    .await?;
    println!("Session: {}", browser_url(&base, &session.id)?);
    drive(client, base, options.common.token, session.id, runner_task).await
}

pub async fn resume(options: ResumeOptions) -> Result<(), SessionCliError> {
    let session_id = parse_id(&options.session_id, "session")?;
    let (client, base, runner, runner_task) = host_runner(&options.common).await?;
    let replay = fetch_session(&client, &base, &options.common.token, &session_id, 0).await?;
    if replay.session.runner_id != runner.runner_id {
        runner_task.abort();
        return Err(SessionCliError::Runner(
            "session belongs to a different workspace runner".into(),
        ));
    }
    if let Some(message) = &options.message {
        submit_message(&client, &base, &options.common.token, &session_id, message).await?;
    }
    println!("Session: {}", browser_url(&base, &session_id)?);
    drive(client, base, options.common.token, session_id, runner_task).await
}

async fn host_runner(
    options: &Options,
) -> Result<
    (
        Client,
        Url,
        RunnerReady,
        tokio::task::JoinHandle<Result<(), control_plane::ControlPlaneError>>,
    ),
    SessionCliError,
> {
    if options.token.trim().is_empty() {
        return Err(SessionCliError::MissingToken);
    }
    let base = validate_base_url(&options.control_plane)?;
    let workspace = Workspace::discover(&options.workspace)
        .map_err(|e| SessionCliError::Runner(e.to_string()))?;
    let (ready_tx, ready_rx) = oneshot::channel();
    let runner_base = options.control_plane.clone();
    let runner_task = tokio::spawn(async move {
        control_plane::serve_with_ready(&runner_base, &workspace, ready_tx).await
    });
    let ready = match tokio::time::timeout(RUNNER_BOOTSTRAP_TIMEOUT, ready_rx).await {
        Ok(Ok(ready)) => ready,
        Ok(Err(_closed)) => {
            return Err(SessionCliError::Runner(
                "registration or channel authentication failed".into(),
            ));
        }
        Err(_elapsed) => {
            runner_task.abort();
            return Err(SessionCliError::Runner(
                "runner did not connect within 30 seconds".into(),
            ));
        }
    };
    let client = Client::builder()
        .timeout(API_TIMEOUT)
        .build()
        .map_err(|error| SessionCliError::Api(error.to_string()))?;
    Ok((client, base, ready, runner_task))
}

async fn drive(
    client: Client,
    base: Url,
    token: String,
    session_id: String,
    mut runner_task: tokio::task::JoinHandle<Result<(), control_plane::ControlPlaneError>>,
) -> Result<(), SessionCliError> {
    let mut cursor = 0;
    loop {
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                cancel_session(&client, &base, &token, &session_id).await?;
                println!("Cancelled session {session_id}");
                runner_task.abort();
                return Ok(());
            }
            result = &mut runner_task => {
                return Err(SessionCliError::Runner(match result {
                    Ok(Ok(())) => "runner exited unexpectedly".into(),
                    Ok(Err(error)) => error.to_string(),
                    Err(error) => error.to_string(),
                }));
            }
            _ = tokio::time::sleep(Duration::from_millis(500)) => {}
        }
        let replay = tokio::select! {
            _ = tokio::signal::ctrl_c() => {
                cancel_session(&client, &base, &token, &session_id).await?;
                println!("Cancelled session {session_id}");
                runner_task.abort();
                return Ok(());
            }
            result = fetch_session(&client, &base, &token, &session_id, cursor) => result?,
        };
        let resolved_approvals: HashSet<String> = replay
            .events
            .iter()
            .filter(|event| event.kind == "approval_resolved")
            .filter_map(|event| {
                event
                    .payload
                    .get("approval_id")
                    .and_then(Value::as_str)
                    .map(str::to_owned)
            })
            .collect();
        for event in replay.events {
            cursor = cursor.max(event.sequence);
            println!("{}", format_event(&event));
            let pending_approval = event
                .payload
                .get("approval_id")
                .and_then(Value::as_str)
                .is_none_or(|id| !resolved_approvals.contains(id));
            if event.kind == "approval_requested"
                && pending_approval
                && !resolve_approval(&client, &base, &token, &session_id, &event).await?
            {
                runner_task.abort();
                println!("Cancelled session {session_id}");
                return Ok(());
            }
        }
        if matches!(
            replay.session.status.as_str(),
            "idle" | "completed" | "failed" | "cancelled"
        ) {
            runner_task.abort();
            return Ok(());
        }
    }
}

async fn resolve_approval(
    client: &Client,
    base: &Url,
    token: &str,
    session_id: &str,
    event: &Event,
) -> Result<bool, SessionCliError> {
    let approval_id = event
        .payload
        .get("approval_id")
        .and_then(Value::as_str)
        .ok_or_else(|| SessionCliError::Api("approval_requested omitted approval_id".into()))?;
    let approval_id = parse_id(approval_id, "approval")?;
    print!("Approve request? [y/N] ");
    io::stdout().flush()?;
    let mut answer = String::new();
    let mut input = BufReader::new(tokio::io::stdin());
    tokio::select! {
        result = input.read_line(&mut answer) => {
            result?;
        }
        _ = tokio::signal::ctrl_c() => {
            cancel_session(client, base, token, session_id).await?;
            return Ok(false);
        }
    }
    let decision = if matches!(answer.trim().to_ascii_lowercase().as_str(), "y" | "yes") {
        "approved"
    } else {
        "denied"
    };
    request_json(
        client
            .post(endpoint(
                base,
                &format!("api/sessions/{session_id}/approvals/{approval_id}"),
            )?)
            .bearer_auth(token)
            .json(&json!({"decision": decision})),
        token,
    )
    .await?;
    Ok(true)
}

async fn submit_message(
    client: &Client,
    base: &Url,
    token: &str,
    id: &str,
    content: &str,
) -> Result<(), SessionCliError> {
    request_json(
        client
            .post(endpoint(base, &format!("api/sessions/{id}/messages"))?)
            .bearer_auth(token)
            .json(&json!({"content": content})),
        token,
    )
    .await?;
    Ok(())
}

async fn cancel_session(
    client: &Client,
    base: &Url,
    token: &str,
    id: &str,
) -> Result<(), SessionCliError> {
    request_json(
        client
            .post(endpoint(base, &format!("api/sessions/{id}/cancel"))?)
            .bearer_auth(token),
        token,
    )
    .await?;
    Ok(())
}

async fn fetch_session(
    client: &Client,
    base: &Url,
    token: &str,
    id: &str,
    cursor: u64,
) -> Result<SessionResponse, SessionCliError> {
    let value = request_json(
        client
            .get(endpoint(
                base,
                &format!("api/sessions/{id}?after_sequence={cursor}"),
            )?)
            .bearer_auth(token),
        token,
    )
    .await?;

    serde_json::from_value(value)
        .map_err(|error| SessionCliError::Api(format!("invalid session response: {error}")))
}

async fn request_json(
    builder: reqwest::RequestBuilder,
    token: &str,
) -> Result<Value, SessionCliError> {
    let response = builder
        .send()
        .await
        .map_err(|e| api_error(e.to_string(), token))?;
    let status = response.status();
    let bytes = bounded_body(response)
        .await
        .map_err(|e| api_error(e, token))?;
    if !status.is_success() {
        let detail = String::from_utf8_lossy(&bytes);
        return Err(api_error(format!("HTTP {status}: {detail}"), token));
    }
    serde_json::from_slice(&bytes)
        .map_err(|e| api_error(format!("invalid JSON response: {e}"), token))
}

async fn bounded_body(mut response: Response) -> Result<Vec<u8>, String> {
    let mut body = Vec::new();
    while let Some(chunk) = response.chunk().await.map_err(|e| e.to_string())? {
        if body.len().saturating_add(chunk.len()) > MAX_RESPONSE_BYTES {
            return Err("response exceeds 4 MiB".into());
        }
        body.extend_from_slice(&chunk);
    }
    Ok(body)
}

fn api_error(message: String, token: &str) -> SessionCliError {
    SessionCliError::Api(if token.is_empty() {
        message
    } else {
        message.replace(token, "[REDACTED]")
    })
}

fn validate_base_url(input: &str) -> Result<Url, SessionCliError> {
    let mut url = Url::parse(input).map_err(|e| SessionCliError::InvalidUrl(e.to_string()))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.cannot_be_a_base()
        || url.host().is_none()
        || url.query().is_some()
        || url.fragment().is_some()
        || !url.username().is_empty()
        || url.password().is_some()
    {
        return Err(SessionCliError::InvalidUrl(
            "expected an http(s) base URL without credentials, query, or fragment".into(),
        ));
    }
    if !url.path().ends_with('/') {
        url.set_path(&format!("{}/", url.path()));
    }
    Ok(url)
}

fn endpoint(base: &Url, path: &str) -> Result<Url, SessionCliError> {
    base.join(path)
        .map_err(|e| SessionCliError::InvalidUrl(e.to_string()))
}

fn parse_id(value: &str, kind: &str) -> Result<String, SessionCliError> {
    Uuid::parse_str(value)
        .map(|id| id.to_string())
        .map_err(|_| SessionCliError::Api(format!("invalid {kind} identifier")))
}

fn browser_url(base: &Url, id: &str) -> Result<Url, SessionCliError> {
    endpoint(base, &format!("sessions/{id}"))
}

fn format_event(event: &Event) -> String {
    let payload = &event.payload;
    match event.kind.as_str() {
        "assistant_message_completed" => payload
            .get("content")
            .and_then(Value::as_str)
            .unwrap_or("")
            .to_owned(),
        "tool_requested" | "tool_started" => format!(
            "[{}] {}",
            event.kind,
            payload
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("tool")
        ),
        "tool_completed" => {
            let name = payload
                .get("name")
                .and_then(Value::as_str)
                .unwrap_or("tool");
            let output = payload.get("output").unwrap_or(&Value::Null);
            if name == "git_diff" {
                format!(
                    "[git_diff]\n{}",
                    find_string(output, &["diff", "content", "output"])
                        .unwrap_or_else(|| output.to_string())
                )
            } else if matches!(name, "start_command" | "poll_command" | "stop_command") {
                format!("[verification: {name}] {}", command_summary(output))
            } else {
                format!("[tool_completed] {name}")
            }
        }
        "session_failed" => format!(
            "[failed] {}",
            payload
                .get("reason")
                .and_then(Value::as_str)
                .unwrap_or("unknown error")
        ),
        "approval_requested" => format!(
            "[approval requested] {}",
            payload
                .get("description")
                .or_else(|| payload.get("command"))
                .and_then(Value::as_str)
                .unwrap_or("tool execution")
        ),
        _ => format!("[{}]", event.kind),
    }
}

fn find_string(value: &Value, keys: &[&str]) -> Option<String> {
    if let Some(object) = value.as_object() {
        for key in keys {
            if let Some(text) = object.get(*key).and_then(Value::as_str) {
                return Some(text.to_owned());
            }
        }
        for child in object.values() {
            if let Some(text) = find_string(child, keys) {
                return Some(text);
            }
        }
    }
    if let Some(array) = value.as_array() {
        for child in array {
            if let Some(text) = find_string(child, keys) {
                return Some(text);
            }
        }
    }
    None
}

fn command_summary(output: &Value) -> String {
    let mut chunks = Vec::new();
    collect_content(output, &mut chunks);
    let text = chunks.join("");
    let status = output
        .get("status")
        .map(format_status)
        .unwrap_or_else(|| "updated".into());
    let truncated = output
        .get("truncated")
        .and_then(Value::as_bool)
        .unwrap_or(false);
    let suffix = if truncated {
        "\n[output truncated]"
    } else {
        ""
    };
    if text.is_empty() {
        format!("{status}{suffix}")
    } else {
        format!("{status}\n{text}{suffix}")
    }
}

fn collect_content(value: &Value, chunks: &mut Vec<String>) {
    match value {
        Value::Object(object) => {
            if let Some(content) = object.get("content").and_then(Value::as_str) {
                chunks.push(content.to_owned());
            } else {
                for child in object.values() {
                    collect_content(child, chunks);
                }
            }
        }
        Value::Array(values) => {
            for child in values {
                collect_content(child, chunks);
            }
        }
        _ => {}
    }
}

fn format_status(status: &Value) -> String {
    match status {
        Value::String(status) => status.clone(),
        Value::Object(status) if status.contains_key("exited") => {
            let code = status["exited"]["code"]
                .as_i64()
                .map_or_else(|| "signal".into(), |code| code.to_string());
            format!("exited ({code})")
        }
        _ => status.to_string(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn validates_and_joins_base_urls() {
        let base = validate_base_url("http://localhost:4451/prefix").unwrap();
        assert_eq!(
            endpoint(&base, "api/sessions").unwrap().as_str(),
            "http://localhost:4451/prefix/api/sessions"
        );
        for bad in [
            "localhost:4451",
            "ftp://localhost",
            "http://u:p@localhost",
            "http://localhost?q=x",
        ] {
            assert!(validate_base_url(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn formats_real_diff_and_command_output() {
        let diff = Event {
            sequence: 1,
            kind: "tool_completed".into(),
            payload: json!({"name":"git_diff", "output":{"response":{"diff":"diff --git a/a b/a"}}}),
        };
        assert!(format_event(&diff).contains("diff --git"));
        let command = Event {
            sequence: 2,
            kind: "tool_completed".into(),
            payload: json!({
                "name": "poll_command",
                "output": {
                    "result": "command_poll",
                    "status": {"exited": {"code": 0}},
                    "output": [
                        {"sequence": 1, "stream": "stdout", "content": "2 tests ", "truncated": false},
                        {"sequence": 2, "stream": "stdout", "content": "passed\n", "truncated": false}
                    ],
                    "truncated": false
                }
            }),
        };
        let rendered = format_event(&command);
        assert!(rendered.contains("exited (0)"));
        assert!(rendered.contains("2 tests passed"));
    }

    #[test]
    fn bearer_secrets_are_redacted() {
        assert_eq!(
            api_error("Bearer top-secret".into(), "top-secret").to_string(),
            "API request failed: Bearer [REDACTED]"
        );
    }

    #[test]
    fn rejects_identifiers_that_could_alter_request_paths() {
        assert!(parse_id("../sessions/other", "session").is_err());
        assert_eq!(
            parse_id("d4d35f9f-055f-41a8-bca6-76c17f84d720", "session").unwrap(),
            "d4d35f9f-055f-41a8-bca6-76c17f84d720"
        );
    }
}
