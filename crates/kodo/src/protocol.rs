//! Versioned wire contract between the local daemon and its eventual Phoenix transport.
//!
//! Tagged request/result variants keep dispatch explicit. Request IDs support replay, while command
//! output sequence numbers let clients resume polling without acknowledging destructive reads.

use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u16 = 4;
pub const LIMITS_VERSION: u16 = 1;
pub const MAX_AUTHORITY_LEASE_MS: u64 = 15_000;
const MAX_CONNECTED_PAYLOAD_BYTES: usize = 4 * 1024 * 1024 - 4 * 1024;
const JSON_ESCAPE_EXPANSION: usize = 6;
const RESPONSE_ENVELOPE_BYTES: usize = 4 * 1024;
const RESULT_METADATA_BYTES: usize = 512;
const MAX_LIMIT_VALUE: usize = u32::MAX as usize;
pub const MAX_BLOCKING_TOOLS: usize = 1024;

/// Phoenix-owned execution policy supplied by the authenticated channel join.
#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct ExecutionLimits {
    pub version: u16,
    pub max_output_bytes: usize,
    pub max_results: usize,
    pub max_patch_input_bytes: usize,
    pub max_file_input_bytes: usize,
    pub max_blocking_tools: usize,
    pub max_retained_processes: usize,
    pub max_process_output_chunks: usize,
    pub max_cached_requests: usize,
    pub max_cached_response_bytes: usize,
}

impl ExecutionLimits {
    /// Explicit compatibility policy for the standalone stdin/stdout transport.
    pub fn standalone() -> Self {
        Self {
            version: LIMITS_VERSION,
            max_output_bytes: 256 * 1024,
            max_results: 1_000,
            max_patch_input_bytes: 512 * 1024,
            max_file_input_bytes: 16 * 1024 * 1024,
            max_blocking_tools: 8,
            max_retained_processes: 1024,
            max_process_output_chunks: 1024,
            max_cached_requests: 1024,
            max_cached_response_bytes: 16 * 1024 * 1024,
        }
    }

    pub fn validate(&self) -> Result<(), String> {
        if self.version != LIMITS_VERSION {
            return Err(format!(
                "unsupported limits version {}; expected {LIMITS_VERSION}",
                self.version
            ));
        }
        let quotas = [
            self.max_output_bytes,
            self.max_results,
            self.max_patch_input_bytes,
            self.max_file_input_bytes,
            self.max_blocking_tools,
            self.max_retained_processes,
            self.max_process_output_chunks,
            self.max_cached_requests,
            self.max_cached_response_bytes,
        ];
        if quotas.contains(&0) {
            return Err("runner limits must be nonzero".into());
        }
        if quotas.into_iter().any(|quota| quota > MAX_LIMIT_VALUE) {
            return Err("runner limits exceed the platform-independent maximum".into());
        }
        if self.max_blocking_tools > MAX_BLOCKING_TOOLS {
            return Err("max_blocking_tools exceeds the supported maximum".into());
        }
        let maximum_response_bytes = self.maximum_encoded_response_bytes()?;
        if maximum_response_bytes > MAX_CONNECTED_PAYLOAD_BYTES {
            return Err("maximum encoded response exceeds the connected transport limit".into());
        }
        if self.max_cached_response_bytes < maximum_response_bytes {
            return Err("response cache cannot retain one maximum-sized encoded response".into());
        }
        let maximum_patch_bytes = self
            .max_patch_input_bytes
            .checked_mul(JSON_ESCAPE_EXPANSION)
            .and_then(|bytes| bytes.checked_add(RESPONSE_ENVELOPE_BYTES))
            .ok_or("runner limits exceed addressable memory")?;
        if maximum_patch_bytes > MAX_CONNECTED_PAYLOAD_BYTES {
            return Err("maximum encoded patch exceeds the connected transport limit".into());
        }
        Ok(())
    }

    pub(crate) fn maximum_encoded_response_bytes(&self) -> Result<usize, String> {
        let metadata_entries = self
            .max_results
            .checked_add(self.max_process_output_chunks)
            .ok_or("runner limits exceed addressable memory")?;
        self.max_output_bytes
            .checked_mul(JSON_ESCAPE_EXPANSION)
            .and_then(|bytes| {
                metadata_entries
                    .checked_mul(RESULT_METADATA_BYTES)
                    .and_then(|metadata| bytes.checked_add(metadata))
            })
            .and_then(|bytes| bytes.checked_add(RESPONSE_ENVELOPE_BYTES))
            .ok_or_else(|| "runner limits exceed addressable memory".into())
    }
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RequestEnvelope {
    pub protocol_version: u16,
    pub request_id: Uuid,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub authority: Option<AuthorityLease>,
    pub request: ToolRequest,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(deny_unknown_fields)]
pub struct AuthorityLease {
    pub session_id: Uuid,
    pub ownership_epoch: u64,
    pub ttl_ms: u64,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "status", rename_all = "snake_case")]
pub enum ResponseEnvelope {
    Success {
        protocol_version: u16,
        request_id: Uuid,
        response: ToolResult,
    },
    Error {
        protocol_version: u16,
        request_id: Option<Uuid>,
        error: String,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "tool", rename_all = "snake_case")]
pub enum ToolRequest {
    ListFiles {
        path: String,
    },
    SearchCode {
        query: String,
        paths: Vec<String>,
    },
    ReadFile {
        path: String,
        offset: usize,
        limit: usize,
    },
    GitStatus,
    GitDiff {
        paths: Vec<String>,
    },
    ApplyPatch {
        patch: String,
    },
    ReplaceText {
        path: String,
        old_text: String,
        new_text: String,
    },
    StartCommand {
        command: String,
        cwd: String,
        timeout_ms: u64,
    },
    PollCommand {
        process_id: Uuid,
        after_sequence: u64,
    },
    StopCommand {
        process_id: Uuid,
        after_sequence: u64,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(tag = "result", rename_all = "snake_case")]
pub enum ToolResult {
    Files {
        paths: Vec<String>,
        truncated: bool,
    },
    Matches {
        matches: Vec<SearchMatch>,
        truncated: bool,
    },
    File {
        content: String,
        offset: usize,
        next_offset: Option<usize>,
        truncated: bool,
    },
    Output {
        content: String,
        truncated: bool,
    },
    FilesChanged {
        paths: Vec<String>,
    },
    CommandStarted {
        process_id: Uuid,
    },
    CommandPoll {
        process_id: Uuid,
        status: ProcessStatus,
        output: Vec<CommandOutput>,
        /// Oldest sequence still retained; a newer value than requested signals lost output.
        earliest_sequence: u64,
        /// Cursor to persist for the next poll.
        next_sequence: u64,
        truncated: bool,
    },
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SearchMatch {
    pub path: String,
    pub line: usize,
    pub content: String,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ProcessStatus {
    Running,
    Exited { code: Option<i32> },
    TimedOut,
    Stopped,
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct CommandOutput {
    pub sequence: u64,
    pub stream: OutputStream,
    pub content: String,
    pub truncated: bool,
}

#[derive(Clone, Copy, Debug, Deserialize, Eq, PartialEq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum OutputStream {
    Stdout,
    Stderr,
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn execution_limits_reject_incomplete_or_invalid_policy() {
        let limits = ExecutionLimits::standalone();
        assert!(limits.validate().is_ok());

        let mut value = serde_json::to_value(&limits).unwrap();
        value["max_results"] = 0.into();
        let limits: ExecutionLimits = serde_json::from_value(value).unwrap();
        assert_eq!(
            limits.validate().unwrap_err(),
            "runner limits must be nonzero"
        );

        let mut limits = ExecutionLimits::standalone();
        limits.max_cached_response_bytes = limits.max_output_bytes;
        assert_eq!(
            limits.validate().unwrap_err(),
            "response cache cannot retain one maximum-sized encoded response"
        );

        let mut limits = ExecutionLimits::standalone();
        limits.max_blocking_tools = MAX_BLOCKING_TOOLS + 1;
        assert_eq!(
            limits.validate().unwrap_err(),
            "max_blocking_tools exceeds the supported maximum"
        );

        let mut value = serde_json::to_value(ExecutionLimits::standalone()).unwrap();
        value["unexpected"] = true.into();
        assert!(serde_json::from_value::<ExecutionLimits>(value).is_err());
    }

    #[test]
    fn request_has_a_stable_tagged_json_shape() {
        let request = ToolRequest::ReadFile {
            path: "src/lib.rs".into(),
            offset: 10,
            limit: 20,
        };

        assert_eq!(
            serde_json::to_value(request).unwrap(),
            serde_json::json!({
                "tool": "read_file",
                "path": "src/lib.rs",
                "offset": 10,
                "limit": 20
            })
        );
    }

    #[test]
    fn connected_request_authority_has_a_stable_json_shape() {
        let session_id = Uuid::new_v4();
        let request_id = Uuid::new_v4();
        let envelope = RequestEnvelope {
            protocol_version: PROTOCOL_VERSION,
            request_id,
            authority: Some(AuthorityLease {
                session_id,
                ownership_epoch: 7,
                ttl_ms: MAX_AUTHORITY_LEASE_MS,
            }),
            request: ToolRequest::GitStatus,
        };

        assert_eq!(
            serde_json::to_value(envelope).unwrap(),
            serde_json::json!({
                "protocol_version": PROTOCOL_VERSION,
                "request_id": request_id,
                "authority": {
                    "session_id": session_id,
                    "ownership_epoch": 7,
                    "ttl_ms": MAX_AUTHORITY_LEASE_MS
                },
                "request": {"tool": "git_status"}
            })
        );
    }
}
