//! Per-device MQTT accounts for Mosquitto.
//!
//! Opt-in per device. The username is the 24-hex DeviceID; a static pattern
//! ACL in the NixOS module (`pattern write gwl/v1/%u/...`) limits every such
//! account to its own topics, so only passwords are dynamic. The server keeps
//! the PBKDF2-SHA512 hash (Mosquitto `$7$` format) in
//! `device_mqtt_credentials` and writes two files into
//! `GROUNDWATER_MQTT_AUTH_DIR`:
//!
//! - `devices.passwd`: `DEVICEID:$7$...` for units in mode `dual` or `device`;
//! - `devices.deny`: DeviceIDs in mode `device`, whose topics the shared
//!   logger account is denied;
//!
//! then bumps `serial`. A root-owned path unit merges them into Mosquitto's
//! listener files (validating every line again) and reloads the broker. The
//! plaintext password is returned to the operator once and never stored.

use std::{
    io::Write,
    path::{Path, PathBuf},
};

use base64::Engine;
use chrono::Utc;
use hmac::{Hmac, Mac};
use rand::RngCore;
use sha2::Sha512;
use tokio_postgres::GenericClient;

/// PBKDF2 rounds. Mosquitto verifies on every CONNECT; a logger connects a
/// few times a day, so the cost is negligible next to a TLS handshake.
pub const ITERATIONS: u32 = 100_000;
const SALT_LEN: usize = 12;
pub const PASSWORD_LEN: usize = 32;

pub const PASSWD_FILE: &str = "devices.passwd";
pub const DENY_FILE: &str = "devices.deny";
pub const SERIAL_FILE: &str = "serial";

fn random_bytes<const N: usize>() -> [u8; N] {
    let mut bytes = [0u8; N];
    rand::rngs::OsRng.fill_bytes(&mut bytes);
    bytes
}

/// A random password of letters and digits: the firmware's C string and the
/// modem's `AT+QMTCONN` quoting both accept it without escaping.
pub fn generate_password() -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789";
    let mut out = String::with_capacity(PASSWORD_LEN);
    while out.len() < PASSWORD_LEN {
        for byte in random_bytes::<64>() {
            // Rejection sampling keeps the alphabet uniform.
            let limit = 256 - 256 % ALPHABET.len();
            if usize::from(byte) < limit && out.len() < PASSWORD_LEN {
                out.push(char::from(ALPHABET[usize::from(byte) % ALPHABET.len()]));
            }
        }
    }
    out
}

fn pbkdf2_sha512(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 64] {
    let mac = Hmac::<Sha512>::new_from_slice(password).expect("HMAC accepts any key length");
    let mut u = {
        let mut m = mac.clone();
        m.update(salt);
        m.update(&1u32.to_be_bytes());
        m.finalize().into_bytes()
    };
    let mut out = [0u8; 64];
    out.copy_from_slice(&u);
    for _ in 1..iterations {
        let mut m = mac.clone();
        m.update(&u);
        u = m.finalize().into_bytes();
        for (o, b) in out.iter_mut().zip(u.iter()) {
            *o ^= b;
        }
    }
    out
}

/// Mosquitto's `$7$<iterations>$<salt>$<hash>` (PBKDF2-HMAC-SHA512, 64-byte
/// hash, standard base64), as `mosquitto_passwd` writes it.
pub fn hash_with(password: &str, salt: &[u8], iterations: u32) -> String {
    let engine = base64::engine::general_purpose::STANDARD;
    let hash = pbkdf2_sha512(password.as_bytes(), salt, iterations);
    format!(
        "$7${iterations}${}${}",
        engine.encode(salt),
        engine.encode(hash)
    )
}

pub fn hash_password(password: &str) -> String {
    hash_with(password, &random_bytes::<SALT_LEN>(), ITERATIONS)
}

/// Checks a password against a `$7$` hash (used by tests and the merge
/// script's expectations; Mosquitto does the real check).
#[cfg(test)]
pub fn verify(password: &str, encoded: &str) -> bool {
    let engine = base64::engine::general_purpose::STANDARD;
    let parts: Vec<&str> = encoded.split('$').collect();
    let [_, "7", iterations, salt, _] = parts.as_slice() else {
        return false;
    };
    let (Ok(iterations), Ok(salt)) = (iterations.parse::<u32>(), engine.decode(salt)) else {
        return false;
    };
    hash_with(password, &salt, iterations) == encoded
}

/// A 24-character uppercase hexadecimal DeviceID, the only username shape
/// the merge step accepts.
pub fn valid_username(name: &str) -> bool {
    name.len() == 24
        && name
            .bytes()
            .all(|b| b.is_ascii_digit() || (b'A'..=b'F').contains(&b))
}

pub fn valid_hash(hash: &str) -> bool {
    let parts: Vec<&str> = hash.split('$').collect();
    matches!(parts.as_slice(), ["", "7", iterations, salt, digest]
        if !iterations.is_empty() && iterations.bytes().all(|b| b.is_ascii_digit())
            && [salt, digest].iter().all(|p| !p.is_empty()
                && p.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'+' | b'/' | b'='))))
}

/// One account line.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Account {
    pub device_id: String,
    pub hash: String,
    /// `device`: the shared account is denied this unit's topics.
    pub exclusive: bool,
}

/// File contents for a set of accounts, sorted for stable diffs. Invalid
/// rows are dropped rather than written.
pub fn render(accounts: &[Account]) -> (String, String) {
    let mut valid: Vec<&Account> = accounts
        .iter()
        .filter(|a| valid_username(&a.device_id) && valid_hash(&a.hash))
        .collect();
    valid.sort_by(|a, b| a.device_id.cmp(&b.device_id));
    let passwd = valid
        .iter()
        .map(|a| format!("{}:{}\n", a.device_id, a.hash))
        .collect();
    let deny = valid
        .iter()
        .filter(|a| a.exclusive)
        .map(|a| format!("{}\n", a.device_id))
        .collect();
    (passwd, deny)
}

fn write_atomic(dir: &Path, name: &str, contents: &str) -> std::io::Result<()> {
    use std::os::unix::fs::PermissionsExt;
    let target = dir.join(name);
    let temp: PathBuf = dir.join(format!(".{name}.tmp"));
    {
        let mut file = std::fs::File::create(&temp)?;
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
    }
    // Group-readable for the broker's merge step (the directory is setgid
    // to the mosquitto group); the service umask would make it 0600.
    std::fs::set_permissions(&temp, std::fs::Permissions::from_mode(0o640))?;
    std::fs::rename(&temp, &target)
}

/// Writes both files, then rewrites `serial` in place: the broker's path
/// unit watches that single file, so it reacts once both are in place.
pub fn write_files(dir: &Path, accounts: &[Account]) -> std::io::Result<()> {
    let (passwd, deny) = render(accounts);
    write_atomic(dir, PASSWD_FILE, &passwd)?;
    write_atomic(dir, DENY_FILE, &deny)?;
    let serial = dir.join(SERIAL_FILE);
    let mut file = std::fs::File::create(&serial)?;
    writeln!(file, "{}", Utc::now().timestamp_micros())?;
    file.sync_all()?;
    std::fs::set_permissions(&serial, std::os::unix::fs::PermissionsExt::from_mode(0o640))
}

/// Writes the current accounts of every live enrollment and records when.
pub async fn publish<C: GenericClient + Sync>(client: &C, dir: &Path) -> Result<usize, String> {
    let rows = client
        .query(
            "SELECT c.device_id,c.password_hash,c.mode='device' FROM device_mqtt_credentials c
             JOIN devices d ON d.device_id=c.device_id WHERE d.revoked_at IS NULL ORDER BY c.device_id",
            &[],
        )
        .await
        .map_err(|e| format!("mqtt credentials: {e}"))?;
    let accounts: Vec<Account> = rows
        .iter()
        .map(|r| Account {
            device_id: r.get(0),
            hash: r.get(1),
            exclusive: r.get(2),
        })
        .collect();
    let dir = dir.to_owned();
    let written = accounts.clone();
    tokio::task::spawn_blocking(move || write_files(&dir, &written))
        .await
        .map_err(|e| format!("mqtt credentials writer: {e}"))?
        .map_err(|e| format!("mqtt credentials files: {e}"))?;
    client
        .execute("UPDATE device_mqtt_credentials SET published_at=now()", &[])
        .await
        .map_err(|e| format!("mqtt credentials published_at: {e}"))?;
    Ok(accounts.len())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pbkdf2_matches_the_rfc_style_vector() {
        // PBKDF2-HMAC-SHA512("password","salt",1) from RFC 6070-style tables.
        let out = pbkdf2_sha512(b"password", b"salt", 1);
        assert_eq!(
            crate::stream::hex_encode(&out[..16]),
            "867F70CF1ADE02CFF3752599A3A53DC4"
        );
        let out = pbkdf2_sha512(b"password", b"salt", 2);
        assert_eq!(
            crate::stream::hex_encode(&out[..16]),
            "E1D9C16AA681708A45F5C7C4E215CEB6"
        );
    }

    #[test]
    fn mosquitto_hash_format_round_trips() {
        let hash = hash_with("secret", &[7u8; 12], 1000);
        assert!(hash.starts_with("$7$1000$BwcHBwcHBwcHBwcH$"), "{hash}");
        assert!(valid_hash(&hash));
        assert!(verify("secret", &hash));
        assert!(!verify("Secret", &hash));
        assert!(!valid_hash("$6$abc$def"));
        assert!(!valid_hash("$7$10$a:b$c"));
        assert!(!valid_hash("$7$$abc$def"));
    }

    #[test]
    fn passwords_are_long_and_shell_safe() {
        let a = generate_password();
        let b = generate_password();
        assert_eq!(a.len(), PASSWORD_LEN);
        assert_ne!(a, b);
        assert!(a.bytes().all(|c| c.is_ascii_alphanumeric()));
    }

    #[test]
    fn files_list_only_valid_accounts_and_exclusive_units() {
        let hash = hash_with("x", &[1u8; 12], 1);
        let accounts = [
            Account {
                device_id: "6A1B2C3D4E5F60718293A4B5".into(),
                hash: hash.clone(),
                exclusive: true,
            },
            Account {
                device_id: "0000000000000000000000C1".into(),
                hash: hash.clone(),
                exclusive: false,
            },
            // Never a static account name, never a malformed hash.
            Account {
                device_id: "groundwater-app".into(),
                hash: hash.clone(),
                exclusive: false,
            },
            Account {
                device_id: "0000000000000000000000C2".into(),
                hash: "plain:text".into(),
                exclusive: false,
            },
        ];
        let (passwd, deny) = render(&accounts);
        assert_eq!(
            passwd,
            format!("0000000000000000000000C1:{hash}\n6A1B2C3D4E5F60718293A4B5:{hash}\n")
        );
        assert_eq!(deny, "6A1B2C3D4E5F60718293A4B5\n");
        let dir = tempfile::tempdir().unwrap();
        write_files(dir.path(), &accounts).unwrap();
        assert_eq!(
            std::fs::read_to_string(dir.path().join(PASSWD_FILE)).unwrap(),
            passwd
        );
        assert!(dir.path().join(SERIAL_FILE).exists());
        use std::os::unix::fs::PermissionsExt;
        let mode = std::fs::metadata(dir.path().join(DENY_FILE))
            .unwrap()
            .permissions()
            .mode();
        assert_eq!(mode & 0o777, 0o640);
    }
}
