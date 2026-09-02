use crate::config::Identity;
use chacha20poly1305::{
    aead::{Aead, AeadCore, KeyInit, OsRng, Payload},
    Key, XChaCha20Poly1305, XNonce,
};
use rusqlite::{params, Connection, OptionalExtension};
use serde::Serialize;
use std::{
    collections::BTreeMap,
    fs::{File, OpenOptions},
    io::{ErrorKind, Read, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
};

const SCHEMA_VERSION: i64 = 1;
const MASTER_KEY_BYTES: usize = 32;
const AAD_DOMAIN: &[u8] = b"media-manager-provider-account:v1";

pub type ProviderCredentials = BTreeMap<String, String>;

#[derive(Clone, Debug, Eq, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct ProviderAccountSummary {
    pub provider_id: String,
    pub owner_username: String,
    pub configured_at: i64,
    pub updated_at: i64,
    pub last_tested_at: Option<i64>,
    pub last_test_status: Option<String>,
    pub last_test_message: Option<String>,
}

pub struct ProviderAccountStore {
    database_path: PathBuf,
    master_key: [u8; MASTER_KEY_BYTES],
}

impl ProviderAccountStore {
    pub fn open(database_path: &Path, master_key_path: &Path) -> Result<Self, ProviderAccountError> {
        let master_key = load_or_create_master_key(master_key_path)?;
        let store = Self {
            database_path: database_path.to_path_buf(),
            master_key,
        };
        store.initialize()?;
        Ok(store)
    }

    pub fn save(
        &self,
        identity: &Identity,
        provider_id: &str,
        credentials: &ProviderCredentials,
        now: i64,
    ) -> Result<(), ProviderAccountError> {
        validate_provider_id(provider_id)?;
        let plaintext = serde_json::to_vec(credentials)
            .map_err(|error| ProviderAccountError::Storage(error.to_string()))?;
        let cipher = XChaCha20Poly1305::new(Key::from_slice(&self.master_key));
        let nonce = XChaCha20Poly1305::generate_nonce(&mut OsRng);
        let aad = associated_data(&identity.subject, provider_id);
        let ciphertext = cipher
            .encrypt(
                &nonce,
                Payload {
                    msg: &plaintext,
                    aad: &aad,
                },
            )
            .map_err(|_| ProviderAccountError::Encrypt)?;
        let connection = self.connection()?;
        connection
            .execute(
                "INSERT INTO provider_accounts
                 (owner_subject, provider_id, owner_username, ciphertext, nonce,
                  configured_at, updated_at, last_tested_at, last_test_status, last_test_message)
                 VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?6, NULL, NULL, NULL)
                 ON CONFLICT(owner_subject, provider_id) DO UPDATE SET
                   owner_username = excluded.owner_username,
                   ciphertext = excluded.ciphertext,
                   nonce = excluded.nonce,
                   updated_at = excluded.updated_at,
                   last_tested_at = NULL,
                   last_test_status = NULL,
                   last_test_message = NULL",
                params![
                    identity.subject,
                    provider_id,
                    identity.username,
                    ciphertext,
                    nonce.as_slice(),
                    now,
                ],
            )
            .map_err(storage_error)?;
        Ok(())
    }

    pub fn load_credentials(
        &self,
        identity: &Identity,
        provider_id: &str,
    ) -> Result<Option<ProviderCredentials>, ProviderAccountError> {
        validate_provider_id(provider_id)?;
        let connection = self.connection()?;
        let encrypted = connection
            .query_row(
                "SELECT ciphertext, nonce FROM provider_accounts
                 WHERE owner_subject = ?1 AND provider_id = ?2",
                params![identity.subject, provider_id],
                |row| Ok((row.get::<_, Vec<u8>>(0)?, row.get::<_, Vec<u8>>(1)?)),
            )
            .optional()
            .map_err(storage_error)?;
        let Some((ciphertext, nonce)) = encrypted else {
            return Ok(None);
        };
        if nonce.len() != 24 {
            return Err(ProviderAccountError::Decrypt);
        }
        let cipher = XChaCha20Poly1305::new(Key::from_slice(&self.master_key));
        let aad = associated_data(&identity.subject, provider_id);
        let plaintext = cipher
            .decrypt(
                XNonce::from_slice(&nonce),
                Payload {
                    msg: &ciphertext,
                    aad: &aad,
                },
            )
            .map_err(|_| ProviderAccountError::Decrypt)?;
        serde_json::from_slice(&plaintext)
            .map(Some)
            .map_err(|_| ProviderAccountError::Decrypt)
    }

    pub fn list(
        &self,
        identity: &Identity,
    ) -> Result<Vec<ProviderAccountSummary>, ProviderAccountError> {
        let connection = self.connection()?;
        let mut statement = connection
            .prepare(
                "SELECT provider_id, owner_username, configured_at, updated_at,
                        last_tested_at, last_test_status, last_test_message
                 FROM provider_accounts WHERE owner_subject = ?1
                 ORDER BY provider_id",
            )
            .map_err(storage_error)?;
        let rows = statement
            .query_map(params![identity.subject], |row| {
                Ok(ProviderAccountSummary {
                    provider_id: row.get(0)?,
                    owner_username: row.get(1)?,
                    configured_at: row.get(2)?,
                    updated_at: row.get(3)?,
                    last_tested_at: row.get(4)?,
                    last_test_status: row.get(5)?,
                    last_test_message: row.get(6)?,
                })
            })
            .map_err(storage_error)?;
        rows.collect::<Result<Vec<_>, _>>().map_err(storage_error)
    }

    pub fn delete(
        &self,
        identity: &Identity,
        provider_id: &str,
    ) -> Result<bool, ProviderAccountError> {
        validate_provider_id(provider_id)?;
        let connection = self.connection()?;
        connection
            .execute(
                "DELETE FROM provider_accounts WHERE owner_subject = ?1 AND provider_id = ?2",
                params![identity.subject, provider_id],
            )
            .map(|deleted| deleted == 1)
            .map_err(storage_error)
    }

    pub fn record_test_result(
        &self,
        identity: &Identity,
        provider_id: &str,
        status: &str,
        message: &str,
        now: i64,
    ) -> Result<bool, ProviderAccountError> {
        validate_provider_id(provider_id)?;
        let connection = self.connection()?;
        connection
            .execute(
                "UPDATE provider_accounts
                 SET owner_username = ?3, last_tested_at = ?4,
                     last_test_status = ?5, last_test_message = ?6
                 WHERE owner_subject = ?1 AND provider_id = ?2",
                params![
                    identity.subject,
                    provider_id,
                    identity.username,
                    now,
                    status,
                    message,
                ],
            )
            .map(|updated| updated == 1)
            .map_err(storage_error)
    }

    fn initialize(&self) -> Result<(), ProviderAccountError> {
        let connection = self.connection()?;
        connection
            .execute_batch(
                "PRAGMA journal_mode = WAL;
                 PRAGMA synchronous = FULL;
                 PRAGMA foreign_keys = ON;
                 CREATE TABLE IF NOT EXISTS provider_accounts (
                   owner_subject TEXT NOT NULL,
                   provider_id TEXT NOT NULL,
                   owner_username TEXT NOT NULL,
                   ciphertext BLOB NOT NULL,
                   nonce BLOB NOT NULL,
                   configured_at INTEGER NOT NULL,
                   updated_at INTEGER NOT NULL,
                   last_tested_at INTEGER,
                   last_test_status TEXT,
                   last_test_message TEXT,
                   PRIMARY KEY (owner_subject, provider_id)
                 );",
            )
            .map_err(storage_error)?;
        connection
            .pragma_update(None, "user_version", SCHEMA_VERSION)
            .map_err(storage_error)
    }

    fn connection(&self) -> Result<Connection, ProviderAccountError> {
        let connection = Connection::open(&self.database_path).map_err(storage_error)?;
        connection
            .busy_timeout(std::time::Duration::from_secs(5))
            .map_err(storage_error)?;
        Ok(connection)
    }
}

fn load_or_create_master_key(path: &Path) -> Result<[u8; MASTER_KEY_BYTES], ProviderAccountError> {
    match open_master_key(path) {
        Ok(file) => read_master_key(file),
        Err(error) if error.kind() == ErrorKind::NotFound => {
            let mut key = [0_u8; MASTER_KEY_BYTES];
            use rand::RngCore;
            OsRng.fill_bytes(&mut key);
            match OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o600)
                .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
                .open(path)
            {
                Ok(mut file) => {
                    file.write_all(&key).map_err(io_error)?;
                    file.sync_all().map_err(io_error)?;
                    Ok(key)
                }
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                    read_master_key(open_master_key(path).map_err(io_error)?)
                }
                Err(error) => Err(io_error(error)),
            }
        }
        Err(error) => Err(io_error(error)),
    }
}

fn open_master_key(path: &Path) -> std::io::Result<File> {
    OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
}

fn read_master_key(mut file: File) -> Result<[u8; MASTER_KEY_BYTES], ProviderAccountError> {
    let metadata = file.metadata().map_err(io_error)?;
    if !metadata.is_file() || metadata.len() != MASTER_KEY_BYTES as u64 {
        return Err(ProviderAccountError::InvalidMasterKey);
    }
    let mut key = [0_u8; MASTER_KEY_BYTES];
    file.read_exact(&mut key).map_err(io_error)?;
    Ok(key)
}

fn associated_data(subject: &str, provider_id: &str) -> Vec<u8> {
    let mut aad = Vec::with_capacity(AAD_DOMAIN.len() + subject.len() + provider_id.len() + 2);
    aad.extend_from_slice(AAD_DOMAIN);
    aad.push(0);
    aad.extend_from_slice(subject.as_bytes());
    aad.push(0);
    aad.extend_from_slice(provider_id.as_bytes());
    aad
}

fn validate_provider_id(provider_id: &str) -> Result<(), ProviderAccountError> {
    if !provider_id.is_empty()
        && provider_id.len() <= 64
        && provider_id
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-')
    {
        Ok(())
    } else {
        Err(ProviderAccountError::InvalidProviderId)
    }
}

fn storage_error(error: rusqlite::Error) -> ProviderAccountError {
    ProviderAccountError::Storage(error.to_string())
}

fn io_error(error: std::io::Error) -> ProviderAccountError {
    ProviderAccountError::Storage(error.to_string())
}

#[derive(Debug, Eq, PartialEq)]
pub enum ProviderAccountError {
    InvalidProviderId,
    InvalidMasterKey,
    Encrypt,
    Decrypt,
    Storage(String),
}

impl std::fmt::Display for ProviderAccountError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidProviderId => formatter.write_str("invalid provider ID"),
            Self::InvalidMasterKey => formatter.write_str("provider master key is invalid"),
            Self::Encrypt => formatter.write_str("credential encryption failed"),
            Self::Decrypt => formatter.write_str("credential decryption failed"),
            Self::Storage(error) => write!(formatter, "provider account storage failed: {error}"),
        }
    }
}

impl std::error::Error for ProviderAccountError {}
