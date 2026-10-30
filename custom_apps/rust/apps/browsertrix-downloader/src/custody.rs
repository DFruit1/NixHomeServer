//! Publication is a durable intent followed by an exclusive, synced payload and
//! idempotent catalogue transaction. Scratch remains until every step succeeds.
use crate::{
    catalog::{Archive, PublicationIntent},
    config::AppConfig,
    database::Database,
};
use sha2::{Digest, Sha256};
use std::{
    fs::{self, File, OpenOptions},
    io::{Read, Write},
    path::{Path, PathBuf},
};
pub fn root<'a>(config: &'a AppConfig, archive: &Archive) -> &'a Path {
    if archive.visibility == "private" {
        &config.private_archive_root
    } else {
        &config.archive_root
    }
}
pub fn safe_id(id: &str) -> bool {
    !id.is_empty() && id.len() <= 128 && id.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-')
}
pub fn checked_file(root: &Path, name: &str) -> Result<PathBuf, String> {
    let relative = Path::new(name);
    if relative.components().count() != 1
        || !matches!(
            relative.components().next(),
            Some(std::path::Component::Normal(_))
        )
    {
        return Err("unsafe payload name".into());
    }
    let meta = fs::symlink_metadata(root).map_err(|e| e.to_string())?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err("payload root is not a real directory".into());
    }
    let path = root.join(name);
    let meta = fs::symlink_metadata(&path).map_err(|e| e.to_string())?;
    if !meta.is_file() || meta.file_type().is_symlink() {
        return Err("payload is not a regular file".into());
    }
    Ok(path)
}
pub fn open_nofollow(path: &Path) -> Result<File, String> {
    let mut options = OpenOptions::new();
    options.read(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK);
    }
    let file = options.open(path).map_err(|e| e.to_string())?;
    if !file.metadata().map_err(|e| e.to_string())?.is_file() {
        return Err("payload is not regular".into());
    }
    Ok(file)
}
pub fn sha256(path: &Path) -> Result<String, String> {
    let mut input = open_nofollow(path)?;
    let mut hash = Sha256::new();
    let mut buffer = [0u8; 65536];
    loop {
        let n = input.read(&mut buffer).map_err(|e| e.to_string())?;
        if n == 0 {
            break;
        }
        hash.update(&buffer[..n]);
    }
    Ok(format!("{:x}", hash.finalize()))
}
pub fn sync_directory(path: &Path) -> Result<(), String> {
    File::open(path)
        .and_then(|f| f.sync_all())
        .map_err(|e| format!("sync containing directory: {e}"))
}
pub fn private_directory(path: &Path) -> Result<(), String> {
    fs::create_dir_all(path).map_err(|e| e.to_string())?;
    let meta = fs::symlink_metadata(path).map_err(|e| e.to_string())?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err("state directory cannot be a symlink".into());
    }
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700)).map_err(|e| e.to_string())?;
    }
    Ok(())
}
pub fn publish(
    config: &AppConfig,
    db: &Database,
    intent: &PublicationIntent,
) -> Result<(), String> {
    if intent.archive.sha256.len() != 64 || intent.report.sha256 != intent.archive.sha256 {
        return Err("publication requires an inspected SHA-256 identity".into());
    }
    db.put_intent(intent).map_err(|e| e.to_string())?;
    recover_one(config, db, intent)
}
pub fn recover(config: &AppConfig, db: &Database) -> Result<usize, String> {
    let mut count = 0;
    for intent in db.pending_intents().map_err(|e| e.to_string())? {
        recover_one(config, db, &intent)?;
        count += 1;
    }
    Ok(count)
}
fn recover_one(
    config: &AppConfig,
    db: &Database,
    intent: &PublicationIntent,
) -> Result<(), String> {
    let a = &intent.archive;
    if !safe_id(&a.id) {
        return Err("invalid archive identity in intent".into());
    }
    let destination_root = root(config, a);
    fs::create_dir_all(destination_root).map_err(|e| e.to_string())?;
    let meta = fs::symlink_metadata(destination_root).map_err(|e| e.to_string())?;
    if !meta.is_dir() || meta.file_type().is_symlink() {
        return Err("publication root is not a real directory".into());
    }
    let name = &a.archive_file;
    if Path::new(name).components().count() != 1 || !name.ends_with(".wacz") {
        return Err("invalid destination in intent".into());
    }
    let destination = destination_root.join(name);
    let staging = destination_root.join(format!(".{}.pending", a.id));
    if destination.try_exists().map_err(|e| e.to_string())? {
        if sha256(&destination)? != a.sha256 {
            return Err(
                "published path conflicts with immutable intent; preserving both copies".into(),
            );
        }
    } else {
        if staging.try_exists().map_err(|e| e.to_string())? && sha256(&staging)? != a.sha256 {
            let retained = destination_root.join(format!(
                ".{}.incomplete-{}",
                a.id,
                crate::queue::random_job_id()
            ));
            rename_exclusive(&staging, &retained)?;
            sync_directory(destination_root)?;
        }
        if !staging.try_exists().map_err(|e| e.to_string())? {
            let source = Path::new(&intent.source);
            let canonical = source.canonicalize().map_err(|e| e.to_string())?;
            let allowed = [
                &config.checkpoints_root,
                &config.inbox_root,
                &config.crawls_root,
            ];
            if !allowed
                .iter()
                .filter_map(|r| r.canonicalize().ok())
                .any(|r| canonical.starts_with(r))
            {
                return Err("intent source is outside worker staging".into());
            }
            let mut input = open_nofollow(source)?;
            let mut options = OpenOptions::new();
            options.write(true).create_new(true);
            #[cfg(unix)]
            {
                use std::os::unix::fs::OpenOptionsExt;
                options.mode(0o600);
            }
            let mut output = options
                .open(&staging)
                .map_err(|e| format!("exclusive staging: {e}"))?;
            std::io::copy(&mut input, &mut output).map_err(|e| e.to_string())?;
            output
                .flush()
                .and_then(|_| output.sync_all())
                .map_err(|e| e.to_string())?;
            if sha256(&staging)? != a.sha256 {
                return Err(
                    "archive changed during publication; source and intent retained".into(),
                );
            }
        }
        set_permissions(&staging, config, a.visibility == "private")?;
        File::open(&staging)
            .and_then(|f| f.sync_all())
            .map_err(|e| e.to_string())?;
        sync_directory(destination_root)?;
        rename_exclusive(&staging, &destination)?;
        sync_directory(destination_root)?;
    }
    db.finalize_intent(intent)
        .map_err(|e| format!("catalogue commit after publication: {e}"))?;
    Ok(())
}
fn rename_exclusive(from: &Path, to: &Path) -> Result<(), String> {
    #[cfg(target_os = "linux")]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let a = CString::new(from.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        let b = CString::new(to.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        if unsafe {
            libc::renameat2(
                libc::AT_FDCWD,
                a.as_ptr(),
                libc::AT_FDCWD,
                b.as_ptr(),
                libc::RENAME_NOREPLACE,
            )
        } != 0
        {
            return Err(format!(
                "exclusive publication rename: {}",
                std::io::Error::last_os_error()
            ));
        }
        Ok(())
    }
    #[cfg(not(target_os = "linux"))]
    {
        fs::hard_link(from, to)
            .and_then(|_| fs::remove_file(from))
            .map_err(|e| e.to_string())
    }
}
fn set_permissions(path: &Path, config: &AppConfig, private: bool) -> Result<(), String> {
    #[cfg(unix)]
    {
        use std::{
            ffi::CString,
            os::unix::{ffi::OsStrExt, fs::PermissionsExt},
        };
        let gid = if private {
            config.private_archive_gid
        } else {
            config.archive_gid
        };
        let c = CString::new(path.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        if unsafe { libc::chown(c.as_ptr(), config.archive_uid, gid) } != 0 {
            return Err(format!(
                "archive ownership: {}",
                std::io::Error::last_os_error()
            ));
        }
        fs::set_permissions(
            path,
            fs::Permissions::from_mode(if private { 0o640 } else { 0o660 }),
        )
        .map_err(|e| e.to_string())?;
    }
    Ok(())
}
pub fn available_bytes(path: &Path) -> Result<u64, String> {
    #[cfg(unix)]
    {
        use std::{ffi::CString, os::unix::ffi::OsStrExt};
        let path = CString::new(path.as_os_str().as_bytes()).map_err(|e| e.to_string())?;
        let mut stat = std::mem::MaybeUninit::<libc::statvfs>::uninit();
        if unsafe { libc::statvfs(path.as_ptr(), stat.as_mut_ptr()) } != 0 {
            return Err(std::io::Error::last_os_error().to_string());
        }
        let stat = unsafe { stat.assume_init() };
        Ok((stat.f_bavail as u64).saturating_mul(stat.f_frsize as u64))
    }
    #[cfg(not(unix))]
    {
        Err("disk headroom checks unsupported".into())
    }
}
