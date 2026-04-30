use std::{
    env,
    fs::{self, File, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::{Path, PathBuf},
};

use pbkdf2::pbkdf2_hmac;
use rand::{rngs::OsRng, RngCore};
use serde_json::json;
use sha2::Sha512;

use crate::{output::CommandOutput, AppError};

const DEFAULT_PASSWORD_HASH_DIR: &str = "/var/lib/jellyfin/.nixos-managed/desired-password-hashes";
const PASSWORD_HASH_DIR_ENV: &str = "KANIDM_ADMIN_JELLYFIN_PASSWORD_HASH_DIR";
const PBKDF2_ITERATIONS: u32 = 210_000;

pub fn stage_jellyfin_password(
    account_id: &str,
    password_env: &str,
) -> Result<CommandOutput, AppError> {
    validate_account_id(account_id)?;

    let password = env::var(password_env).map_err(|_| AppError::Config {
        message: format!("environment variable '{password_env}' is required"),
    })?;
    if password.is_empty() {
        return Err(AppError::Config {
            message: format!("environment variable '{password_env}' must not be empty"),
        });
    }

    let directory = env::var_os(PASSWORD_HASH_DIR_ENV)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(DEFAULT_PASSWORD_HASH_DIR));
    let path = directory.join(format!("{account_id}.pbkdf2"));

    write_password_hash_atomic(&directory, &path, &hash_password(&password))?;

    Ok(CommandOutput {
        message: format!("staged desired Jellyfin password hash for '{account_id}'"),
        human: format!(
            "Staged the desired Jellyfin password hash for '{account_id}'.\nPath: {}\nSource env var: {password_env}\nThe Jellyfin reconcile service still needs to apply this staged hash.",
            path.display()
        ),
        details: json!({
            "account_id": account_id,
            "path": path,
            "password_env": password_env,
            "staged": true,
        }),
        warnings: vec![
            "The Jellyfin reconcile timer or service must still converge before the password change is active.".to_string(),
        ],
    })
}

fn validate_account_id(account_id: &str) -> Result<(), AppError> {
    let valid = !account_id.is_empty()
        && account_id
            .chars()
            .all(|ch| ch.is_ascii_alphanumeric() || matches!(ch, '-' | '_' | '.'));
    if valid {
        Ok(())
    } else {
        Err(AppError::Config {
            message: format!("invalid Jellyfin account id for filename use: '{account_id}'"),
        })
    }
}

fn hash_password(password: &str) -> String {
    let mut salt = [0u8; 16];
    OsRng.fill_bytes(&mut salt);

    let mut derived = [0u8; 64];
    pbkdf2_hmac::<Sha512>(password.as_bytes(), &salt, PBKDF2_ITERATIONS, &mut derived);

    format!(
        "$PBKDF2-SHA512$iterations={PBKDF2_ITERATIONS}${}${}",
        hex_upper(&salt),
        hex_upper(&derived)
    )
}

fn hex_upper(bytes: &[u8]) -> String {
    let mut out = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        out.push_str(&format!("{byte:02X}"));
    }
    out
}

fn write_password_hash_atomic(
    directory: &Path,
    path: &Path,
    password_hash: &str,
) -> Result<(), AppError> {
    ensure_safe_directory_path(directory)?;

    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    builder.mode(0o700);
    builder.create(directory).map_err(|error| AppError::Io {
        message: format!(
            "failed to create Jellyfin password state directory '{}': {error}",
            directory.display()
        ),
    })?;

    let metadata = fs::metadata(directory).map_err(|error| AppError::Io {
        message: format!(
            "failed to inspect Jellyfin password state directory '{}': {error}",
            directory.display()
        ),
    })?;
    if !metadata.is_dir() {
        return Err(AppError::Io {
            message: format!(
                "Jellyfin password state directory path '{}' exists but is not a directory",
                directory.display()
            ),
        });
    }

    let (temp_path, mut file) = create_temp_file(directory, path)?;

    if let Err(error) = file
        .write_all(password_hash.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
    {
        cleanup_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to write temporary Jellyfin password state file '{}': {error}",
                temp_path.display()
            ),
        });
    }

    if let Err(error) = file.sync_all() {
        cleanup_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to fsync temporary Jellyfin password state file '{}': {error}",
                temp_path.display()
            ),
        });
    }
    drop(file);

    if let Err(error) = fs::rename(&temp_path, path) {
        cleanup_temp_file(&temp_path);
        return Err(AppError::Io {
            message: format!(
                "failed to atomically replace Jellyfin password state file '{}' with '{}': {error}",
                path.display(),
                temp_path.display()
            ),
        });
    }

    best_effort_directory_sync(directory);
    Ok(())
}

fn ensure_safe_directory_path(directory: &Path) -> Result<(), AppError> {
    let mut current = PathBuf::new();

    for component in directory.components() {
        current.push(component.as_os_str());

        let metadata = match fs::symlink_metadata(&current) {
            Ok(metadata) => metadata,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
            Err(error) => {
                return Err(AppError::Io {
                    message: format!(
                        "failed to inspect Jellyfin password path component '{}': {error}",
                        current.display()
                    ),
                });
            }
        };

        if metadata.file_type().is_symlink() {
            return Err(AppError::Io {
                message: format!(
                    "Jellyfin password state directory path '{}' resolves through symlinked component '{}'",
                    directory.display(),
                    current.display()
                ),
            });
        }

        if current != directory && !metadata.is_dir() {
            return Err(AppError::Io {
                message: format!(
                    "Jellyfin password path component '{}' exists but is not a directory",
                    current.display()
                ),
            });
        }
    }

    Ok(())
}

fn create_temp_file(directory: &Path, path: &Path) -> Result<(PathBuf, File), AppError> {
    let stem = path
        .file_stem()
        .and_then(|value| value.to_str())
        .unwrap_or("jellyfin");

    for _ in 0..32 {
        let temp_path = directory.join(format!(".{stem}.pbkdf2.tmp-{}", random_suffix()));
        match OpenOptions::new()
            .create_new(true)
            .write(true)
            .mode(0o600)
            .open(&temp_path)
        {
            Ok(file) => return Ok((temp_path, file)),
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => continue,
            Err(error) => {
                return Err(AppError::Io {
                    message: format!(
                        "failed to open temporary Jellyfin password state file '{}' in '{}': {error}",
                        temp_path.display(),
                        directory.display()
                    ),
                });
            }
        }
    }

    Err(AppError::Io {
        message: format!(
            "failed to allocate a unique temporary Jellyfin password state file in '{}'",
            directory.display()
        ),
    })
}

fn random_suffix() -> String {
    let mut bytes = [0u8; 8];
    OsRng.fill_bytes(&mut bytes);
    hex_upper(&bytes)
}

fn cleanup_temp_file(path: &Path) {
    let _ = fs::remove_file(path);
}

fn best_effort_directory_sync(directory: &Path) {
    if let Ok(dir) = File::open(directory) {
        let _ = dir.sync_all();
    }
}

#[cfg(test)]
mod tests {
    use std::{fs, sync::Mutex};

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    #[test]
    fn writes_password_hash_file_from_env() {
        let _guard = ENV_LOCK.lock().expect("env lock");
        let temp = tempfile::tempdir().expect("tempdir");
        let original_password = env::var_os("TEST_JELLYFIN_PASSWORD");
        let original_dir = env::var_os(PASSWORD_HASH_DIR_ENV);
        env::set_var("TEST_JELLYFIN_PASSWORD", "correct horse battery staple");
        env::set_var(PASSWORD_HASH_DIR_ENV, temp.path());

        let output =
            stage_jellyfin_password("dsaw", "TEST_JELLYFIN_PASSWORD").expect("set password");

        let hash_path = temp.path().join("dsaw.pbkdf2");
        let stored = fs::read_to_string(&hash_path).expect("hash file");
        assert!(stored.contains("$PBKDF2-SHA512$iterations=210000$"));
        assert_eq!(output.details["account_id"], "dsaw");

        match original_password {
            Some(value) => env::set_var("TEST_JELLYFIN_PASSWORD", value),
            None => env::remove_var("TEST_JELLYFIN_PASSWORD"),
        }
        match original_dir {
            Some(value) => env::set_var(PASSWORD_HASH_DIR_ENV, value),
            None => env::remove_var(PASSWORD_HASH_DIR_ENV),
        }
    }
}
