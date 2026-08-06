use serde::{Deserialize, Serialize};
use uuid::Uuid;

pub const PROTOCOL_VERSION: u16 = 2;

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct RequestEnvelope {
    pub protocol_version: u16,
    pub request_id: Uuid,
    pub request: ToolRequest,
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
        earliest_sequence: u64,
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
}
