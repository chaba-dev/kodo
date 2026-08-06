use std::collections::{HashMap, VecDeque};
use std::path::Path;
use std::process::Stdio;
use std::sync::{Arc, Mutex as StdMutex};
use std::time::Duration;

use thiserror::Error;
use tokio::io::{AsyncRead, AsyncReadExt};
use tokio::process::{Child, Command};
use tokio::sync::Mutex;
use uuid::Uuid;

use crate::protocol::{CommandOutput, OutputStream, ProcessStatus};

#[derive(Debug, Error)]
pub enum ProcessError {
    #[error("failed to start command: {0}")]
    Start(#[source] std::io::Error),
    #[error("unknown process: {0}")]
    Unknown(Uuid),
    #[error("failed to inspect process {process_id}: {source}")]
    Inspect {
        process_id: Uuid,
        #[source]
        source: std::io::Error,
    },
    #[error("failed to stop process {process_id}: {source}")]
    Stop {
        process_id: Uuid,
        #[source]
        source: std::io::Error,
    },
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
    child: Child,
    output: Arc<StdMutex<OutputBuffer>>,
    readers: Vec<tokio::task::JoinHandle<()>>,
    status: ProcessStatus,
}

#[derive(Default)]
struct OutputBuffer {
    chunks: VecDeque<CommandOutput>,
    bytes: usize,
    truncated: bool,
}

#[derive(Debug, Eq, PartialEq)]
pub struct ProcessPoll {
    pub status: ProcessStatus,
    pub output: Vec<CommandOutput>,
    pub truncated: bool,
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
            .spawn()
            .map_err(ProcessError::Start)?;
        let process_id = Uuid::new_v4();
        let output = Arc::new(StdMutex::new(OutputBuffer::default()));

        let stdout_reader = spawn_reader(
            child.stdout.take().expect("piped stdout must be available"),
            OutputStream::Stdout,
            Arc::clone(&output),
            self.max_pending_output_bytes,
        );
        let stderr_reader = spawn_reader(
            child.stderr.take().expect("piped stderr must be available"),
            OutputStream::Stderr,
            Arc::clone(&output),
            self.max_pending_output_bytes,
        );

        self.entries.lock().await.insert(
            process_id,
            ProcessEntry {
                child,
                output,
                readers: vec![stdout_reader, stderr_reader],
                status: ProcessStatus::Running,
            },
        );

        if !timeout.is_zero() {
            self.schedule_timeout(process_id, timeout);
        }

        Ok(process_id)
    }

    pub async fn poll(&self, process_id: Uuid) -> Result<ProcessPoll, ProcessError> {
        let mut entries = self.entries.lock().await;
        let entry = entries
            .get_mut(&process_id)
            .ok_or(ProcessError::Unknown(process_id))?;

        if entry.status == ProcessStatus::Running
            && let Some(status) = entry
                .child
                .try_wait()
                .map_err(|source| ProcessError::Inspect { process_id, source })?
        {
            entry.status = ProcessStatus::Exited {
                code: status.code(),
            };
        }

        let readers = if entry.status == ProcessStatus::Running {
            Vec::new()
        } else {
            std::mem::take(&mut entry.readers)
        };
        drop(entries);

        for reader in readers {
            let _ = reader.await;
        }

        let mut entries = self.entries.lock().await;
        let entry = entries
            .get_mut(&process_id)
            .ok_or(ProcessError::Unknown(process_id))?;

        let mut buffer = entry.output.lock().expect("output buffer lock poisoned");
        let output = buffer.chunks.drain(..).collect();
        let truncated = std::mem::take(&mut buffer.truncated);
        buffer.bytes = 0;

        Ok(ProcessPoll {
            status: entry.status.clone(),
            output,
            truncated,
        })
    }

    pub async fn stop(&self, process_id: Uuid) -> Result<ProcessPoll, ProcessError> {
        let mut entries = self.entries.lock().await;
        let entry = entries
            .get_mut(&process_id)
            .ok_or(ProcessError::Unknown(process_id))?;

        if entry.status == ProcessStatus::Running {
            entry
                .child
                .start_kill()
                .map_err(|source| ProcessError::Stop { process_id, source })?;
            entry.status = ProcessStatus::Stopped;
        }
        drop(entries);
        self.poll(process_id).await
    }

    fn schedule_timeout(&self, process_id: Uuid, timeout: Duration) {
        let entries = Arc::clone(&self.entries);
        tokio::spawn(async move {
            tokio::time::sleep(timeout).await;
            let mut entries = entries.lock().await;
            let Some(entry) = entries.get_mut(&process_id) else {
                return;
            };
            if entry.status == ProcessStatus::Running {
                let _ = entry.child.start_kill();
                entry.status = ProcessStatus::TimedOut;
            }
        });
    }
}

fn spawn_reader(
    mut reader: impl AsyncRead + Unpin + Send + 'static,
    stream: OutputStream,
    output: Arc<StdMutex<OutputBuffer>>,
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
            let mut output = output.lock().expect("output buffer lock poisoned");
            let remaining = max_pending_output_bytes.saturating_sub(output.bytes);
            let (content, truncated) = truncate_utf8(content, remaining);
            output.truncated |= truncated;
            if !content.is_empty() {
                output.bytes += content.len();
                output.chunks.push_back(CommandOutput { stream, content });
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

        let poll = manager.stop(process_id).await.unwrap();

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

    async fn poll_until_finished(manager: &ProcessManager, process_id: Uuid) -> ProcessPoll {
        tokio::time::timeout(Duration::from_secs(2), async {
            let mut output = Vec::new();
            let mut truncated = false;
            loop {
                let mut poll = manager.poll(process_id).await.unwrap();
                output.append(&mut poll.output);
                truncated |= poll.truncated;
                if poll.status != ProcessStatus::Running {
                    return ProcessPoll {
                        status: poll.status,
                        output,
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
