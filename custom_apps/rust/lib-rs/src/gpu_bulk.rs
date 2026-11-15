//! A coarse advisory lease shared by bulk GPU jobs.
//!
//! Bonsai's photo-tag review and Search's passage backfill both run for hours
//! on the one Arc card. Letting either run unthrottled starves the other;
//! yielding to every GPU request starves the backfill while the tag reviewer
//! is busy. This lease gives each job a long turn instead: the holder keeps
//! the GPU for [`SLICE`], then drops the lock and waits [`HANDOFF`] before
//! trying again, so the other job can take over. The slices are deliberately
//! long; switching on every request would cost more than it saves.
//!
//! The lock file is created by tmpfiles with mode 0644. `flock(2)` does not
//! require write access, so both service users open it read-only and no
//! shared group or writable directory is needed. The lease is advisory: if
//! the file is missing or unreadable a job proceeds uncoordinated rather
//! than stopping.
use std::fs::File;
use std::io;
use std::os::fd::AsRawFd;
use std::path::{Path, PathBuf};
use std::time::Duration;

/// Created by the search tmpfiles rule. Jobs that cannot open it still run.
pub const LEASE_PATH: &str = "/run/ai-gpu-bulk.lease";

/// How long one bulk job keeps the GPU before handing it over.
pub const SLICE: Duration = Duration::from_secs(30);

/// How long a waiting job sleeps before trying the lease again.
pub const POLL: Duration = Duration::from_secs(3);

/// Pause after a productive slice so the other job can acquire the lease.
pub const HANDOFF: Duration = Duration::from_secs(3);

/// Result of one non-blocking lease attempt.
#[derive(Debug)]
pub enum LeaseAttempt {
    Acquired(GpuBulkLease),
    /// Another bulk job holds the lease.
    Busy,
    /// The lease file is absent or cannot be opened; run uncoordinated.
    Unavailable(io::Error),
}

/// Exclusive, non-blocking bulk-GPU lease. Released on drop.
#[derive(Debug)]
pub struct GpuBulkLease {
    file: File,
    path: PathBuf,
}

impl GpuBulkLease {
    /// Try the default lease path.
    pub fn try_acquire() -> LeaseAttempt {
        Self::try_acquire_at(Path::new(LEASE_PATH))
    }

    /// Try a specific lease path. Useful for tests and alternate deployments.
    pub fn try_acquire_at(path: &Path) -> LeaseAttempt {
        let file = match File::open(path) {
            Ok(file) => file,
            Err(error) => return LeaseAttempt::Unavailable(error),
        };
        // SAFETY: `file` owns a valid descriptor for the duration of the call.
        let rc = unsafe { libc::flock(file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) };
        if rc == 0 {
            return LeaseAttempt::Acquired(Self {
                file,
                path: path.to_path_buf(),
            });
        }
        let error = io::Error::last_os_error();
        if error.raw_os_error() == Some(libc::EWOULDBLOCK) {
            LeaseAttempt::Busy
        } else {
            LeaseAttempt::Unavailable(error)
        }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }
}

impl Drop for GpuBulkLease {
    fn drop(&mut self) {
        // SAFETY: the descriptor is still open here.
        unsafe {
            libc::flock(self.file.as_raw_fd(), libc::LOCK_UN);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn lease_file(name: &str) -> PathBuf {
        let path =
            std::env::temp_dir().join(format!("ai-gpu-bulk-{}-{name}.lease", std::process::id()));
        let mut file = File::create(&path).expect("create lease file");
        file.write_all(b"").expect("write lease file");
        path
    }

    #[test]
    fn a_second_acquire_reports_busy_until_the_first_drops() {
        let path = lease_file("exclusive");
        let first = match GpuBulkLease::try_acquire_at(&path) {
            LeaseAttempt::Acquired(lease) => lease,
            other => panic!("first acquire failed: {other:?}"),
        };
        match GpuBulkLease::try_acquire_at(&path) {
            LeaseAttempt::Busy => {}
            other => panic!("second acquire should be busy: {other:?}"),
        }
        drop(first);
        match GpuBulkLease::try_acquire_at(&path) {
            LeaseAttempt::Acquired(_) => {}
            other => panic!("acquire after release failed: {other:?}"),
        }
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_missing_file_is_unavailable_rather_than_busy() {
        let path = std::env::temp_dir().join("ai-gpu-bulk-does-not-exist.lease");
        let _ = std::fs::remove_file(&path);
        match GpuBulkLease::try_acquire_at(&path) {
            LeaseAttempt::Unavailable(_) => {}
            other => panic!("missing file should be unavailable: {other:?}"),
        }
    }
}
