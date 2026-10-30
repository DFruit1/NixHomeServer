//! Profile imports never invoke tar until every header and inflated byte is checked.
use crate::{catalog::now, config::AppConfig, custody, database::Database};
use serde_json::json;
use std::{
    io::{Read, Write},
    path::Path,
};
pub const PROFILE_BYTES: usize = 32 * 1024 * 1024;
pub fn validate_tar(path: &Path) -> Result<(), String> {
    let input = custody::open_nofollow(path)?;
    let mut decoder = flate2::read::GzDecoder::new(input).take(256 * 1024 * 1024 + 1);
    let mut entries = 0u32;
    let mut total = 0u64;
    let mut names = std::collections::BTreeSet::new();
    loop {
        let mut header = [0u8; 512];
        decoder
            .read_exact(&mut header)
            .map_err(|_| "truncated profile tar header".to_owned())?;
        total += 512;
        if header.iter().all(|b| *b == 0) {
            let mut end = [0u8; 512];
            decoder
                .read_exact(&mut end)
                .map_err(|_| "missing tar terminator")?;
            if end.iter().any(|b| *b != 0) {
                return Err("invalid tar terminator".into());
            }
            let mut trailing = Vec::new();
            decoder
                .take(1024 * 1024)
                .read_to_end(&mut trailing)
                .map_err(|e| e.to_string())?;
            if trailing.iter().any(|b| *b != 0) {
                return Err("profile has data after tar terminator".into());
            }
            return Ok(());
        }
        entries += 1;
        if entries > 10000 {
            return Err("profile entry limit exceeded".into());
        }
        let octal = |bytes: &[u8]| -> Result<u64, String> {
            let s = std::str::from_utf8(bytes)
                .map_err(|_| "invalid tar number")?
                .trim_matches(['\0', ' ']);
            u64::from_str_radix(if s.is_empty() { "0" } else { s }, 8)
                .map_err(|_| "invalid tar number".into())
        };
        let expected = octal(&header[148..156])?;
        let checksum: u64 = header
            .iter()
            .enumerate()
            .map(|(i, v)| {
                if (148..156).contains(&i) {
                    32
                } else {
                    u64::from(*v)
                }
            })
            .sum();
        if expected != checksum {
            return Err("profile tar checksum mismatch".into());
        }
        let field = |bytes: &[u8]| -> Result<String, String> {
            let end = bytes.iter().position(|b| *b == 0).unwrap_or(bytes.len());
            String::from_utf8(bytes[..end].to_vec()).map_err(|_| "profile path is not UTF-8".into())
        };
        let name = field(&header[..100])?;
        let prefix = field(&header[345..500])?;
        let name = if prefix.is_empty() {
            name
        } else {
            format!("{prefix}/{name}")
        };
        let p = Path::new(&name);
        if name.is_empty()
            || name.contains('\\')
            || name.contains(':')
            || name.chars().any(char::is_control)
            || p.is_absolute()
            || p.components().any(|c| {
                !matches!(
                    c,
                    std::path::Component::Normal(_) | std::path::Component::CurDir
                )
            })
        {
            return Err("unsafe path in profile tar".into());
        }
        if !matches!(header[156], 0 | b'0' | b'5') {
            return Err("profile tar links, devices and extension headers are forbidden".into());
        }
        if !names.insert(name) {
            return Err("duplicate profile path".into());
        }
        let size = octal(&header[124..136])?;
        if size > 64 * 1024 * 1024 || (header[156] == b'5' && size != 0) {
            return Err("invalid profile entry size".into());
        }
        let padded = size.checked_add(511).ok_or("profile size overflow")? / 512 * 512;
        total = total.checked_add(padded).ok_or("profile size overflow")?;
        if total > 256 * 1024 * 1024 {
            return Err("inflated profile size limit exceeded".into());
        }
        let copied = std::io::copy(&mut decoder.by_ref().take(padded), &mut std::io::sink())
            .map_err(|e| e.to_string())?;
        if copied != padded {
            return Err("truncated profile entry".into());
        }
    }
}
pub fn accept(
    config: &AppConfig,
    db: &Database,
    id: &str,
    inbox: &str,
    owner: &str,
) -> Result<(), String> {
    if !custody::safe_id(id) || !custody::safe_id(inbox) {
        return Err("unsafe profile identifier".into());
    }
    let mut metadata = db
        .record("profile", id, owner)
        .map_err(|e| e.to_string())?
        .ok_or("profile not found")?;
    if metadata["revoked"].as_bool() == Some(true) {
        return Err("profile was revoked before validation".into());
    }
    let source = custody::checked_file(&config.inbox_root, inbox)?;
    validate_tar(&source)?;
    let digest = custody::sha256(&source)?;
    custody::private_directory(&config.profiles_root)?;
    let destination = config.profiles_root.join(format!("{id}.tar.gz"));
    let mut input = custody::open_nofollow(&source)?;
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut output = options.open(&destination).map_err(|e| e.to_string())?;
    std::io::copy(&mut input, &mut output).map_err(|e| e.to_string())?;
    output
        .flush()
        .and_then(|_| output.sync_all())
        .map_err(|e| e.to_string())?;
    custody::sync_directory(&config.profiles_root)?;
    metadata = db
        .record("profile", id, owner)
        .map_err(|e| e.to_string())?
        .filter(|v| v["revoked"].as_bool() != Some(true))
        .ok_or("profile revoked during validation; material remains private")?;
    metadata["digest"] = json!(digest);
    metadata["available"] = json!(true);
    metadata["updatedAt"] = json!(now());
    db.put_record("profile", id, owner, &metadata)
        .map_err(|e| e.to_string())?;
    std::fs::remove_file(source).map_err(|e| e.to_string())?;
    Ok(())
}
pub fn checked_profile(
    config: &AppConfig,
    db: &Database,
    id: &str,
    owner: &str,
) -> Result<std::path::PathBuf, String> {
    if !custody::safe_id(id) {
        return Err("invalid profile identity".into());
    }
    let value = db
        .record("profile", id, owner)
        .map_err(|e| e.to_string())?
        .ok_or("profile not found")?;
    if value["available"].as_bool() != Some(true) || value["revoked"].as_bool() == Some(true) {
        return Err("profile unavailable or revoked".into());
    }
    if let Some(expiry) = value["expiresAt"].as_str() {
        let stamp =
            chrono::DateTime::parse_from_rfc3339(expiry).map_err(|_| "invalid profile expiry")?;
        if stamp <= chrono::Utc::now() {
            return Err("profile expired".into());
        }
    }
    let path = custody::checked_file(&config.profiles_root, &format!("{id}.tar.gz"))?;
    if custody::sha256(&path)? != value["digest"].as_str().unwrap_or("") {
        return Err("profile digest changed; refusing capture".into());
    }
    validate_tar(&path)?;
    Ok(path)
}
