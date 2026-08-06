use serde::{Deserialize, Serialize};

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
}

#[derive(Clone, Debug, Deserialize, Eq, PartialEq, Serialize)]
pub struct SearchMatch {
    pub path: String,
    pub line: usize,
    pub content: String,
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
