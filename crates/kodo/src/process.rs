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

const MAX_RETAINED_PROCESSES: usize = 1024;
const MAX_OUTPUT_CHUNKS: usize = 1024;
const PROCESS_RETENTION: Duration = Duration::from_secs(5 * 60);

#[derive(Debug, Error)]
pub enum ProcessError {
    #[error("failed to start command: {0}")]
    Start(#[source] std::io::Error),
    #[error("unknown process: {0}")]
    Unknown(Uuid),
    #[error("process supervisor for {0} stopped unexpectedly")]
    SupervisorStopped(Uuid),
    #[error("runner already retains the maximum of {MAX_RETAINED_PROCESSES} processes")]
    Capacity,
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
    terminal_truncated: bool,
}

impl Default for OutputBuffer {
    fn default() -> Self {
        Self {
            chunks: VecDeque::new(),
            bytes: 0,
            next_sequence: 1,
            terminal_truncated: false,
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
        let mut entries = self.entries.lock().await;
        if entries.len() >= MAX_RETAINED_PROCESSES {
            return Err(ProcessError::Capacity);
        }
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

        entries.insert(
            process_id,
            ProcessEntry {
                state: Arc::clone(&state),
                stop,
            },
        );
        drop(entries);
        tokio::spawn(supervise(Supervisor {
            child,
            stdout,
            stderr,
            state,
            stop: stop_receiver,
            timeout,
            max_pending_output_bytes: self.max_pending_output_bytes,
            process_id,
            entries: Arc::clone(&self.entries),
        }));

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
        let truncated = state.output.terminal_truncated
            || after_sequence.saturating_add(1) < earliest_sequence
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

        if running {
            match stop.try_send(StopReason::Stopped) {
                Ok(()) | Err(mpsc::error::TrySendError::Full(_)) => {}
                Err(mpsc::error::TrySendError::Closed(_)) => {
                    tokio::task::yield_now().await;
                }
            }
        }
        wait_until_terminal(self, process_id, after_sequence).await
    }
}

struct Supervisor {
    child: Child,
    stdout: ChildStdout,
    stderr: ChildStderr,
    state: Arc<StdMutex<ProcessState>>,
    stop: mpsc::Receiver<StopReason>,
    timeout: Duration,
    max_pending_output_bytes: usize,
    process_id: Uuid,
    entries: Arc<Mutex<HashMap<Uuid, ProcessEntry>>>,
}

async fn supervise(supervisor: Supervisor) {
    let Supervisor {
        mut child,
        stdout,
        stderr,
        state,
        mut stop,
        timeout,
        max_pending_output_bytes,
        process_id,
        entries,
    } = supervisor;
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
    let process_group = child.id().map(|id| Pid::from_raw(id as i32));

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
        SupervisorOutcome::Exited(Ok(status)) => {
            cleanup_process_group(process_group).await;
            ProcessStatus::Exited {
                code: status.code(),
            }
        }
        SupervisorOutcome::Exited(Err(_)) => {
            cleanup_process_group(process_group).await;
            ProcessStatus::Exited { code: None }
        }
        SupervisorOutcome::Stopped(reason) => {
            terminate_process_group(&mut child, process_group).await;
            match reason {
                StopReason::TimedOut => ProcessStatus::TimedOut,
                StopReason::Stopped => ProcessStatus::Stopped,
            }
        }
    };

    let output_truncated = finish_reader(stdout_reader).await | finish_reader(stderr_reader).await;
    {
        let mut state = state.lock().expect("process state lock poisoned");
        state.output.terminal_truncated |= output_truncated;
        state.status = status;
    }
    tokio::time::sleep(PROCESS_RETENTION).await;
    entries.lock().await.remove(&process_id);
}

enum SupervisorOutcome {
    Exited(Result<std::process::ExitStatus, std::io::Error>),
    Stopped(StopReason),
}

async fn terminate_process_group(child: &mut Child, process_group: Option<Pid>) {
    let Some(group) = process_group else {
        let _ = child.wait().await;
        return;
    };
    let _ = signal::killpg(group, Signal::SIGTERM);
    let waited = tokio::time::timeout(Duration::from_millis(100), child.wait()).await;
    let _ = signal::killpg(group, Signal::SIGKILL);
    if waited.is_err() {
        let _ = child.wait().await;
    }
}

async fn cleanup_process_group(process_group: Option<Pid>) {
    let Some(group) = process_group else {
        return;
    };
    let _ = signal::killpg(group, Signal::SIGTERM);
    tokio::time::sleep(Duration::from_millis(100)).await;
    let _ = signal::killpg(group, Signal::SIGKILL);
}

async fn finish_reader(mut reader: tokio::task::JoinHandle<()>) -> bool {
    if tokio::time::timeout(Duration::from_millis(25), &mut reader)
        .await
        .is_err()
    {
        reader.abort();
        let _ = reader.await;
        true
    } else {
        false
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
        tokio::time::sleep(Duration::from_millis(1)).await;
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
        let mut pending_utf8 = Vec::new();
        loop {
            let read = match reader.read(&mut bytes).await {
                Ok(0) | Err(_) => {
                    let content = decode_utf8(&mut pending_utf8, &[], true);
                    append_output(&state, stream, content, max_pending_output_bytes);
                    return;
                }
                Ok(read) => read,
            };
            let content = decode_utf8(&mut pending_utf8, &bytes[..read], false);
            append_output(&state, stream, content, max_pending_output_bytes);
        }
    })
}

fn append_output(
    state: &StdMutex<ProcessState>,
    stream: OutputStream,
    content: String,
    max_pending_output_bytes: usize,
) {
    let mut state = state.lock().expect("process state lock poisoned");
    let output = &mut state.output;
    let (content, truncated) = truncate_utf8(content, max_pending_output_bytes);
    if content.is_empty() {
        return;
    }
    while output.bytes + content.len() > max_pending_output_bytes
        || output.chunks.len() >= MAX_OUTPUT_CHUNKS
    {
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

fn decode_utf8(pending: &mut Vec<u8>, bytes: &[u8], end_of_stream: bool) -> String {
    pending.extend_from_slice(bytes);
    let mut decoded = String::new();
    loop {
        match std::str::from_utf8(pending) {
            Ok(content) => {
                decoded.push_str(content);
                pending.clear();
                break;
            }
            Err(error) => {
                let valid = error.valid_up_to();
                decoded.push_str(
                    std::str::from_utf8(&pending[..valid])
                        .expect("UTF-8 validator marked prefix as valid"),
                );
                match error.error_len() {
                    Some(invalid) => {
                        decoded.push('\u{FFFD}');
                        pending.drain(..valid + invalid);
                    }
                    None => {
                        pending.drain(..valid);
                        break;
                    }
                }
            }
        }
    }

    if end_of_stream && !pending.is_empty() {
        decoded.push_str(&String::from_utf8_lossy(pending));
        pending.clear();
    }
    decoded
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
    use std::pin::Pin;
    use std::task::{Context, Poll};

    use tempfile::TempDir;
    use tokio::io::ReadBuf;

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
        let poll = poll_until_finished(&manager, process_id).await;

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
    async fn stopping_escalates_for_descendants_that_ignore_sigterm() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start(
                "trap '' TERM; sleep 30 & echo $!; wait",
                directory.path(),
                Duration::ZERO,
            )
            .await
            .unwrap();
        let descendant = reported_pid(&manager, process_id).await;

        manager.stop(process_id, 0).await.unwrap();

        assert_process_exits(descendant).await;
    }

    #[tokio::test]
    async fn natural_shell_exit_cleans_up_background_descendants() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("sleep 30 & echo $!", directory.path(), Duration::ZERO)
            .await
            .unwrap();
        let descendant = reported_pid(&manager, process_id).await;

        poll_until_finished(&manager, process_id).await;

        assert_process_exits(descendant).await;
    }

    #[tokio::test]
    async fn concurrent_stop_requests_are_idempotent() {
        let manager = ProcessManager::new(1024);
        let directory = TempDir::new().unwrap();
        let process_id = manager
            .start("while true; do :; done", directory.path(), Duration::ZERO)
            .await
            .unwrap();

        let (first, second, third) = tokio::join!(
            manager.stop(process_id, 0),
            manager.stop(process_id, 0),
            manager.stop(process_id, 0)
        );

        assert_eq!(first.unwrap().status, ProcessStatus::Stopped);
        assert_eq!(second.unwrap().status, ProcessStatus::Stopped);
        assert_eq!(third.unwrap().status, ProcessStatus::Stopped);
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

    #[tokio::test]
    async fn preserves_utf8_characters_split_across_reads() {
        let state = Arc::new(StdMutex::new(ProcessState {
            output: OutputBuffer::default(),
            status: ProcessStatus::Running,
        }));
        let reader = ChunkReader::new([vec![0xE2, 0x82], vec![0xAC]]);

        spawn_reader(reader, OutputStream::Stdout, Arc::clone(&state), 1024)
            .await
            .unwrap();

        let state = state.lock().unwrap();
        let output: String = state
            .output
            .chunks
            .iter()
            .map(|chunk| chunk.content.as_str())
            .collect();
        assert_eq!(output, "€");
    }

    #[tokio::test]
    async fn bounds_process_output_chunk_metadata() {
        let state = Arc::new(StdMutex::new(ProcessState {
            output: OutputBuffer::default(),
            status: ProcessStatus::Running,
        }));
        let reader = ChunkReader::new((0..MAX_OUTPUT_CHUNKS + 10).map(|_| vec![b'x']));

        spawn_reader(
            reader,
            OutputStream::Stdout,
            Arc::clone(&state),
            1024 * 1024,
        )
        .await
        .unwrap();

        let state = state.lock().unwrap();
        assert_eq!(state.output.chunks.len(), MAX_OUTPUT_CHUNKS);
        assert!(state.output.chunks.front().unwrap().sequence > 1);
    }

    struct ChunkReader {
        chunks: VecDeque<Vec<u8>>,
    }

    impl ChunkReader {
        fn new(chunks: impl IntoIterator<Item = Vec<u8>>) -> Self {
            Self {
                chunks: chunks.into_iter().collect(),
            }
        }
    }

    impl AsyncRead for ChunkReader {
        fn poll_read(
            mut self: Pin<&mut Self>,
            _context: &mut Context<'_>,
            buffer: &mut ReadBuf<'_>,
        ) -> Poll<Result<(), std::io::Error>> {
            if let Some(chunk) = self.chunks.pop_front() {
                buffer.put_slice(&chunk);
            }
            Poll::Ready(Ok(()))
        }
    }

    async fn reported_pid(manager: &ProcessManager, process_id: Uuid) -> Pid {
        tokio::time::timeout(Duration::from_secs(1), async {
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
        .expect("command did not report its descendant process")
    }

    async fn assert_process_exits(process: Pid) {
        tokio::time::timeout(Duration::from_secs(1), async {
            while signal::kill(process, None).is_ok() {
                tokio::task::yield_now().await;
            }
        })
        .await
        .expect("descendant process survived cleanup");
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
