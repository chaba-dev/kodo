use std::fs;
use std::io::Write;
use std::path::PathBuf;
use std::process::{Command, Output, Stdio};
use std::time::Duration;

use thiserror::Error;
use uuid::Uuid;

use crate::process::{ProcessError, ProcessManager};
use crate::protocol::{SearchMatch, ToolRequest, ToolResult};
use crate::workspace::{Workspace, WorkspaceError};

const DEFAULT_MAX_OUTPUT_BYTES: usize = 256 * 1024;
const DEFAULT_MAX_RESULTS: usize = 1_000;

#[derive(Debug, Error)]
pub enum RunnerError {
    #[error(transparent)]
    Workspace(#[from] WorkspaceError),
    #[error("failed to read {path}: {source}")]
    Read {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to run Git: {0}")]
    GitIo(#[source] std::io::Error),
    #[error("Git command failed: {0}")]
    Git(String),
    #[error("patch is invalid: {0}")]
    Patch(String),
    #[error("path is not valid UTF-8: {0}")]
    NonUtf8Path(PathBuf),
    #[error(transparent)]
    Process(#[from] ProcessError),
}

#[derive(Clone, Debug)]
pub struct Runner {
    workspace: Workspace,
    max_output_bytes: usize,
    max_results: usize,
    processes: ProcessManager,
}

impl Runner {
    pub fn new(workspace: Workspace) -> Self {
        Self {
            workspace,
            max_output_bytes: DEFAULT_MAX_OUTPUT_BYTES,
            max_results: DEFAULT_MAX_RESULTS,
            processes: ProcessManager::new(DEFAULT_MAX_OUTPUT_BYTES),
        }
    }

    pub fn with_limits(workspace: Workspace, max_output_bytes: usize, max_results: usize) -> Self {
        Self {
            workspace,
            max_output_bytes,
            max_results,
            processes: ProcessManager::new(max_output_bytes),
        }
    }

    pub async fn execute(&self, request: ToolRequest) -> Result<ToolResult, RunnerError> {
        match request {
            ToolRequest::ListFiles { path } => self.list_files(&path),
            ToolRequest::SearchCode { query, paths } => self.search_code(&query, &paths),
            ToolRequest::ReadFile {
                path,
                offset,
                limit,
            } => self.read_file(&path, offset, limit),
            ToolRequest::GitStatus => self.git_output(["status", "--short"], &[]),
            ToolRequest::GitDiff { paths } => self.git_diff(&paths),
            ToolRequest::ApplyPatch { patch } => self.apply_patch(&patch),
            ToolRequest::StartCommand {
                command,
                cwd,
                timeout_ms,
            } => self.start_command(&command, &cwd, timeout_ms).await,
            ToolRequest::PollCommand {
                process_id,
                after_sequence,
            } => self.poll_command(process_id, after_sequence).await,
            ToolRequest::StopCommand {
                process_id,
                after_sequence,
            } => self.stop_command(process_id, after_sequence).await,
        }
    }

    async fn start_command(
        &self,
        command: &str,
        cwd: &str,
        timeout_ms: u64,
    ) -> Result<ToolResult, RunnerError> {
        let cwd = self.workspace.resolve(cwd)?;
        let process_id = self
            .processes
            .start(command, &cwd, Duration::from_millis(timeout_ms))
            .await?;
        Ok(ToolResult::CommandStarted { process_id })
    }

    async fn poll_command(
        &self,
        process_id: Uuid,
        after_sequence: u64,
    ) -> Result<ToolResult, RunnerError> {
        let poll = self.processes.poll(process_id, after_sequence).await?;
        Ok(ToolResult::CommandPoll {
            process_id,
            status: poll.status,
            output: poll.output,
            earliest_sequence: poll.earliest_sequence,
            next_sequence: poll.next_sequence,
            truncated: poll.truncated,
        })
    }

    async fn stop_command(
        &self,
        process_id: Uuid,
        after_sequence: u64,
    ) -> Result<ToolResult, RunnerError> {
        let poll = self.processes.stop(process_id, after_sequence).await?;
        Ok(ToolResult::CommandPoll {
            process_id,
            status: poll.status,
            output: poll.output,
            earliest_sequence: poll.earliest_sequence,
            next_sequence: poll.next_sequence,
            truncated: poll.truncated,
        })
    }

    fn list_files(&self, path: &str) -> Result<ToolResult, RunnerError> {
        let relative = self.confined_relative(path)?;
        let mut args = vec![
            "ls-files".to_owned(),
            "--cached".to_owned(),
            "--others".to_owned(),
            "--exclude-standard".to_owned(),
            "--".to_owned(),
        ];
        args.push(relative);
        let output = self.git(args)?;
        let files = successful_stdout(output)?;
        let mut paths: Vec<_> = files.lines().map(str::to_owned).collect();
        paths.sort_unstable();
        let truncated = paths.len() > self.max_results;
        paths.truncate(self.max_results);

        Ok(ToolResult::Files { paths, truncated })
    }

    fn search_code(&self, query: &str, paths: &[String]) -> Result<ToolResult, RunnerError> {
        let search_paths = if paths.is_empty() {
            vec![String::new()]
        } else {
            paths.to_vec()
        };
        let mut matches = Vec::new();
        let mut truncated = false;

        for search_path in search_paths {
            let ToolResult::Files {
                paths,
                truncated: files_truncated,
            } = self.list_files(&search_path)?
            else {
                unreachable!();
            };
            truncated |= files_truncated;

            for path in paths {
                let resolved = self.workspace.resolve(&path)?;
                if !resolved.is_file() {
                    continue;
                }

                let Ok(content) = fs::read_to_string(&resolved) else {
                    continue;
                };

                for (index, line) in content.lines().enumerate() {
                    if line.contains(query) {
                        if matches.len() == self.max_results {
                            truncated = true;
                            break;
                        }
                        matches.push(SearchMatch {
                            path: path.clone(),
                            line: index + 1,
                            content: line.to_owned(),
                        });
                    }
                }

                if matches.len() == self.max_results {
                    break;
                }
            }

            if matches.len() == self.max_results {
                break;
            }
        }

        Ok(ToolResult::Matches { matches, truncated })
    }

    fn read_file(
        &self,
        path: &str,
        offset: usize,
        limit: usize,
    ) -> Result<ToolResult, RunnerError> {
        let resolved = self.workspace.resolve(path)?;
        let content = fs::read_to_string(&resolved).map_err(|source| RunnerError::Read {
            path: resolved,
            source,
        })?;
        let lines: Vec<_> = content.lines().collect();
        let selected = lines
            .iter()
            .skip(offset)
            .take(limit)
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        let next_line = offset.saturating_add(limit);
        let next_offset = (next_line < lines.len()).then_some(next_line);
        let (content, bytes_truncated) = truncate_utf8(selected, self.max_output_bytes);

        Ok(ToolResult::File {
            content,
            offset,
            next_offset,
            truncated: bytes_truncated || next_offset.is_some(),
        })
    }

    fn git_diff(&self, paths: &[String]) -> Result<ToolResult, RunnerError> {
        let relative_paths = paths
            .iter()
            .map(|path| self.confined_relative(path))
            .collect::<Result<Vec<_>, _>>()?;
        self.git_output(["diff", "HEAD", "--"], &relative_paths)
    }

    fn apply_patch(&self, patch: &str) -> Result<ToolResult, RunnerError> {
        let paths = self.patch_paths(patch)?;
        let check = self.git_with_input(["apply", "--check"], patch)?;
        successful_patch(check)?;
        let applied = self.git_with_input(["apply"], patch)?;
        successful_patch(applied)?;
        Ok(ToolResult::FilesChanged { paths })
    }

    fn patch_paths(&self, patch: &str) -> Result<Vec<String>, RunnerError> {
        let output = self.git_with_input(["apply", "--numstat", "-z"], patch)?;
        let stdout = successful_patch(output)?;
        let mut paths = Vec::new();

        for record in stdout
            .split(|byte| *byte == 0)
            .filter(|record| !record.is_empty())
        {
            let path = record
                .splitn(3, |byte| *byte == b'\t')
                .nth(2)
                .ok_or_else(|| RunnerError::Patch("unexpected Git numstat output".into()))?;
            let path = String::from_utf8(path.to_vec())
                .map_err(|_| RunnerError::Patch("patch path is not valid UTF-8".into()))?;
            self.workspace.resolve_new(&path)?;
            paths.push(path);
        }

        if paths.is_empty() {
            return Err(RunnerError::Patch("patch does not affect any files".into()));
        }

        paths.sort_unstable();
        paths.dedup();
        Ok(paths)
    }

    fn git_output<const N: usize>(
        &self,
        args: [&str; N],
        paths: &[String],
    ) -> Result<ToolResult, RunnerError> {
        let output = self.git(
            args.into_iter()
                .map(str::to_owned)
                .chain(paths.iter().cloned()),
        )?;
        let content = successful_stdout(output)?;
        let (content, truncated) = truncate_utf8(content, self.max_output_bytes);
        Ok(ToolResult::Output { content, truncated })
    }

    fn git<I, S>(&self, args: I) -> Result<Output, RunnerError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        Command::new("git")
            .args(args)
            .current_dir(self.workspace.root())
            .output()
            .map_err(RunnerError::GitIo)
    }

    fn git_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &str,
    ) -> Result<Output, RunnerError> {
        let mut child = Command::new("git")
            .args(args)
            .current_dir(self.workspace.root())
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .spawn()
            .map_err(RunnerError::GitIo)?;
        child
            .stdin
            .take()
            .expect("piped stdin must be available")
            .write_all(input.as_bytes())
            .map_err(RunnerError::GitIo)?;
        child.wait_with_output().map_err(RunnerError::GitIo)
    }

    fn confined_relative(&self, path: &str) -> Result<String, RunnerError> {
        let resolved = self.workspace.resolve(path)?;
        let relative = resolved
            .strip_prefix(self.workspace.root())
            .expect("confined workspace path must have workspace prefix");
        if relative.as_os_str().is_empty() {
            return Ok(".".to_owned());
        }
        relative
            .to_str()
            .map(str::to_owned)
            .ok_or_else(|| RunnerError::NonUtf8Path(relative.to_path_buf()))
    }
}

fn successful_stdout(output: Output) -> Result<String, RunnerError> {
    if output.status.success() {
        Ok(String::from_utf8_lossy(&output.stdout).into_owned())
    } else {
        Err(RunnerError::Git(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ))
    }
}

fn successful_patch(output: Output) -> Result<Vec<u8>, RunnerError> {
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(RunnerError::Patch(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ))
    }
}

fn truncate_utf8(mut content: String, max_bytes: usize) -> (String, bool) {
    if content.len() <= max_bytes {
        return (content, false);
    }

    let mut boundary = max_bytes;
    while boundary > 0 && !content.is_char_boundary(boundary) {
        boundary -= 1;
    }
    content.truncate(boundary);
    (content, true)
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::path::Path;

    use tempfile::TempDir;

    use super::*;

    #[tokio::test]
    async fn reads_lines_with_offsets_and_reports_truncation() {
        let repository = repository();
        fs::write(repository.path().join("notes.txt"), "one\ntwo\nthree\n").unwrap();
        let runner = runner(&repository);

        assert_eq!(
            runner
                .execute(ToolRequest::ReadFile {
                    path: "notes.txt".into(),
                    offset: 1,
                    limit: 1,
                })
                .await
                .unwrap(),
            ToolResult::File {
                content: "two".into(),
                offset: 1,
                next_offset: Some(2),
                truncated: true,
            }
        );
    }

    #[tokio::test]
    async fn lists_and_searches_tracked_and_untracked_files() {
        let repository = repository();
        fs::write(repository.path().join("tracked.txt"), "find me\n").unwrap();
        git(repository.path(), ["add", "tracked.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        fs::write(repository.path().join("untracked.txt"), "also find me\n").unwrap();
        let runner = runner(&repository);

        let ToolResult::Files { paths, truncated } = runner
            .execute(ToolRequest::ListFiles {
                path: String::new(),
            })
            .await
            .unwrap()
        else {
            panic!("expected files");
        };
        assert_eq!(paths, ["tracked.txt", "untracked.txt"]);
        assert!(!truncated);

        let ToolResult::Matches { matches, truncated } = runner
            .execute(ToolRequest::SearchCode {
                query: "find me".into(),
                paths: vec![],
            })
            .await
            .unwrap()
        else {
            panic!("expected matches");
        };
        assert_eq!(matches.len(), 2);
        assert!(!truncated);
    }

    #[tokio::test]
    async fn reports_status_and_the_resulting_diff() {
        let repository = repository();
        fs::write(repository.path().join("file.txt"), "before\n").unwrap();
        git(repository.path(), ["add", "file.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        fs::write(repository.path().join("file.txt"), "after\n").unwrap();
        let runner = runner(&repository);

        let ToolResult::Output { content, .. } =
            runner.execute(ToolRequest::GitStatus).await.unwrap()
        else {
            panic!("expected output");
        };
        assert_eq!(content, " M file.txt\n");

        let ToolResult::Output { content, .. } = runner
            .execute(ToolRequest::GitDiff { paths: vec![] })
            .await
            .unwrap()
        else {
            panic!("expected output");
        };
        assert!(content.contains("-before"));
        assert!(content.contains("+after"));
    }

    #[tokio::test]
    async fn applies_a_patch_and_reports_affected_paths() {
        let repository = repository();
        fs::write(repository.path().join("file.txt"), "before\n").unwrap();
        git(repository.path(), ["add", "file.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        let runner = runner(&repository);

        let result = runner
            .execute(ToolRequest::ApplyPatch {
                patch: "--- a/file.txt\n+++ b/file.txt\n@@ -1 +1 @@\n-before\n+after\n".into(),
            })
            .await
            .unwrap();

        assert_eq!(
            result,
            ToolResult::FilesChanged {
                paths: vec!["file.txt".into()]
            }
        );
        assert_eq!(
            fs::read_to_string(repository.path().join("file.txt")).unwrap(),
            "after\n"
        );
    }

    #[tokio::test]
    async fn rejects_patch_paths_outside_the_workspace() {
        let repository = repository();
        let runner = runner(&repository);

        let error = runner
            .execute(ToolRequest::ApplyPatch {
                patch: "--- /dev/null\n+++ b/../outside.txt\n@@ -0,0 +1 @@\n+nope\n".into(),
            })
            .await
            .unwrap_err();

        assert!(matches!(
            error,
            RunnerError::Patch(_) | RunnerError::Workspace(_)
        ));
        assert!(
            !repository
                .path()
                .parent()
                .unwrap()
                .join("outside.txt")
                .exists()
        );
    }

    #[tokio::test]
    async fn starts_and_polls_a_command_through_typed_dispatch() {
        let repository = repository();
        let runner = runner(&repository);

        let ToolResult::CommandStarted { process_id } = runner
            .execute(ToolRequest::StartCommand {
                command: "printf runner-output".into(),
                cwd: String::new(),
                timeout_ms: 1_000,
            })
            .await
            .unwrap()
        else {
            panic!("expected a process identifier");
        };

        let output = tokio::time::timeout(Duration::from_secs(2), async {
            let mut output = String::new();
            let mut after_sequence = 0;
            loop {
                let result = runner
                    .execute(ToolRequest::PollCommand {
                        process_id,
                        after_sequence,
                    })
                    .await
                    .unwrap();
                let ToolResult::CommandPoll {
                    status,
                    output: chunks,
                    next_sequence,
                    ..
                } = result
                else {
                    panic!("expected command output");
                };
                output.extend(chunks.into_iter().map(|chunk| chunk.content));
                after_sequence = next_sequence.saturating_sub(1);
                if matches!(
                    status,
                    crate::protocol::ProcessStatus::Exited { code: Some(0) }
                ) {
                    return output;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("command did not finish");

        assert_eq!(output, "runner-output");
    }

    fn runner(repository: &TempDir) -> Runner {
        Runner::new(Workspace::from_root(repository.path()).unwrap())
    }

    fn repository() -> TempDir {
        let directory = TempDir::new().unwrap();
        git(directory.path(), ["init", "--quiet"]);
        git(
            directory.path(),
            ["config", "user.email", "test@example.com"],
        );
        git(directory.path(), ["config", "user.name", "Test"]);
        directory
    }

    fn git<const N: usize>(directory: &Path, args: [&str; N]) {
        let status = Command::new("git")
            .args(args)
            .current_dir(directory)
            .status()
            .unwrap();
        assert!(status.success());
    }
}
