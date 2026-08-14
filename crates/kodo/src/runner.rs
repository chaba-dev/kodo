//! Typed local tools built around a single registered [`Workspace`].
//!
//! Every result is bounded before crossing the daemon protocol. Filesystem mutations are
//! serialized, while read-only blocking work is concurrency-limited off the async runtime.

use std::io::{Read, Write};
use std::path::{Path, PathBuf};
use std::process::{Command, ExitStatus, Stdio};
use std::sync::Arc;
use std::time::Duration;

use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWriteExt};
use tokio::process::Command as TokioCommand;
#[cfg(test)]
use tokio::sync::Notify;
use tokio::sync::{Mutex, Semaphore};
use uuid::Uuid;

use crate::authority::{AuthorityError, AuthorityGuard};
use crate::process::{
    ProcessError, ProcessGroupGuard, ProcessManager, cleanup_process_group, terminate_process_group,
};
use crate::protocol::{ExecutionLimits, MAX_BLOCKING_TOOLS, SearchMatch, ToolRequest, ToolResult};
use crate::workspace::{Workspace, WorkspaceError};

// Git metadata is an implementation buffer, unlike patch input policy supplied by Phoenix.
const MAX_GIT_METADATA_BYTES: usize = 1024 * 1024;

#[derive(Debug, Error)]
pub enum RunnerError {
    #[error(transparent)]
    Workspace(#[from] WorkspaceError),
    #[error("failed to run Git: {0}")]
    GitIo(#[source] std::io::Error),
    #[error("Git command failed: {0}")]
    Git(String),
    #[error("patch is invalid: {0}")]
    Patch(String),
    #[error("path is not valid UTF-8: {0}")]
    NonUtf8Path(PathBuf),
    #[error("{0}")]
    OutputLimit(String),
    #[error("runner task failed: {0}")]
    Task(String),
    #[error("{0}")]
    Authority(String),
    #[error(transparent)]
    Process(#[from] ProcessError),
}

impl From<AuthorityError> for RunnerError {
    fn from(error: AuthorityError) -> Self {
        Self::Authority(error.to_string())
    }
}

#[derive(Clone, Debug)]
/// Executes the protocol tool surface within one workspace and one process registry.
pub struct Runner {
    workspace: Workspace,
    limits: ExecutionLimits,
    processes: ProcessManager,
    // Keep patch validation and application atomic with respect to other runner patch requests.
    mutation_lock: Arc<Mutex<()>>,
    // Git and filesystem calls are blocking; cap them to protect runtime and host resources.
    blocking_tools: Arc<Semaphore>,
    #[cfg(test)]
    patch_mutation_gate: Option<Arc<PatchMutationGate>>,
}

#[cfg(test)]
#[derive(Debug)]
pub(crate) struct PatchMutationGate {
    spawned: Notify,
    release: Notify,
}

#[cfg(test)]
impl PatchMutationGate {
    pub(crate) fn new() -> Arc<Self> {
        Arc::new(Self {
            spawned: Notify::new(),
            release: Notify::new(),
        })
    }

    pub(crate) async fn wait_until_spawned(&self) {
        self.spawned.notified().await;
    }

    pub(crate) fn release(&self) {
        self.release.notify_one();
    }
}

impl Runner {
    pub fn new(workspace: Workspace) -> Self {
        Self::from_limits(workspace, ExecutionLimits::standalone())
            .expect("standalone runner limits must be valid")
    }

    #[cfg(test)]
    pub fn with_limits(workspace: Workspace, max_output_bytes: usize, max_results: usize) -> Self {
        let mut limits = ExecutionLimits::standalone();
        limits.max_output_bytes = max_output_bytes;
        limits.max_results = max_results;
        Self::from_limits(workspace, limits).expect("test runner limits must be valid")
    }

    pub fn from_limits(workspace: Workspace, limits: ExecutionLimits) -> Result<Self, String> {
        limits.validate()?;
        if limits.max_blocking_tools > MAX_BLOCKING_TOOLS
            || limits.max_blocking_tools > Semaphore::MAX_PERMITS
        {
            return Err("max_blocking_tools exceeds the runtime semaphore limit".into());
        }
        let processes = ProcessManager::with_limits(
            limits.max_output_bytes,
            limits.max_retained_processes,
            limits.max_process_output_chunks,
        );
        let max_blocking_tools = limits.max_blocking_tools;

        Ok(Self {
            workspace,
            limits,
            processes,
            mutation_lock: Arc::new(Mutex::new(())),
            blocking_tools: Arc::new(Semaphore::new(max_blocking_tools)),
            #[cfg(test)]
            patch_mutation_gate: None,
        })
    }

    #[cfg(test)]
    pub(crate) fn with_patch_mutation_gate(mut self, gate: Arc<PatchMutationGate>) -> Self {
        self.patch_mutation_gate = Some(gate);
        self
    }

    pub(crate) fn limits(&self) -> &ExecutionLimits {
        &self.limits
    }

    pub async fn execute(&self, request: ToolRequest) -> Result<ToolResult, RunnerError> {
        self.execute_authorized(request, AuthorityGuard::unmanaged())
            .await
    }

    pub(crate) async fn execute_authorized(
        &self,
        request: ToolRequest,
        authority: AuthorityGuard,
    ) -> Result<ToolResult, RunnerError> {
        authority.ensure_valid()?;
        match request {
            ToolRequest::StartCommand {
                command,
                cwd,
                timeout_ms,
            } => {
                self.start_command(&command, &cwd, timeout_ms, authority)
                    .await
            }
            ToolRequest::PollCommand {
                process_id,
                after_sequence,
            } => self.poll_command(process_id, after_sequence).await,
            ToolRequest::StopCommand {
                process_id,
                after_sequence,
            } => self.stop_command(process_id, after_sequence).await,
            ToolRequest::ApplyPatch { patch } => {
                self.apply_patch_authorized(patch, authority).await
            }
            request => {
                let runner = self.clone();
                let blocking_authority = authority.clone();
                let permit = Arc::clone(&self.blocking_tools)
                    .acquire_owned()
                    .await
                    .map_err(|error| RunnerError::Task(error.to_string()))?;
                tokio::task::spawn_blocking(move || {
                    // Hold the permit for the complete blocking operation, including child reaping.
                    let _permit = permit;
                    runner.execute_blocking(request, &blocking_authority)
                })
                .await
                .map_err(|error| RunnerError::Task(error.to_string()))?
            }
        }
    }

    fn execute_blocking(
        &self,
        request: ToolRequest,
        authority: &AuthorityGuard,
    ) -> Result<ToolResult, RunnerError> {
        authority.ensure_valid()?;
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
            ToolRequest::ApplyPatch { .. }
            | ToolRequest::StartCommand { .. }
            | ToolRequest::PollCommand { .. }
            | ToolRequest::StopCommand { .. } => {
                unreachable!("mutation and process requests are dispatched asynchronously")
            }
        }
    }

    async fn start_command(
        &self,
        command: &str,
        cwd: &str,
        timeout_ms: u64,
        authority: AuthorityGuard,
    ) -> Result<ToolResult, RunnerError> {
        authority.ensure_valid()?;
        let cwd = self.workspace.resolve(cwd)?;
        let process_id = self
            .processes
            .start_authorized(command, &cwd, Duration::from_millis(timeout_ms), authority)
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
        let (files, output_truncated) = successful_stdout(output)?;
        let mut paths: Vec<_> = files.lines().map(str::to_owned).collect();
        paths.sort_unstable();
        let mut bytes = 0;
        let mut truncated = output_truncated || paths.len() > self.limits.max_results;
        paths.truncate(self.limits.max_results);
        paths.retain(|path| {
            if bytes + path.len() > self.limits.max_output_bytes {
                truncated = true;
                false
            } else {
                bytes += path.len();
                true
            }
        });

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
        let mut output_bytes = 0;

        'search: for search_path in search_paths {
            let ToolResult::Files {
                paths,
                truncated: files_truncated,
            } = self.list_files(&search_path)?
            else {
                unreachable!();
            };
            truncated |= files_truncated;

            for path in paths {
                if !self.workspace.is_file(&path)? {
                    continue;
                }

                let Ok(content) = self
                    .workspace
                    .read_to_string_bounded(&path, self.limits.max_file_input_bytes)
                else {
                    // Search is best-effort across repository files; binary and unreadable files
                    // should not prevent useful matches from other files.
                    continue;
                };

                for (index, line) in content.lines().enumerate() {
                    if line.contains(query) {
                        if matches.len() == self.limits.max_results {
                            truncated = true;
                            break 'search;
                        }
                        let path_bytes = path.len();
                        if output_bytes + path_bytes >= self.limits.max_output_bytes {
                            truncated = true;
                            break 'search;
                        }
                        let remaining = self.limits.max_output_bytes - output_bytes - path_bytes;
                        let (content, content_truncated) =
                            truncate_utf8(line.to_owned(), remaining);
                        matches.push(SearchMatch {
                            path: path.clone(),
                            line: index + 1,
                            content,
                        });
                        output_bytes += path_bytes + matches.last().unwrap().content.len();
                        if content_truncated {
                            truncated = true;
                            break 'search;
                        }
                    }
                }
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
        if limit == 0 {
            return Err(RunnerError::OutputLimit(
                "read_file limit must be greater than zero".into(),
            ));
        }
        let content = self
            .workspace
            .read_to_string_bounded(path, self.limits.max_file_input_bytes)?;
        let lines: Vec<_> = content.lines().collect();
        let selected = lines
            .iter()
            .skip(offset)
            .take(limit)
            .copied()
            .collect::<Vec<_>>()
            .join("\n");
        if selected.len() > self.limits.max_output_bytes {
            return Err(RunnerError::OutputLimit(format!(
                "requested file lines exceed {} byte output limit",
                self.limits.max_output_bytes
            )));
        }
        let next_line = offset.saturating_add(limit);
        let next_offset = (next_line < lines.len()).then_some(next_line);

        Ok(ToolResult::File {
            content: selected,
            offset,
            next_offset,
            truncated: next_offset.is_some(),
        })
    }

    fn git_diff(&self, paths: &[String]) -> Result<ToolResult, RunnerError> {
        let relative_paths = paths
            .iter()
            .map(|path| self.confined_relative_new(path))
            .collect::<Result<Vec<_>, _>>()?;
        let head_exists = self
            .git(["rev-parse", "--verify", "--quiet", "HEAD"])?
            .status
            .success();
        let tracked_args = if head_exists {
            vec![
                "diff".to_owned(),
                "--binary".to_owned(),
                "--no-ext-diff".to_owned(),
                "--no-textconv".to_owned(),
                "HEAD".to_owned(),
                "--".to_owned(),
            ]
        } else {
            vec![
                "diff".to_owned(),
                "--cached".to_owned(),
                "--binary".to_owned(),
                "--no-ext-diff".to_owned(),
                "--no-textconv".to_owned(),
                "--".to_owned(),
            ]
        };

        // Disable user-configured diff drivers: inspection must not execute external diff commands
        // or text converters.
        let tracked = self.git(
            tracked_args
                .into_iter()
                .chain(relative_paths.iter().cloned()),
        )?;
        let (mut content, mut truncated) = successful_stdout(tracked)?;

        let mut untracked_args = vec![
            "ls-files".to_owned(),
            "--others".to_owned(),
            "--exclude-standard".to_owned(),
            "-z".to_owned(),
            "--".to_owned(),
        ];

        untracked_args.extend(relative_paths);
        let (untracked, untracked_truncated) = successful_stdout(self.git_with_limit(
            untracked_args,
            MAX_GIT_METADATA_BYTES,
            None,
        )?)?;
        if untracked_truncated {
            return Err(RunnerError::OutputLimit(
                "untracked file list exceeds internal byte limit".into(),
            ));
        }
        for path in untracked.split('\0').filter(|path| !path.is_empty()) {
            if content.len() >= self.limits.max_output_bytes {
                truncated = true;
                break;
            }
            self.workspace.resolve(path)?;
            let output = self.git_with_limit(
                [
                    "diff",
                    "--no-index",
                    "--binary",
                    "--no-ext-diff",
                    "--no-textconv",
                    "--",
                    "/dev/null",
                    path,
                ],
                self.limits.max_output_bytes - content.len(),
                None,
            )?;
            if !matches!(output.status.code(), Some(0 | 1)) {
                let (error, _) = lossy_bounded(&output.stderr, output.limit);
                return Err(RunnerError::Git(error.trim().to_owned()));
            }
            let (converted, conversion_truncated) =
                lossy_bounded(&output.stdout, self.limits.max_output_bytes - content.len());
            content.push_str(&converted);
            truncated |= output.stdout_truncated || conversion_truncated;
            if output.stdout_truncated || conversion_truncated {
                break;
            }
        }

        Ok(ToolResult::Output { content, truncated })
    }

    async fn apply_patch_authorized(
        &self,
        patch: String,
        authority: AuthorityGuard,
    ) -> Result<ToolResult, RunnerError> {
        if patch.len() > self.limits.max_patch_input_bytes {
            return Err(RunnerError::Patch(format!(
                "patch exceeds {} byte limit",
                self.limits.max_patch_input_bytes
            )));
        }
        let _permit = Arc::clone(&self.blocking_tools)
            .acquire_owned()
            .await
            .map_err(|error| RunnerError::Task(error.to_string()))?;
        let _mutation = self.mutation_lock.lock().await;
        let runner = self.clone();
        let preflight_patch = patch.clone();
        let preflight_authority = authority.clone();
        let paths = tokio::task::spawn_blocking(move || {
            runner.preflight_patch(&preflight_patch, &preflight_authority)
        })
        .await
        .map_err(|error| RunnerError::Task(error.to_string()))??;
        authority.ensure_valid()?;
        let applied = self.git_apply_authorized(&patch, &authority).await?;
        successful_patch(applied)?;
        Ok(ToolResult::FilesChanged { paths })
    }

    fn preflight_patch(
        &self,
        patch: &str,
        authority: &AuthorityGuard,
    ) -> Result<Vec<String>, RunnerError> {
        authority.ensure_valid()?;
        // Derive and confine every affected path before asking Git to mutate the worktree.
        let paths = self.patch_paths(patch)?;
        // Preflight under the same mutation lock so a successful check describes the state applied.
        let check = self.git_with_input(["apply", "--check"], patch)?;
        successful_patch(check)?;
        authority.ensure_valid()?;
        Ok(paths)
    }

    async fn git_apply_authorized(
        &self,
        patch: &str,
        authority: &AuthorityGuard,
    ) -> Result<CapturedOutput, RunnerError> {
        authority.ensure_valid()?;
        let mut command = TokioCommand::new("git");
        command
            .args([
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.hooksPath=/dev/null",
                "apply",
            ])
            .current_dir(self.workspace.root())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_ATTR_NOSYSTEM", "1")
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            // Git may invoke filters while updating the worktree; keep them within the same
            // authority-controlled lifecycle as the direct Git process.
            .process_group(0);
        for variable in [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
        ] {
            command.env_remove(variable);
        }
        let mut child = command.spawn().map_err(RunnerError::GitIo)?;
        let mut process_group = ProcessGroupGuard::for_child(&child);
        let group = process_group.as_ref().and_then(ProcessGroupGuard::group);
        let mut stdin = child.stdin.take().expect("piped stdin must be available");
        let stdout = child.stdout.take().expect("piped stdout must be available");
        let stderr = child.stderr.take().expect("piped stderr must be available");
        #[cfg(test)]
        if let Some(gate) = &self.patch_mutation_gate {
            gate.spawned.notify_one();
            gate.release.notified().await;
        }
        let input = patch.as_bytes().to_vec();
        let input_writer = tokio::spawn(async move { stdin.write_all(&input).await });
        let limit = self.limits.max_output_bytes;
        let stdout_reader = tokio::spawn(read_async_bounded(stdout, limit));
        let stderr_reader = tokio::spawn(read_async_bounded(stderr, limit));

        let status = tokio::select! {
            biased;
            () = authority.wait_until_invalid() => {
                terminate_process_group(&mut child, group).await;
                None
            }
            status = child.wait() => Some(status.map_err(RunnerError::GitIo)?),
        };
        if status.is_some() {
            cleanup_process_group(group).await;
        }
        if let Some(process_group) = process_group.as_mut() {
            process_group.disarm();
        }
        let input_result = if status.is_none() {
            input_writer.abort();
            let _ = input_writer.await;
            Ok(())
        } else {
            input_writer
                .await
                .map_err(|error| RunnerError::Task(error.to_string()))?
        };
        let (stdout, stdout_truncated) = finish_git_reader(stdout_reader).await?;
        let (stderr, stderr_truncated) = finish_git_reader(stderr_reader).await?;
        let Some(status) = status else {
            return Err(AuthorityError::Lost.into());
        };
        if status.success() {
            input_result.map_err(RunnerError::GitIo)?;
        }
        Ok(CapturedOutput {
            status,
            stdout,
            stderr,
            stdout_truncated,
            stderr_truncated,
            limit,
        })
    }

    fn patch_paths(&self, patch: &str) -> Result<Vec<String>, RunnerError> {
        let output = self.git_with_limit(
            ["apply", "--numstat", "-z"],
            self.limits.max_patch_input_bytes,
            Some(patch.as_bytes()),
        )?;
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

        for line in patch.lines() {
            let path = ["rename from ", "rename to ", "copy from ", "copy to "]
                .iter()
                .find_map(|prefix| line.strip_prefix(prefix));
            let Some(path) = path else {
                continue;
            };
            if path.starts_with('"') {
                return Err(RunnerError::Patch(
                    "quoted rename and copy paths are not supported".into(),
                ));
            }
            self.workspace.resolve_new(path)?;
            paths.push(path.to_owned());
        }

        if paths.is_empty() {
            return Err(RunnerError::Patch("patch does not affect any files".into()));
        }

        paths.sort_unstable();
        paths.dedup();
        if paths.len() > self.limits.max_results {
            return Err(RunnerError::Patch(format!(
                "patch affects more than {} files",
                self.limits.max_results
            )));
        }
        if paths.iter().map(String::len).sum::<usize>() > self.limits.max_output_bytes {
            return Err(RunnerError::Patch(
                "affected patch paths exceed the output byte limit".into(),
            ));
        }
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
        let (content, truncated) = successful_stdout(output)?;
        Ok(ToolResult::Output { content, truncated })
    }

    fn git<I, S>(&self, args: I) -> Result<CapturedOutput, RunnerError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        self.git_with_limit(args, self.limits.max_output_bytes, None)
    }

    fn git_with_input<const N: usize>(
        &self,
        args: [&str; N],
        input: &str,
    ) -> Result<CapturedOutput, RunnerError> {
        self.git_with_limit(args, self.limits.max_output_bytes, Some(input.as_bytes()))
    }

    fn git_with_limit<I, S>(
        &self,
        args: I,
        limit: usize,
        input: Option<&[u8]>,
    ) -> Result<CapturedOutput, RunnerError>
    where
        I: IntoIterator<Item = S>,
        S: AsRef<std::ffi::OsStr>,
    {
        let mut command = Command::new("git");
        // Ignore ambient Git redirection and user/system configuration. Repository configuration
        // is still honored and is explicitly outside the MVP's OS-sandbox boundary.
        command
            .args([
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.hooksPath=/dev/null",
            ])
            .args(args)
            .current_dir(self.workspace.root())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_ATTR_NOSYSTEM", "1");
        for variable in [
            "GIT_DIR",
            "GIT_WORK_TREE",
            "GIT_INDEX_FILE",
            "GIT_OBJECT_DIRECTORY",
            "GIT_ALTERNATE_OBJECT_DIRECTORIES",
            "GIT_COMMON_DIR",
        ] {
            command.env_remove(variable);
        }
        run_command(&mut command, input, limit).map_err(RunnerError::GitIo)
    }

    fn confined_relative(&self, path: &str) -> Result<String, RunnerError> {
        let resolved = self.workspace.resolve(path)?;
        self.relative_path(&resolved)
    }

    fn confined_relative_new(&self, path: &str) -> Result<String, RunnerError> {
        let resolved = self.workspace.resolve_new(path)?;
        self.relative_path(&resolved)
    }

    fn relative_path(&self, resolved: &Path) -> Result<String, RunnerError> {
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

struct CapturedOutput {
    status: ExitStatus,
    stdout: Vec<u8>,
    stderr: Vec<u8>,
    stdout_truncated: bool,
    stderr_truncated: bool,
    limit: usize,
}

fn successful_stdout(output: CapturedOutput) -> Result<(String, bool), RunnerError> {
    if output.status.success() {
        let (content, conversion_truncated) = lossy_bounded(&output.stdout, output.limit);
        Ok((content, output.stdout_truncated || conversion_truncated))
    } else {
        let (error, _) = lossy_bounded(&output.stderr, output.limit);
        let mut error = error.trim().to_owned();
        if output.stderr_truncated {
            error.push_str("\n[stderr truncated]");
        }
        Err(RunnerError::Git(error))
    }
}

fn successful_patch(output: CapturedOutput) -> Result<Vec<u8>, RunnerError> {
    if output.status.success() {
        if output.stdout_truncated {
            return Err(RunnerError::Patch(
                "patch metadata exceeds internal byte limit".into(),
            ));
        }
        Ok(output.stdout)
    } else {
        let (error, _) = lossy_bounded(&output.stderr, output.limit);
        let mut error = error.trim().to_owned();
        if output.stderr_truncated {
            error.push_str("\n[stderr truncated]");
        }
        Err(RunnerError::Patch(error))
    }
}

fn run_command(
    command: &mut Command,
    input: Option<&[u8]>,
    limit: usize,
) -> Result<CapturedOutput, std::io::Error> {
    let mut child = command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()?;
    let stdout = child.stdout.take().expect("piped stdout must be available");
    let stderr = child.stderr.take().expect("piped stderr must be available");
    let stdout_reader = std::thread::spawn(move || read_bounded(stdout, limit));
    let stderr_reader = std::thread::spawn(move || read_bounded(stderr, limit));

    let input_error = input.and_then(|input| {
        child
            .stdin
            .take()
            .expect("piped stdin must be available")
            .write_all(input)
            .err()
    });
    let status = child.wait();
    let stdout = stdout_reader.join().expect("stdout reader thread panicked");
    let stderr = stderr_reader.join().expect("stderr reader thread panicked");
    let status = status?;
    let (stdout, stdout_truncated) = stdout?;
    let (stderr, stderr_truncated) = stderr?;
    if status.success()
        && let Some(error) = input_error
    {
        return Err(error);
    }
    Ok(CapturedOutput {
        status,
        stdout,
        stderr,
        stdout_truncated,
        stderr_truncated,
        limit,
    })
}

fn lossy_bounded(bytes: &[u8], limit: usize) -> (String, bool) {
    // Lossy UTF-8 decoding may expand one invalid input byte into a three-byte replacement scalar.
    truncate_utf8(String::from_utf8_lossy(bytes).into_owned(), limit)
}

fn read_bounded(mut reader: impl Read, limit: usize) -> Result<(Vec<u8>, bool), std::io::Error> {
    let mut output = Vec::with_capacity(limit.min(8 * 1024));
    let mut buffer = [0; 8 * 1024];
    let mut truncated = false;
    loop {
        // Continue draining after reaching the retention limit so a verbose child cannot block on
        // a full pipe while its parent waits for it to exit.
        let read = reader.read(&mut buffer)?;
        if read == 0 {
            return Ok((output, truncated));
        }
        let remaining = limit.saturating_sub(output.len());
        output.extend_from_slice(&buffer[..read.min(remaining)]);
        truncated |= read > remaining;
    }
}

async fn read_async_bounded(
    mut reader: impl AsyncRead + Unpin,
    limit: usize,
) -> Result<(Vec<u8>, bool), std::io::Error> {
    let mut output = Vec::with_capacity(limit.min(8 * 1024));
    let mut buffer = [0; 8 * 1024];
    let mut truncated = false;
    loop {
        let read = reader.read(&mut buffer).await?;
        if read == 0 {
            return Ok((output, truncated));
        }
        let remaining = limit.saturating_sub(output.len());
        output.extend_from_slice(&buffer[..read.min(remaining)]);
        truncated |= read > remaining;
    }
}

async fn finish_git_reader(
    mut reader: tokio::task::JoinHandle<Result<(Vec<u8>, bool), std::io::Error>>,
) -> Result<(Vec<u8>, bool), RunnerError> {
    match tokio::time::timeout(Duration::from_millis(25), &mut reader).await {
        Ok(result) => result
            .map_err(|error| RunnerError::Task(error.to_string()))?
            .map_err(RunnerError::GitIo),
        Err(_) => {
            // A descendant that inherited Git's output pipe must not hold the mutation lock after
            // its process group has been terminated.
            reader.abort();
            let _ = reader.await;
            Ok((Vec::new(), true))
        }
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
    async fn search_respects_byte_and_result_limits() {
        let repository = repository();
        fs::write(
            repository.path().join("large.txt"),
            "needle followed by a very long matching line\nneedle again\n",
        )
        .unwrap();
        let runner = Runner::with_limits(Workspace::from_root(repository.path()).unwrap(), 16, 1);

        let ToolResult::Matches { matches, truncated } = runner
            .execute(ToolRequest::SearchCode {
                query: "needle".into(),
                paths: vec![],
            })
            .await
            .unwrap()
        else {
            panic!("expected matches");
        };

        assert!(matches[0].content.len() <= 16);
        assert!(truncated);
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
    async fn repository_output_is_bounded_while_git_is_drained() {
        let repository = repository();
        for index in 0..20 {
            fs::write(
                repository.path().join(format!("file-{index}.txt")),
                "content",
            )
            .unwrap();
        }
        let runner = Runner::with_limits(Workspace::from_root(repository.path()).unwrap(), 16, 100);

        let ToolResult::Output { content, truncated } =
            runner.execute(ToolRequest::GitStatus).await.unwrap()
        else {
            panic!("expected repository output");
        };

        assert!(content.len() <= 16);
        assert!(truncated);
    }

    #[tokio::test]
    async fn diff_includes_untracked_files_in_an_unborn_repository() {
        let repository = repository();
        fs::write(repository.path().join("new.txt"), "new content\n").unwrap();
        let runner = runner(&repository);

        let ToolResult::Output { content, .. } = runner
            .execute(ToolRequest::GitDiff { paths: vec![] })
            .await
            .unwrap()
        else {
            panic!("expected diff output");
        };

        assert!(content.contains("new.txt"));
        assert!(content.contains("+new content"));
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
    async fn rejects_patch_paths_that_cannot_fit_in_the_result() {
        let repository = repository();
        let runner = Runner::with_limits(Workspace::from_root(repository.path()).unwrap(), 4, 100);
        let patch = "diff --git a/long.txt b/long.txt\nnew file mode 100644\n--- /dev/null\n+++ b/long.txt\n@@ -0,0 +1 @@\n+content\n";

        let error = runner
            .execute(ToolRequest::ApplyPatch {
                patch: patch.into(),
            })
            .await
            .unwrap_err();

        assert!(error.to_string().contains("affected patch paths"));
        assert!(!repository.path().join("long.txt").exists());
    }

    #[tokio::test]
    async fn applying_a_rename_reports_source_and_destination_paths() {
        let repository = repository();
        fs::write(repository.path().join("old.txt"), "content\n").unwrap();
        git(repository.path(), ["add", "old.txt"]);
        git(repository.path(), ["commit", "-m", "fixture"]);
        git(repository.path(), ["mv", "old.txt", "new.txt"]);
        let patch = git_stdout(repository.path(), ["diff", "--cached", "--binary"]);
        git(repository.path(), ["reset", "--hard", "HEAD"]);
        let runner = runner(&repository);

        let result = runner
            .execute(ToolRequest::ApplyPatch { patch })
            .await
            .unwrap();

        assert_eq!(
            result,
            ToolResult::FilesChanged {
                paths: vec!["new.txt".into(), "old.txt".into()]
            }
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

    #[test]
    fn lossy_git_output_remains_within_the_logical_byte_limit() {
        let (content, truncated) = lossy_bounded(&[0xff, 0xff], 4);

        assert!(content.len() <= 4);
        assert!(truncated);
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

    fn git_stdout<const N: usize>(directory: &Path, args: [&str; N]) -> String {
        let output = Command::new("git")
            .args(args)
            .current_dir(directory)
            .output()
            .unwrap();
        assert!(output.status.success());
        String::from_utf8(output.stdout).unwrap()
    }
}
