use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use nix::sys::signal::{self, Signal};
use nix::unistd::Pid;
use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, ChildStderr, ChildStdout, Command};
use tokio::sync::{Mutex, mpsc};
use uuid::Uuid;

use crate::protocol::{CommandOutput, OutputStream, ProcessStatus};

#[derive(Debug, Error)]
pub enum ProcessError {
    #[error("failed to start command: {0}")]
    Start(#[source] std::io::Error),
    #[error("unknown process: {0}")]
    Unknown(Uuid),
    #[error("process supervisor for {0} stopped unexpectedly")]
    SupervisorStopped(Uuid),
}

#[derive(Clone)]
pub struct ProcessManager {
    entries: Arc<Mutex<HashMap<Uuid, ProcessEntry>>>,
    max_pending_output_bytes: usize,
}

impl std::fmt::Debug for ProcessManager {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        formatter
            .debug_struct("ProcessManager")
            .field("max_pending_output_bytes", &self.max_pending_output_bytes)
            .finish_non_exhaustive()
    }
}

struct ProcessEntry {
    state: Arc<StdMutex<ProcessState>>,
    stop: mpsc::Sender<StopReason>,
}

struct ProcessState {
    output: OutputBuffer,
    status: ProcessStatus,
}

struct OutputBuffer {
    chunks: VecDeque<CommandOutput>,
    bytes: usize,
    next_sequence: u64,
}

impl Default for OutputBuffer {
    fn default() -> Self {
        Self {
            chunks: VecDeque::new(),
            bytes: 0,
            next_sequence: 1,
        }
    }
}

#[derive(Debug, Eq, PartialEq)]
pub struct ProcessPoll {
    pub status: ProcessStatus,
    pub output: Vec<CommandOutput>,
    pub earliest_sequence: u64,
    pub next_sequence: u64,
    pub truncated: bool,
}

#[derive(Clone, Copy)]
enum StopReason {
    TimedOut,
    Stopped,
}

impl ProcessManager {
    pub fn new(max_pending_output_bytes: usize) -> Self {
        Self {
            entries: Arc::new(Mutex::new(HashMap::new())),
            max_pending_output_bytes,
        }
    }

    pub async fn start(
        &self,
        command: &str,
        cwd: &Path,
        timeout: Duration,
    ) -> Result<Uuid, ProcessError> {
        let mut child = Command::new("sh")
            .args(["-c", command])
            .current_dir(cwd)
            .stdin(Stdio::null())
            .stdout(Stdio::piped())
            .stderr(Stdio::piped())
            .kill_on_drop(true)
            .process_group(0)
            .spawn()
            .map_err(ProcessError::Start)?;
        let process_id = Uuid::new_v4();
        let stdout = child.stdout.take().expect("piped stdout must be available");
        let stderr = child.stderr.take().expect("piped stderr must be available");
        let state = Arc::new(StdMutex::new(ProcessState {
            output: OutputBuffer::default(),
            status: ProcessStatus::Running,
        }));
        let (stop, stop_receiver) = mpsc::channel(1);

        self.entries.lock().await.insert(
            process_id,
            ProcessEntry {
                state: Arc::clone(&state),
                stop,
            },
        );
        tokio::spawn(supervise(
            child,
            stdout,
            stderr,
            state,
            stop_receiver,
            timeout,
            self.max_pending_output_bytes,
        ));

        Ok(process_id)
    }

    pub async fn poll(
        &self,
        process_id: Uuid,
        after_sequence: u64,
    ) -> Result<ProcessPoll, ProcessError> {
        let entries = self.entries.lock().await;
        let entry = entries
            .get(&process_id)
            .ok_or(ProcessError::Unknown(process_id))?;
        let state = Arc::clone(&entry.state);
        drop(entries);
        let state = state.lock().expect("process state lock poisoned");
        let earliest_sequence = state
            .output
            .chunks
            .front()
            .map_or(state.output.next_sequence, |chunk| chunk.sequence);
        let output = state
            .output
            .chunks
            .iter()
            .filter(|chunk| chunk.sequence > after_sequence)
            .cloned()
            .collect::<Vec<_>>();
        let truncated = after_sequence.saturating_add(1) < earliest_sequence
            || output.iter().any(|chunk| chunk.truncated);

        Ok(ProcessPoll {
            status: state.status.clone(),
            output,
            earliest_sequence,
            next_sequence: state.output.next_sequence,
            truncated,
        })
    }

    pub async fn stop(
        &self,
        process_id: Uuid,
        after_sequence: u64,
    ) -> Result<ProcessPoll, ProcessError> {
        let entries = self.entries.lock().await;
        let entry = entries
            .get(&process_id)
            .ok_or(ProcessError::Unknown(process_id))?;
        let running = entry
            .state
            .lock()
            .expect("process state lock poisoned")
            .status
            == ProcessStatus::Running;
        let stop = entry.stop.clone();
        drop(entries);

        if running && stop.send(StopReason::Stopped).await.is_err() {
            return Err(ProcessError::SupervisorStopped(process_id));
        }
        wait_until_terminal(self, process_id, after_sequence).await
    }
}

async fn supervise(
    mut child: Child,
    stdout: ChildStdout,
    stderr: ChildStderr,
    state: Arc<StdMutex<ProcessState>>,
    mut stop: mpsc::Receiver<StopReason>,
    timeout: Duration,
    max_pending_output_bytes: usize,
) {
    let stdout_reader = spawn_reader(
        stdout,
        OutputStream::Stdout,
        Arc::clone(&state),
        max_pending_output_bytes,
    );
    let stderr_reader = spawn_reader(
        stderr,
        OutputStream::Stderr,
        Arc::clone(&state),
        max_pending_output_bytes,
    );

    let outcome = if timeout.is_zero() {
        tokio::select! {
            biased;
            status = child.wait() => SupervisorOutcome::Exited(status),
            reason = stop.recv() => SupervisorOutcome::Stopped(reason.unwrap_or(StopReason::Stopped)),
        }
    } else {
        tokio::select! {
            biased;
            status = child.wait() => SupervisorOutcome::Exited(status),
            reason = stop.recv() => SupervisorOutcome::Stopped(reason.unwrap_or(StopReason::Stopped)),
            _ = tokio::time::sleep(timeout) => SupervisorOutcome::Stopped(StopReason::TimedOut),
        }
    };

    let status = match outcome {
        SupervisorOutcome::Exited(Ok(status)) => ProcessStatus::Exited {
            code: status.code(),
        },
        SupervisorOutcome::Exited(Err(_)) => ProcessStatus::Exited { code: None },
        SupervisorOutcome::Stopped(reason) => {
            terminate_process_group(&mut child).await;
            match reason {
                StopReason::TimedOut => ProcessStatus::TimedOut,
                StopReason::Stopped => ProcessStatus::Stopped,
            }
        }
    };

    finish_reader(stdout_reader).await;
    finish_reader(stderr_reader).await;
    state.lock().expect("process state lock poisoned").status = status;
}

enum SupervisorOutcome {
    Exited(Result<std::process::ExitStatus, std::io::Error>),
    Stopped(StopReason),
}

async fn terminate_process_group(child: &mut Child) {
    let Some(id) = child.id() else {
        return;
    };
    let group = Pid::from_raw(id as i32);
    let _ = signal::killpg(group, Signal::SIGTERM);
    if tokio::time::timeout(Duration::from_millis(100), child.wait())
        .await
        .is_err()
    {
        let _ = signal::killpg(group, Signal::SIGKILL);
        let _ = child.wait().await;
    }
}

async fn finish_reader(mut reader: tokio::task::JoinHandle<()>) {
    if tokio::time::timeout(Duration::from_millis(25), &mut reader)
        .await
        .is_err()
    {
        reader.abort();
        let _ = reader.await;
    }
}

async fn wait_until_terminal(
    manager: &ProcessManager,
    process_id: Uuid,
    after_sequence: u64,
) -> Result<ProcessPoll, ProcessError> {
    loop {
        let poll = manager.poll(process_id, after_sequence).await?;
        if poll.status != ProcessStatus::Running {
            return Ok(poll);
        }
        tokio::task::yield_now().await;
    }
}

fn spawn_reader(
    mut reader: impl AsyncRead + Unpin + Send + 'static,
    stream: OutputStream,
    state: Arc<StdMutex<ProcessState>>,
    max_pending_output_bytes: usize,
) -> tokio::task::JoinHandle<()> {
    tokio::spawn(async move {
        let mut bytes = vec![0; 8 * 1024];
        loop {
            let read = match reader.read(&mut bytes).await {
                Ok(0) | Err(_) => return,
                Ok(read) => read,
            };
            let content = String::from_utf8_lossy(&bytes[..read]).into_owned();
            let mut state = state.lock().expect("process state lock poisoned");
            let output = &mut state.output;
            let (content, truncated) = truncate_utf8(content, max_pending_output_bytes);
            if !content.is_empty() {
                while output.bytes + content.len() > max_pending_output_bytes {
                    let Some(removed) = output.chunks.pop_front() else {
                        break;
                    };
                    output.bytes -= removed.content.len();
                }
                output.bytes += content.len();
                output.chunks.push_back(CommandOutput {
                    sequence: output.next_sequence,
                    stream,
                    content,
                    truncated,
                });
                output.next_sequence += 1;
            }
        }
    })
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
    use tempfile::TempDir;

    use super::*;

    #[tokio::test]
    async fn streams_output_and_reports_exit_status() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start(
                "printf stdout; printf stderr >&2; exit 7",
                directory.path(),
                Duration::from_secs(5),
            )
            .await
            .unwrap();

        let poll = poll_until_finished(&manager, process_id).await;
        let output: String = poll.output.into_iter().map(|chunk| chunk.content).collect();
        assert_eq!(poll.status, ProcessStatus::Exited { code: Some(7) });
        assert!(output.contains("stdout"));
        assert!(output.contains("stderr"));
    }

    #[tokio::test]
    async fn bounds_unpolled_output() {
        let manager = ProcessManager::new(5);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("printf 123456789", directory.path(), Duration::from_secs(5))
            .await
            .unwrap();

        let poll = poll_until_finished(&manager, process_id).await;
        let output: String = poll.output.into_iter().map(|chunk| chunk.content).collect();
        assert_eq!(output, "12345");
        assert!(poll.truncated);
    }

    #[tokio::test]
    async fn stops_a_running_process() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("while true; do :; done", directory.path(), Duration::ZERO)
            .await
            .unwrap();

        let poll = manager.stop(process_id, 0).await.unwrap();

        assert_eq!(poll.status, ProcessStatus::Stopped);
    }

    #[tokio::test]
    async fn times_out_a_running_process() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start(
                "while true; do :; done",
                directory.path(),
                Duration::from_millis(10),
            )
            .await
            .unwrap();

        let poll = poll_until_finished(&manager, process_id).await;

        assert_eq!(poll.status, ProcessStatus::TimedOut);
    }

    #[tokio::test]
    async fn does_not_timeout_a_process_that_exited_before_its_deadline() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("exit 0", directory.path(), Duration::from_millis(20))
            .await
            .unwrap();

        tokio::time::sleep(Duration::from_millis(50)).await;
        let poll = manager.poll(process_id, 0).await.unwrap();

        assert_eq!(poll.status, ProcessStatus::Exited { code: Some(0) });
    }

    #[tokio::test]
    async fn terminal_poll_does_not_wait_for_a_background_descendants_pipes() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("sleep 1 &", directory.path(), Duration::ZERO)
            .await
            .unwrap();

        tokio::time::timeout(Duration::from_millis(200), async {
            loop {
                let poll = manager.poll(process_id, 0).await.unwrap();
                if poll.status != ProcessStatus::Running {
                    assert_eq!(poll.status, ProcessStatus::Exited { code: Some(0) });
                    break;
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("terminal poll waited for a background descendant");
    }

    #[tokio::test]
    async fn stopping_a_command_terminates_its_descendants() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("sleep 30 & echo $!; wait", directory.path(), Duration::ZERO)
            .await
            .unwrap();
        let descendant = tokio::time::timeout(Duration::from_secs(1), async {
            loop {
                let poll = manager.poll(process_id, 0).await.unwrap();
                let output: String = poll.output.into_iter().map(|chunk| chunk.content).collect();
                if let Ok(pid) = output.trim().parse::<i32>() {
                    return Pid::from_raw(pid);
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("command did not report its descendant process");

        let poll = manager.stop(process_id, 0).await.unwrap();

        assert_eq!(poll.status, ProcessStatus::Stopped);
        tokio::time::timeout(Duration::from_secs(1), async {
            while signal::kill(descendant, None).is_ok() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("descendant process survived cancellation");
    }

    #[tokio::test]
    async fn repeated_poll_replays_process_output() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("printf replay-me", directory.path(), Duration::ZERO)
            .await
            .unwrap();
        let first = poll_until_finished(&manager, process_id).await;

        let replay = manager.poll(process_id, 0).await.unwrap();

        assert_eq!(replay.output, first.output);
    }

    async fn poll_until_finished(manager: &ProcessManager, process_id: Uuid) -> ProcessPoll {
        tokio::time::timeout(Duration::from_secs(2), async {
            let mut output = Vec::new();
            let mut truncated = false;
            let mut after_sequence = 0;
            loop {
                let mut poll = manager.poll(process_id, after_sequence).await.unwrap();
                output.append(&mut poll.output);
                truncated |= poll.truncated;
                after_sequence = poll.next_sequence.saturating_sub(1);
                if poll.status != ProcessStatus::Running {
                    return ProcessPoll {
                        status: poll.status,
                        output,
                        earliest_sequence: poll.earliest_sequence,
                        next_sequence: poll.next_sequence,
                        truncated,
                    };
                }
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("process did not finish")
    }
}
