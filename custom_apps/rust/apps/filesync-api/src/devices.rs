//! Long-lived per-device sync keys.
//!
//! Kanidm ties every OAuth2 refresh session to the browser login that created
//! it, so a native client cannot stay signed in past the account policy's
//! auth-session expiry. File Sync instead exchanges a fresh Kanidm access token
//! for one random device key per installation. The key authorizes the same
//! per-user library access as a Kanidm token, never expires, and is revoked
//! when the device signs out (or by removing its entry from the store file and
//! restarting the service). Issuing a key always requires a Kanidm token.
//!
//! Only SHA-256 digests of keys are stored; the plaintext key exists on the
//! device alone.

use base64::{engine::general_purpose::URL_SAFE_NO_PAD, Engine};
use rand::{rngs::OsRng, RngCore};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::{
    collections::HashMap,
    io,
    path::{Path, PathBuf},
};
use tokio::sync::RwLock;
use uuid::Uuid;

/// Distinguishes device keys from Kanidm JWT access tokens, which always start
/// with a base64url JOSE header (`eyJ`).
pub const TOKEN_PREFIX: &str = "fsd1_";

/// Oldest keys beyond this per-account count are dropped when a new one is
/// issued, so repeated reinstalls cannot grow the store without bound.
const MAX_DEVICES_PER_USER: usize = 16;

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct DeviceRecord {
    pub id: String,
    pub username: String,
    pub label: String,
    pub created_unix: u64,
}

#[derive(Default, Serialize, Deserialize)]
struct StoreFile {
    /// Keyed by the hex SHA-256 digest of the device key.
    devices: HashMap<String, DeviceRecord>,
}

pub struct DeviceStore {
    path: PathBuf,
    devices: RwLock<HashMap<String, DeviceRecord>>,
}

fn digest(token: &str) -> String {
    format!("{:x}", Sha256::digest(token.as_bytes()))
}

impl DeviceStore {
    pub fn load(path: PathBuf) -> io::Result<Self> {
        let devices = match std::fs::read(&path) {
            Ok(bytes) => {
                serde_json::from_slice::<StoreFile>(&bytes)
                    .map_err(|error| {
                        io::Error::other(format!("{} is invalid: {error}", path.display()))
                    })?
                    .devices
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => HashMap::new(),
            Err(error) => return Err(error),
        };
        Ok(Self {
            path,
            devices: RwLock::new(devices),
        })
    }

    pub async fn lookup(&self, token: &str) -> Option<DeviceRecord> {
        if !token.starts_with(TOKEN_PREFIX) {
            return None;
        }
        self.devices.read().await.get(&digest(token)).cloned()
    }

    pub async fn issue(
        &self,
        username: &str,
        label: &str,
        now: u64,
    ) -> io::Result<(DeviceRecord, String)> {
        let mut secret = [0_u8; 32];
        OsRng.fill_bytes(&mut secret);
        let token = format!("{TOKEN_PREFIX}{}", URL_SAFE_NO_PAD.encode(secret));
        let record = DeviceRecord {
            id: Uuid::new_v4().to_string(),
            username: username.to_owned(),
            label: label.to_owned(),
            created_unix: now,
        };
        let mut devices = self.devices.write().await;
        let mut next = devices.clone();
        next.insert(digest(&token), record.clone());
        prune_user(&mut next, username);
        persist(&self.path, &next).await?;
        *devices = next;
        Ok((record, token))
    }

    /// Remove the key. Returns whether it existed.
    pub async fn revoke(&self, token: &str) -> io::Result<bool> {
        let mut devices = self.devices.write().await;
        let key = digest(token);
        if !devices.contains_key(&key) {
            return Ok(false);
        }
        let mut next = devices.clone();
        next.remove(&key);
        persist(&self.path, &next).await?;
        *devices = next;
        Ok(true)
    }
}

fn prune_user(devices: &mut HashMap<String, DeviceRecord>, username: &str) {
    let mut owned: Vec<(u64, String, String)> = devices
        .iter()
        .filter(|(_, record)| record.username == username)
        .map(|(key, record)| (record.created_unix, record.id.clone(), key.clone()))
        .collect();
    if owned.len() <= MAX_DEVICES_PER_USER {
        return;
    }
    owned.sort();
    let excess = owned.len() - MAX_DEVICES_PER_USER;
    for (_, _, key) in owned.into_iter().take(excess) {
        devices.remove(&key);
    }
}

/// Write the store atomically so a crash never leaves a truncated file that
/// would revoke every device at the next start.
async fn persist(path: &Path, devices: &HashMap<String, DeviceRecord>) -> io::Result<()> {
    let body = serde_json::to_vec_pretty(&StoreFile {
        devices: devices.clone(),
    })
    .map_err(io::Error::other)?;
    let staging = path.with_extension("json.tmp");
    let mut file = tokio::fs::OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .mode(0o600)
        .open(&staging)
        .await?;
    tokio::io::AsyncWriteExt::write_all(&mut file, &body).await?;
    file.sync_all().await?;
    drop(file);
    tokio::fs::rename(&staging, path).await
}

#[cfg(test)]
mod tests {
    use super::*;

    fn store() -> (tempfile::TempDir, DeviceStore) {
        let dir = tempfile::tempdir().unwrap();
        let store = DeviceStore::load(dir.path().join("devices.json")).unwrap();
        (dir, store)
    }

    #[tokio::test]
    async fn issued_keys_survive_a_restart_and_stop_working_once_revoked() {
        let (dir, store) = store();
        let (record, token) = store.issue("alice", "Pixel", 10).await.unwrap();
        assert!(token.starts_with(TOKEN_PREFIX));
        let reloaded = DeviceStore::load(dir.path().join("devices.json")).unwrap();
        assert_eq!(reloaded.lookup(&token).await.unwrap().id, record.id);
        let raw = std::fs::read_to_string(dir.path().join("devices.json")).unwrap();
        assert!(
            !raw.contains(&token[TOKEN_PREFIX.len()..]),
            "plaintext key stored"
        );
        assert!(reloaded.revoke(&token).await.unwrap());
        assert!(reloaded.lookup(&token).await.is_none());
        assert!(DeviceStore::load(dir.path().join("devices.json"))
            .unwrap()
            .lookup(&token)
            .await
            .is_none());
    }

    #[tokio::test]
    async fn jwt_shaped_and_unknown_tokens_are_not_device_keys() {
        let (_dir, store) = store();
        let (_, token) = store.issue("alice", "Pixel", 10).await.unwrap();
        assert!(store.lookup("eyJhbGciOiJFUzI1NiJ9.e30.sig").await.is_none());
        assert!(store.lookup(&format!("{token}x")).await.is_none());
    }

    #[tokio::test]
    async fn the_oldest_keys_beyond_the_per_user_limit_are_dropped() {
        let (_dir, store) = store();
        let (_, first) = store.issue("alice", "old", 1).await.unwrap();
        let (_, other_user) = store.issue("bob", "bob", 1).await.unwrap();
        for created in 2..=(MAX_DEVICES_PER_USER as u64 + 1) {
            store.issue("alice", "new", created).await.unwrap();
        }
        assert!(store.lookup(&first).await.is_none());
        assert!(store.lookup(&other_user).await.is_some());
    }
}
