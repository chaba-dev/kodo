//! Workspace discovery and the filesystem security boundary for runner tools.
//!
//! File and patch paths are always relative to one canonical Git root. Direct reads use a retained
//! directory capability; paths passed to external programs are validated here first.

use std::fs::{File, OpenOptions};
use std::path::{Component, Path, PathBuf};
use std::process::Command;
use std::sync::Arc;
use std::{io::ErrorKind, io::Read, io::Seek, io::SeekFrom, io::Write};

use cap_std::ambient_authority;
use cap_std::fs::{Dir, OpenOptions as CapOpenOptions};
use sha2::{Digest, Sha256};
use thiserror::Error;

#[derive(Debug, Error)]
pub enum WorkspaceError {
    #[error("{path} is not inside a Git repository")]
    NotARepository { path: PathBuf },
    #[error("workspace path must be relative: {0}")]
    AbsolutePath(PathBuf),
    #[error("workspace path cannot contain parent-directory components: {0}")]
    ParentTraversal(PathBuf),
    #[error("path escapes the workspace: {0}")]
    OutsideWorkspace(PathBuf),
    #[error("path has no existing ancestor: {0}")]
    NoExistingAncestor(PathBuf),
    #[error("file exceeds {limit} byte input limit: {path}")]
    FileTooLarge { path: PathBuf, limit: usize },
    #[error("another Kodo runner is already active for workspace: {0}")]
    RunnerAlreadyActive(PathBuf),
    #[error("failed to access {path}: {source}")]
    Io {
        path: PathBuf,
        #[source]
        source: std::io::Error,
    },
}

/// A canonical Git worktree root and capability for validating model-supplied file paths.
#[derive(Clone, Debug)]
pub struct Workspace {
    root: PathBuf,
    root_dir: Arc<Dir>,
}

pub struct RunnerLock {
    _file: File,
}

impl Workspace {
    pub fn discover(start: impl AsRef<Path>) -> Result<Self, WorkspaceError> {
        let start = canonicalize(start.as_ref())?;
        let mut command = Command::new("git");
        command
            .args([
                "-c",
                "core.fsmonitor=false",
                "-c",
                "core.hooksPath=/dev/null",
                "-C",
            ])
            .arg(&start)
            .args(["rev-parse", "--show-toplevel"])
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
        let output = command.output().map_err(|source| WorkspaceError::Io {
            path: start.clone(),
            source,
        })?;

        if !output.status.success() {
            return Err(WorkspaceError::NotARepository { path: start });
        }

        let reported_root = PathBuf::from(String::from_utf8_lossy(&output.stdout).trim());
        Self::from_root(reported_root)
    }

    pub fn from_root(root: impl AsRef<Path>) -> Result<Self, WorkspaceError> {
        let root = canonicalize(root.as_ref())?;
        // Ambient authority is used once, at registration, then narrowed to this directory handle.
        let root_dir = Dir::open_ambient_dir(&root, ambient_authority()).map_err(|source| {
            WorkspaceError::Io {
                path: root.clone(),
                source,
            }
        })?;
        Ok(Self {
            root,
            root_dir: Arc::new(root_dir),
        })
    }

    pub fn root(&self) -> &Path {
        &self.root
    }

    /// Exclusively owns this workspace for one runner process lifetime.
    pub fn lock_runner(&self) -> Result<RunnerLock, WorkspaceError> {
        let lock_dir = std::env::temp_dir().join("kodo-workspace-locks");
        std::fs::create_dir_all(&lock_dir).map_err(|source| WorkspaceError::Io {
            path: lock_dir.clone(),
            source,
        })?;
        let digest = Sha256::digest(self.root.as_os_str().as_encoded_bytes());
        let lock_path = lock_dir.join(format!("{digest:x}.lock"));
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .truncate(false)
            .open(&lock_path)
            .map_err(|source| WorkspaceError::Io {
                path: lock_path.clone(),
                source,
            })?;

        if let Err(source) = fs2::FileExt::try_lock_exclusive(&file) {
            if source.kind() == ErrorKind::WouldBlock {
                return Err(WorkspaceError::RunnerAlreadyActive(self.root.clone()));
            }
            return Err(WorkspaceError::Io {
                path: lock_path,
                source,
            });
        }

        Ok(RunnerLock { _file: file })
    }

    /// Read through the retained root capability so concurrent symlink changes cannot escape it.
    pub fn read_to_string(&self, path: impl AsRef<Path>) -> Result<String, WorkspaceError> {
        let path = validate_relative(path.as_ref())?;
        self.root_dir
            .read_to_string(path)
            .map_err(|source| WorkspaceError::Io {
                path: self.root.join(path),
                source,
            })
    }

    /// Read at most `limit` bytes through the workspace capability.
    pub fn read_to_string_bounded(
        &self,
        path: impl AsRef<Path>,
        limit: usize,
    ) -> Result<String, WorkspaceError> {
        let path = validate_relative(path.as_ref())?;
        let display_path = self.root.join(path);
        let file = self
            .root_dir
            .open(path)
            .map_err(|source| WorkspaceError::Io {
                path: display_path.clone(),
                source,
            })?;
        let mut bytes = Vec::with_capacity(limit.min(8 * 1024));
        file.take(limit.saturating_add(1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|source| WorkspaceError::Io {
                path: display_path.clone(),
                source,
            })?;
        if bytes.len() > limit {
            return Err(WorkspaceError::FileTooLarge {
                path: display_path,
                limit,
            });
        }
        String::from_utf8(bytes).map_err(|source| WorkspaceError::Io {
            path: display_path,
            source: std::io::Error::new(ErrorKind::InvalidData, source),
        })
    }

    /// Replace one exact text occurrence through the retained directory capability.
    pub fn replace_text_if_unique(
        &self,
        path: impl AsRef<Path>,
        old_text: &str,
        new_text: &str,
        limit: usize,
    ) -> Result<bool, WorkspaceError> {
        let path = validate_relative(path.as_ref())?;
        let display_path = self.root.join(path);
        let mut options = CapOpenOptions::new();
        options.read(true).write(true);
        let mut file =
            self.root_dir
                .open_with(path, &options)
                .map_err(|source| WorkspaceError::Io {
                    path: display_path.clone(),
                    source,
                })?;
        let mut bytes = Vec::with_capacity(limit.min(8 * 1024));
        std::io::Read::by_ref(&mut file)
            .take(limit.saturating_add(1) as u64)
            .read_to_end(&mut bytes)
            .map_err(|source| WorkspaceError::Io {
                path: display_path.clone(),
                source,
            })?;
        if bytes.len() > limit {
            return Err(WorkspaceError::FileTooLarge {
                path: display_path,
                limit,
            });
        }
        let content = String::from_utf8(bytes).map_err(|source| WorkspaceError::Io {
            path: display_path.clone(),
            source: std::io::Error::new(ErrorKind::InvalidData, source),
        })?;
        if content.match_indices(old_text).take(2).count() != 1 {
            return Ok(false);
        }
        let replacement = content.replacen(old_text, new_text, 1);
        if replacement.len() > limit {
            return Err(WorkspaceError::FileTooLarge {
                path: display_path,
                limit,
            });
        }
        file.seek(SeekFrom::Start(0))
            .and_then(|_| file.set_len(0))
            .and_then(|_| file.write_all(replacement.as_bytes()))
            .map_err(|source| WorkspaceError::Io {
                path: display_path,
                source,
            })?;
        Ok(true)
    }

    pub fn is_file(&self, path: impl AsRef<Path>) -> Result<bool, WorkspaceError> {
        let path = validate_relative(path.as_ref())?;
        self.root_dir
            .metadata(path)
            .map(|metadata| metadata.is_file())
            .map_err(|source| WorkspaceError::Io {
                path: self.root.join(path),
                source,
            })
    }

    /// Resolve an existing workspace-relative path and reject symlinks that escape the root.
    pub fn resolve(&self, path: impl AsRef<Path>) -> Result<PathBuf, WorkspaceError> {
        let path = validate_relative(path.as_ref())?;
        let resolved = canonicalize(&self.root.join(path))?;
        self.ensure_confined(resolved)
    }

    /// Resolve a path that may not exist by validating its nearest existing ancestor.
    ///
    /// This permits patch-created files while still rejecting an existing symlinked ancestor that
    /// points outside the workspace.
    pub fn resolve_new(&self, path: impl AsRef<Path>) -> Result<PathBuf, WorkspaceError> {
        let path = validate_relative(path.as_ref())?;
        let candidate = self.root.join(path);
        let mut ancestor = candidate.as_path();

        while !ancestor.exists() {
            ancestor = ancestor
                .parent()
                .ok_or_else(|| WorkspaceError::NoExistingAncestor(candidate.clone()))?;
        }

        let canonical_ancestor = canonicalize(ancestor)?;
        self.ensure_confined(canonical_ancestor)?;
        Ok(candidate)
    }

    fn ensure_confined(&self, path: PathBuf) -> Result<PathBuf, WorkspaceError> {
        if path.starts_with(&self.root) {
            Ok(path)
        } else {
            Err(WorkspaceError::OutsideWorkspace(path))
        }
    }
}

fn validate_relative(path: &Path) -> Result<&Path, WorkspaceError> {
    if path.is_absolute() {
        return Err(WorkspaceError::AbsolutePath(path.to_path_buf()));
    }

    if path.components().any(|component| {
        matches!(
            component,
            Component::ParentDir | Component::RootDir | Component::Prefix(_)
        )
    }) {
        return Err(WorkspaceError::ParentTraversal(path.to_path_buf()));
    }

    Ok(path)
}

fn canonicalize(path: &Path) -> Result<PathBuf, WorkspaceError> {
    path.canonicalize().map_err(|source| WorkspaceError::Io {
        path: path.to_path_buf(),
        source,
    })
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::io::{Read, Seek, SeekFrom};

    use tempfile::TempDir;

    use super::*;

    #[test]
    fn discovers_git_root_from_nested_directory() {
        let repository = git_repository();
        let nested = repository.path().join("one/two");
        fs::create_dir_all(&nested).unwrap();

        let workspace = Workspace::discover(&nested).unwrap();

        assert_eq!(workspace.root(), repository.path().canonicalize().unwrap());
    }

    #[test]
    fn permits_only_one_runner_for_a_workspace() {
        let repository = git_repository();
        let workspace = Workspace::from_root(repository.path()).unwrap();
        let first = workspace.lock_runner().unwrap();

        assert!(matches!(
            workspace.lock_runner(),
            Err(WorkspaceError::RunnerAlreadyActive(path)) if path == workspace.root()
        ));

        drop(first);
        workspace.lock_runner().unwrap();
    }

    #[test]
    fn rejects_parent_traversal_and_absolute_paths() {
        let repository = git_repository();
        let workspace = Workspace::from_root(repository.path()).unwrap();

        assert!(matches!(
            workspace.resolve("../outside"),
            Err(WorkspaceError::ParentTraversal(_))
        ));
        assert!(matches!(
            workspace.resolve(repository.path()),
            Err(WorkspaceError::AbsolutePath(_))
        ));
    }

    #[cfg(unix)]
    #[test]
    fn rejects_symlinks_that_escape_the_workspace() {
        use std::os::unix::fs::symlink;

        let repository = git_repository();
        let outside = TempDir::new().unwrap();
        fs::write(outside.path().join("secret.txt"), "secret").unwrap();
        symlink(outside.path(), repository.path().join("escape")).unwrap();
        let workspace = Workspace::from_root(repository.path()).unwrap();

        assert!(matches!(
            workspace.resolve("escape"),
            Err(WorkspaceError::OutsideWorkspace(_))
        ));
        assert!(matches!(
            workspace.resolve_new("escape/new-file"),
            Err(WorkspaceError::OutsideWorkspace(_))
        ));
        assert!(workspace.read_to_string("escape/secret.txt").is_err());
    }

    #[test]
    fn resolves_new_paths_beneath_existing_workspace_directories() {
        let repository = git_repository();
        fs::create_dir(repository.path().join("src")).unwrap();
        let workspace = Workspace::from_root(repository.path()).unwrap();

        assert_eq!(
            workspace.resolve_new("src/new/module.rs").unwrap(),
            repository
                .path()
                .canonicalize()
                .unwrap()
                .join("src/new/module.rs")
        );
    }

    #[test]
    fn bounded_reads_reject_oversized_files() {
        let repository = git_repository();
        fs::write(repository.path().join("large.txt"), "12345").unwrap();
        let workspace = Workspace::from_root(repository.path()).unwrap();

        assert!(matches!(
            workspace.read_to_string_bounded("large.txt", 4),
            Err(WorkspaceError::FileTooLarge { limit: 4, .. })
        ));
    }

    #[test]
    fn replace_text_atomically_swaps_the_file() {
        let repository = git_repository();
        let path = repository.path().join("message.txt");
        fs::write(&path, "before value").unwrap();
        let mut original_file = fs::File::open(&path).unwrap();
        let workspace = Workspace::from_root(repository.path()).unwrap();

        assert!(
            workspace
                .replace_text_if_unique("message.txt", "before", "after", 1024)
                .unwrap()
        );
        assert_eq!(fs::read_to_string(&path).unwrap(), "after value");

        original_file.seek(SeekFrom::Start(0)).unwrap();
        let mut original_content = String::new();
        original_file.read_to_string(&mut original_content).unwrap();
        assert_eq!(original_content, "before value");
    }

    fn git_repository() -> TempDir {
        let directory = TempDir::new().unwrap();
        let status = Command::new("git")
            .args(["init", "--quiet"])
            .current_dir(directory.path())
            .status()
            .unwrap();
        assert!(status.success());
        directory
    }
}
