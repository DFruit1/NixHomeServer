use std::{
    env,
    fs::{self, OpenOptions},
    io::Write,
    os::unix::fs::{DirBuilderExt, OpenOptionsExt},
    path::PathBuf,
};

use pbkdf2::pbkdf2_hmac;
use rand::{rngs::OsRng, RngCore};
use serde_json::json;
use sha2::Sha512;

use crate::{output::CommandOutput, AppError};

const DEFAULT_PASSWORD_HASH_DIR: &str = "/var/lib/jellyfin/.nixos-managed/desired-password-hashes";
const PASSWORD_HASH_DIR_ENV: &str = "KANIDM_ADMIN_JELLYFIN_PASSWORD_HASH_DIR";
const PBKDF2_ITERATIONS: u32 = 210_000;

pub fn set_jellyfin_password(
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

    write_password_hash(&directory, &path, &hash_password(&password))?;

    Ok(CommandOutput {
        message: format!("stored desired Jellyfin password hash for '{account_id}'"),
        human: format!(
            "Stored the desired Jellyfin password hash for '{account_id}'.\nPath: {}\nSource env var: {password_env}",
            path.display()
        ),
        details: json!({
            "account_id": account_id,
            "path": path,
            "password_env": password_env,
        }),
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

fn write_password_hash(directory: &PathBuf, path: &PathBuf, password_hash: &str) -> Result<(), AppError> {
    let mut builder = fs::DirBuilder::new();
    builder.recursive(true);
    builder.mode(0o700);
    builder.create(directory).map_err(|error| AppError::Io {
        message: format!(
            "failed to create Jellyfin password state directory '{}': {error}",
            directory.display()
        ),
    })?;

    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o600)
        .open(path)
        .map_err(|error| AppError::Io {
            message: format!(
                "failed to open Jellyfin password state file '{}': {error}",
                path.display()
            ),
        })?;

    file.write_all(password_hash.as_bytes())
        .and_then(|_| file.write_all(b"\n"))
        .map_err(|error| AppError::Io {
            message: format!(
                "failed to write Jellyfin password state file '{}': {error}",
                path.display()
            ),
        })
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

        env::set_var(PASSWORD_HASH_DIR_ENV, temp.path());
        env::set_var("TEST_JELLYFIN_PASSWORD", "super-secret");

        let output =
            set_jellyfin_password("dsaw", "TEST_JELLYFIN_PASSWORD").expect("set password");

        let hash_path = temp.path().join("dsaw.pbkdf2");
        let stored = fs::read_to_string(&hash_path).expect("hash file");
        assert!(stored.starts_with("$PBKDF2-SHA512$iterations=210000$"));
        assert!(output.human.contains(hash_path.to_string_lossy().as_ref()));

        env::remove_var(PASSWORD_HASH_DIR_ENV);
        env::remove_var("TEST_JELLYFIN_PASSWORD");
    }
}
