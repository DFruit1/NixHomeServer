//! Directory-descriptor operations keep user-controlled symlinks out of the
//! privileged worker's reads and writes, including across concurrent renames.
use std::{
    ffi::CString,
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::{
        fd::{AsRawFd, FromRawFd},
        unix::fs::{MetadataExt, OpenOptionsExt},
    },
    path::Path,
};

pub struct Dir(pub File);
fn name(value: &str) -> Result<CString, String> {
    if value.is_empty() || value == "." || value == ".." || value.contains('/') || value.len() > 240
    {
        return Err("invalid path component".into());
    }
    CString::new(value).map_err(|_| "invalid path component".into())
}
impl Dir {
    pub fn allow_media_read(&self) -> Result<(), String> {
        let Some(setfacl) = std::env::var_os("TRANSCRIBE_SETFACL") else {
            return Ok(());
        };
        let path = format!("/proc/{}/fd/{}", std::process::id(), self.0.as_raw_fd());
        let status = std::process::Command::new(setfacl)
            .args(["-m", "g:media-manager:r-x,d:g:media-manager:r-x"])
            .arg(path)
            .status()
            .map_err(|_| "ACL setup failed")?;
        if !status.success() {
            return Err("ACL setup failed".into());
        }
        Ok(())
    }
    pub fn open(path: &Path) -> Result<Self, String> {
        OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map(Self)
            .map_err(|e| e.to_string())
    }
    pub fn child(&self, value: &str) -> Result<Self, String> {
        let value = name(value)?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                value.as_ptr(),
                libc::O_RDONLY | libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        Ok(Self(unsafe { File::from_raw_fd(fd) }))
    }
    pub fn create(&self, value: &str) -> Result<Self, String> {
        self.create_mode(value, 0o750)
    }
    /// Web and filesystem broker share only the intake spool, not user roots.
    pub fn create_shared(&self, value: &str) -> Result<Self, String> {
        self.create_mode(value, 0o2770)
    }
    fn create_mode(&self, value: &str, mode: libc::mode_t) -> Result<Self, String> {
        let component = name(value)?;
        let created = unsafe { libc::mkdirat(self.0.as_raw_fd(), component.as_ptr(), mode) } == 0;
        if !created && std::io::Error::last_os_error().raw_os_error() != Some(libc::EEXIST) {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let dir = self.child(value)?;
        if created {
            self.own(&dir.0)?;
        }
        Ok(dir)
    }
    fn own(&self, file: &File) -> Result<(), String> {
        let metadata = self.0.metadata().map_err(|e| e.to_string())?;
        // A non-root provisioning broker already inherits the correct group.
        if unsafe { libc::geteuid() } == 0
            && unsafe { libc::fchown(file.as_raw_fd(), metadata.uid(), metadata.gid()) } != 0
        {
            return Err(std::io::Error::last_os_error().to_string());
        }
        Ok(())
    }
    pub fn file(&self, value: &str) -> Result<File, String> {
        let component = name(value)?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                component.as_ptr(),
                libc::O_RDONLY | libc::O_NOFOLLOW | libc::O_NONBLOCK | libc::O_CLOEXEC,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let file = unsafe { File::from_raw_fd(fd) };
        if !file.metadata().map_err(|e| e.to_string())?.is_file() {
            return Err("not a regular file".into());
        }
        Ok(file)
    }
    pub fn read(&self, value: &str, limit: u64) -> Result<Vec<u8>, String> {
        let mut bytes = Vec::new();
        self.file(value)?
            .take(limit + 1)
            .read_to_end(&mut bytes)
            .map_err(|e| e.to_string())?;
        if bytes.len() as u64 > limit {
            return Err("file exceeds size limit".into());
        }
        Ok(bytes)
    }
    pub fn write(&self, value: &str, bytes: &[u8]) -> Result<(), String> {
        let target = name(value)?;
        let temporary = name(&format!(".transcribe-{}", homelab_common::random_hex(16)))?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o640,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        let result = (|| {
            self.own(&file)?;
            file.write_all(bytes)
                .and_then(|_| file.sync_all())
                .map_err(|e| e.to_string())?;
            if unsafe {
                libc::renameat(
                    self.0.as_raw_fd(),
                    temporary.as_ptr(),
                    self.0.as_raw_fd(),
                    target.as_ptr(),
                )
            } != 0
            {
                return Err(std::io::Error::last_os_error().to_string());
            }
            self.0.sync_all().map_err(|e| e.to_string())
        })();
        if result.is_err() {
            unsafe {
                libc::unlinkat(self.0.as_raw_fd(), temporary.as_ptr(), 0);
            }
        }
        result
    }
    /// Stream a large media file, then publish without replacing any entry.
    pub fn copy_new(&self, value: &str, mut source: File) -> Result<(), String> {
        let before = source.metadata().map_err(|e| e.to_string())?;
        let target = name(value)?;
        let temporary = name(&format!(".media-copy-{}", homelab_common::random_hex(16)))?;
        let fd = unsafe {
            libc::openat(
                self.0.as_raw_fd(),
                temporary.as_ptr(),
                libc::O_WRONLY | libc::O_CREAT | libc::O_EXCL | libc::O_NOFOLLOW | libc::O_CLOEXEC,
                0o660,
            )
        };
        if fd < 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let mut file = unsafe { File::from_raw_fd(fd) };
        let result = (|| {
            self.own(&file)?;
            let copied = std::io::copy(&mut (&mut source).take(before.len() + 1), &mut file)
                .map_err(|e| e.to_string())?;
            let after = source.metadata().map_err(|e| e.to_string())?;
            if copied != before.len()
                || before.len() != after.len()
                || before.mtime() != after.mtime()
                || before.mtime_nsec() != after.mtime_nsec()
            {
                return Err("The source changed while it was being copied.".into());
            }
            file.sync_all().map_err(|e| e.to_string())?;
            if unsafe {
                libc::linkat(
                    self.0.as_raw_fd(),
                    temporary.as_ptr(),
                    self.0.as_raw_fd(),
                    target.as_ptr(),
                    0,
                )
            } != 0
            {
                return Err(format!(
                    "Cannot save {}: {} (existing files are never replaced)",
                    value,
                    std::io::Error::last_os_error()
                ));
            }
            self.0.sync_all().map_err(|e| e.to_string())
        })();
        unsafe {
            libc::unlinkat(self.0.as_raw_fd(), temporary.as_ptr(), 0);
        }
        result
    }
    pub fn remove(&self, value: &str) -> Result<(), String> {
        let value = name(value)?;
        if unsafe { libc::unlinkat(self.0.as_raw_fd(), value.as_ptr(), 0) } != 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        Ok(())
    }
    pub fn names(&self) -> Result<Vec<String>, String> {
        let mut entries = Vec::new();
        for entry in std::fs::read_dir(format!("/proc/self/fd/{}", self.0.as_raw_fd()))
            .map_err(|e| e.to_string())?
        {
            if entries.len() >= 10000 {
                return Err("inbox entry limit exceeded".into());
            }
            let entry = entry.map_err(|e| e.to_string())?;
            if let Some(value) = entry.file_name().to_str().filter(|v| name(v).is_ok()) {
                entries.push(value.to_string());
            }
        }
        entries.sort();
        Ok(entries)
    }
}
