//! Filesystem helpers: safe names, no-clobber moves and settle signatures.

use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    ffi::CString,
    fs,
    io::{self, Read},
    os::unix::{ffi::OsStrExt, fs::MetadataExt},
    path::{Path, PathBuf},
};

/// Identity of a file's current content, used to tell when an upload settled.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Signature {
    pub size: u64,
    pub mtime_ns: i64,
    pub inode: u64,
}

pub fn signature(path: &Path) -> Result<Signature> {
    let meta = fs::metadata(path).with_context(|| format!("cannot stat {}", path.display()))?;
    Ok(Signature {
        size: meta.len(),
        mtime_ns: meta
            .mtime()
            .saturating_mul(1_000_000_000)
            .saturating_add(meta.mtime_nsec()),
        inode: meta.ino(),
    })
}

/// One path component that cannot leave its parent directory or hide itself.
pub fn safe_component(value: &str, fallback: &str) -> String {
    let mut text = String::with_capacity(value.len());
    for ch in value.chars() {
        if ch.is_control() || matches!(ch, '/' | '\\' | ':' | '*' | '?' | '"' | '<' | '>' | '|') {
            text.push(' ');
        } else {
            text.push(ch);
        }
    }
    let collapsed = text.split_whitespace().collect::<Vec<_>>().join(" ");
    let trimmed = collapsed.trim_matches(['.', ' ']);
    let mut limited = String::new();
    for ch in trimmed.chars() {
        if limited.len() + ch.len_utf8() > 180 {
            break;
        }
        limited.push(ch);
    }
    let limited = limited.trim_end_matches(['.', ' ']).to_string();
    if limited.is_empty() {
        fallback.to_string()
    } else {
        limited
    }
}

/// Lower-case letters and digits only, for comparing names written differently.
pub fn normalized(value: &str) -> String {
    value
        .chars()
        .filter(|ch| ch.is_alphanumeric())
        .flat_map(char::to_lowercase)
        .collect()
}

/// Sort key that orders `Disc 2` before `Disc 10`.
pub fn natural_key(value: &str) -> Vec<(u8, u64, String)> {
    let mut key = Vec::new();
    let mut digits = String::new();
    let mut letters = String::new();
    for ch in value.chars() {
        if ch.is_ascii_digit() {
            if !letters.is_empty() {
                key.push((1, 0, std::mem::take(&mut letters)));
            }
            digits.push(ch);
        } else {
            if !digits.is_empty() {
                key.push((0, digits.parse().unwrap_or(u64::MAX), String::new()));
                digits.clear();
            }
            letters.extend(ch.to_lowercase());
        }
    }
    if !digits.is_empty() {
        key.push((0, digits.parse().unwrap_or(u64::MAX), String::new()));
    }
    if !letters.is_empty() {
        key.push((1, 0, letters));
    }
    key
}

fn c_path(path: &Path) -> Result<CString> {
    CString::new(path.as_os_str().as_bytes())
        .with_context(|| format!("path contains a NUL byte: {}", path.display()))
}

/// Rename that fails instead of replacing an existing destination.
pub fn rename_noreplace(source: &Path, destination: &Path) -> io::Result<()> {
    let from = c_path(source).map_err(io::Error::other)?;
    let to = c_path(destination).map_err(io::Error::other)?;
    // SAFETY: both pointers are valid NUL-terminated paths for the call.
    let rc = unsafe {
        libc::renameat2(
            libc::AT_FDCWD,
            from.as_ptr(),
            libc::AT_FDCWD,
            to.as_ptr(),
            libc::RENAME_NOREPLACE,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// Move one file without ever replacing another. Each systemd
/// `ReadWritePaths` entry is its own bind mount, so a rename between two of
/// them fails with EXDEV even on one dataset; that case copies and verifies.
pub fn move_file(source: &Path, destination: &Path) -> Result<()> {
    match rename_noreplace(source, destination) {
        Ok(()) => return Ok(()),
        Err(error) if error.raw_os_error() == Some(libc::EXDEV) => {}
        Err(error) => {
            return Err(error).with_context(|| {
                format!(
                    "cannot move {} to {}",
                    source.display(),
                    destination.display()
                )
            });
        }
    }
    let partial = destination.with_file_name(format!(
        ".{}.partial",
        destination
            .file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("file")
    ));
    let _ = fs::remove_file(&partial);
    let copied = fs::copy(source, &partial)
        .with_context(|| format!("cannot copy {} to {}", source.display(), partial.display()))?;
    let expected = fs::metadata(source)?.len();
    if copied != expected {
        let _ = fs::remove_file(&partial);
        bail!(
            "copy of {} was short ({copied} of {expected} bytes)",
            source.display()
        );
    }
    fs::File::open(&partial)?.sync_all()?;
    if let Err(error) = rename_noreplace(&partial, destination) {
        let _ = fs::remove_file(&partial);
        return Err(error).with_context(|| format!("cannot publish {}", destination.display()));
    }
    fs::remove_file(source)
        .with_context(|| format!("copied {} but cannot remove the original", source.display()))
}

/// A sibling path that does not exist yet (`name`, `name (2)`, ...).
pub fn unique_destination(directory: &Path, name: &str) -> PathBuf {
    let first = directory.join(name);
    if fs::symlink_metadata(&first).is_err() {
        return first;
    }
    for index in 2.. {
        let candidate = directory.join(format!("{name} ({index})"));
        if fs::symlink_metadata(&candidate).is_err() {
            return candidate;
        }
    }
    unreachable!()
}

pub fn sha256_file(path: &Path) -> Result<String> {
    let mut file =
        fs::File::open(path).with_context(|| format!("cannot open {}", path.display()))?;
    let mut hasher = Sha256::new();
    let mut buffer = vec![0u8; 1 << 20];
    loop {
        let read = file.read(&mut buffer)?;
        if read == 0 {
            break;
        }
        hasher.update(&buffer[..read]);
    }
    Ok(hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect())
}

/// Free bytes available to this user on the filesystem holding `path`.
pub fn free_bytes(path: &Path) -> Result<u64> {
    let target = c_path(path)?;
    // SAFETY: `stats` is plain data that statvfs fully initialises on success.
    let mut stats: libc::statvfs = unsafe { std::mem::zeroed() };
    // SAFETY: the path pointer is valid and `stats` is a writable struct.
    if unsafe { libc::statvfs(target.as_ptr(), &mut stats) } != 0 {
        return Err(io::Error::last_os_error())
            .with_context(|| format!("cannot read free space of {}", path.display()));
    }
    Ok((stats.f_bavail as u64).saturating_mul(stats.f_frsize as u64))
}

/// Login name of the file's owner: the person who uploaded it, whose saved
/// provider accounts identification may use.
pub fn file_owner(path: &Path) -> Option<String> {
    let uid = fs::metadata(path).ok()?.uid();
    let mut buffer = vec![0 as libc::c_char; 4096];
    // SAFETY: `entry` is plain data that getpwuid_r fills in on success.
    let mut entry: libc::passwd = unsafe { std::mem::zeroed() };
    let mut found: *mut libc::passwd = std::ptr::null_mut();
    // SAFETY: every pointer is valid for the call, and `buffer` outlives the
    // read of `pw_name` below, which points into it.
    let status = unsafe {
        libc::getpwuid_r(
            uid,
            &mut entry,
            buffer.as_mut_ptr(),
            buffer.len(),
            &mut found,
        )
    };
    if status != 0 || found.is_null() {
        return None;
    }
    // SAFETY: on success `pw_name` is a NUL-terminated string in `buffer`.
    let name = unsafe { std::ffi::CStr::from_ptr(entry.pw_name) };
    name.to_str().ok().map(str::to_owned)
}

pub fn write_json_atomic(path: &Path, value: &impl Serialize) -> Result<()> {
    let directory = path.parent().context("JSON path has no parent")?;
    let temporary = directory.join(format!(
        ".{}.tmp",
        path.file_name()
            .and_then(|name| name.to_str())
            .unwrap_or("state")
    ));
    let mut text = serde_json::to_string_pretty(value)?;
    text.push('\n');
    fs::write(&temporary, text).with_context(|| format!("cannot write {}", temporary.display()))?;
    fs::rename(&temporary, path).with_context(|| format!("cannot replace {}", path.display()))
}

#[cfg(test)]
mod tests {
    use super::*;

    // These two tests exist because the importer moves ISOs and removes the
    // folders it emptied: a name that escaped its parent, or a move that
    // replaced a file, would lose an archive that cannot be ripped again
    // without the physical disc.
    #[test]
    fn names_cannot_escape_or_hide() {
        assert_eq!(safe_component("../../etc/passwd", "x"), "etc passwd");
        assert_eq!(safe_component("..", "Unknown"), "Unknown");
        assert_eq!(safe_component(".hidden", "x"), "hidden");
        assert_eq!(safe_component("Guards! Guards!", "x"), "Guards! Guards!");
        assert_eq!(safe_component("A: B / C?", "x"), "A B C");
        assert_eq!(safe_component(" \u{0}\n ", "Unknown"), "Unknown");
    }

    #[test]
    fn moves_never_replace_a_file() {
        let directory = tempfile_dir();
        let source = directory.join("a");
        let destination = directory.join("b");
        fs::write(&source, "new").unwrap();
        fs::write(&destination, "kept").unwrap();
        assert!(move_file(&source, &destination).is_err());
        assert_eq!(fs::read_to_string(&destination).unwrap(), "kept");
        assert_eq!(fs::read_to_string(&source).unwrap(), "new");
        fs::remove_dir_all(directory).unwrap();
    }

    fn tempfile_dir() -> PathBuf {
        let directory = std::env::temp_dir().join(format!(
            "audio-import-fsops-{}-{:?}",
            std::process::id(),
            std::thread::current().id()
        ));
        let _ = fs::remove_dir_all(&directory);
        fs::create_dir_all(&directory).unwrap();
        directory
    }
}
