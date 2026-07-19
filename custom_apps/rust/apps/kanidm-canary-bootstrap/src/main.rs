use data_encoding::BASE32_NOPAD;
use hmac::{Hmac, Mac};
use kanidm_client::{KanidmClient, KanidmClientBuilder};
use kanidm_proto::internal::{CURegState, TotpAlgo};
use sha2::Sha256;
use std::env;
use std::error::Error;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{OpenOptionsExt, PermissionsExt};
use std::path::{Path, PathBuf};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

type Result<T> = std::result::Result<T, Box<dyn Error + Send + Sync>>;

#[derive(Debug)]
struct Settings {
    kanidm_url: String,
    canary_username: String,
    admin_username: String,
    admin_password_path: PathBuf,
    canary_password_path: PathBuf,
    seed_path: PathBuf,
}

impl Settings {
    fn from_env() -> Result<Self> {
        let credentials_dir = required_env("CREDENTIALS_DIRECTORY")?;
        Ok(Self {
            kanidm_url: required_env("KANIDM_URL")?,
            canary_username: required_env("CANARY_USERNAME")?,
            admin_username: env::var("KANIDM_ADMIN_USERNAME")
                .unwrap_or_else(|_| "idm_admin".to_string()),
            admin_password_path: Path::new(&credentials_dir).join("idm-admin-password"),
            canary_password_path: Path::new(&credentials_dir).join("canary-password"),
            seed_path: PathBuf::from(required_env("CANARY_TOTP_SEED_FILE")?),
        })
    }
}

fn required_env(name: &str) -> Result<String> {
    env::var(name).map_err(|_| io::Error::other(format!("{name} is required")).into())
}

fn read_secret(path: &Path) -> Result<String> {
    let mut file = File::open(path)?;
    let mut value = String::new();
    file.read_to_string(&mut value)?;
    let value = value.trim().to_string();
    if value.is_empty() {
        return Err(io::Error::other(format!("{} is empty", path.display())).into());
    }
    Ok(value)
}

fn current_unix_seconds() -> Result<u64> {
    Ok(SystemTime::now().duration_since(UNIX_EPOCH)?.as_secs())
}

fn totp_sha256(secret: &[u8], timestamp: u64, step: u64, digits: u8) -> Result<u32> {
    if step == 0 || !(6..=8).contains(&digits) {
        return Err(io::Error::other("unsupported TOTP parameters").into());
    }
    let counter = (timestamp / step).to_be_bytes();
    let mut mac = Hmac::<Sha256>::new_from_slice(secret)
        .map_err(|_| io::Error::other("invalid TOTP key length"))?;
    mac.update(&counter);
    let digest = mac.finalize().into_bytes();
    let offset = usize::from(digest[digest.len() - 1] & 0x0f);
    if offset + 4 > digest.len() {
        return Err(io::Error::other("invalid TOTP digest offset").into());
    }
    let binary = (u32::from(digest[offset] & 0x7f) << 24)
        | (u32::from(digest[offset + 1]) << 16)
        | (u32::from(digest[offset + 2]) << 8)
        | u32::from(digest[offset + 3]);
    Ok(binary % 10_u32.pow(u32::from(digits)))
}

async fn stable_totp(secret: &[u8], step: u64, digits: u8) -> Result<u32> {
    let mut now = current_unix_seconds()?;
    let seconds_remaining = step - (now % step);
    if seconds_remaining <= 2 {
        tokio::time::sleep(Duration::from_secs(seconds_remaining + 1)).await;
        now = current_unix_seconds()?;
    }
    totp_sha256(secret, now, step, digits)
}

fn decode_seed(seed: &str) -> Result<Vec<u8>> {
    BASE32_NOPAD
        .decode(seed.trim().to_ascii_uppercase().as_bytes())
        .map_err(|_| io::Error::other("persisted TOTP seed is not valid base32").into())
}

fn client(url: &str) -> Result<KanidmClient> {
    KanidmClientBuilder::new()
        .address(url.to_string())
        .connect_timeout(10)
        .request_timeout(30)
        .no_proxy()
        .build()
        .map_err(|error| {
            io::Error::other(format!("failed to build Kanidm client: {error:?}")).into()
        })
}

fn kanidm_error(context: &str, error: impl std::fmt::Debug) -> io::Error {
    io::Error::other(format!("{context}: {error:?}"))
}

async fn credentials_work(url: &str, username: &str, password: &str, seed: &str) -> bool {
    let secret = match decode_seed(seed) {
        Ok(secret) => secret,
        Err(_) => return false,
    };
    let code = match stable_totp(&secret, 30, 6).await {
        Ok(code) => code,
        Err(_) => return false,
    };
    match client(url) {
        Ok(client) => {
            let authenticated = client
                .auth_password_totp(username, password, code)
                .await
                .is_ok();
            if authenticated {
                let _ = client.logout().await;
            }
            authenticated
        }
        Err(_) => false,
    }
}

fn write_secret_atomic(path: &Path, value: &str) -> Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("TOTP seed path has no parent"))?;
    fs::create_dir_all(parent)?;
    fs::set_permissions(parent, fs::Permissions::from_mode(0o700))?;
    let temporary = path.with_extension(format!("tmp-{}", std::process::id()));
    let mut file = OpenOptions::new()
        .create(true)
        .truncate(true)
        .write(true)
        .mode(0o400)
        .open(&temporary)?;
    file.write_all(value.as_bytes())?;
    file.write_all(b"\n")?;
    file.sync_all()?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o400))?;
    fs::rename(&temporary, path)?;
    File::open(parent)?.sync_all()?;
    Ok(())
}

async fn use_existing_state(settings: &Settings, password: &str) -> Result<bool> {
    let pending_path = settings.seed_path.with_extension("pending");
    for candidate in [&settings.seed_path, &pending_path] {
        let Ok(seed) = read_secret(candidate) else {
            continue;
        };
        if credentials_work(
            &settings.kanidm_url,
            &settings.canary_username,
            password,
            &seed,
        )
        .await
        {
            if candidate == &pending_path {
                write_secret_atomic(&settings.seed_path, &seed)?;
            }
            if pending_path.exists() {
                fs::remove_file(&pending_path)?;
            }
            return Ok(true);
        }
    }
    Ok(false)
}

async fn provision(settings: &Settings, admin_password: &str, canary_password: &str) -> Result<()> {
    let admin_client = client(&settings.kanidm_url)?;
    admin_client
        .auth_simple_password(&settings.admin_username, admin_password)
        .await
        .map_err(|error| kanidm_error("failed to authenticate Kanidm administrator", error))?;

    let (session, _) = admin_client
        .idm_account_credential_update_begin(&settings.canary_username)
        .await
        .map_err(|error| kanidm_error("failed to begin canary credential update", error))?;
    admin_client
        .idm_account_credential_update_set_password(&session, canary_password)
        .await
        .map_err(|error| kanidm_error("failed to set canary password", error))?;
    let status = admin_client
        .idm_account_credential_update_init_totp(&session)
        .await
        .map_err(|error| kanidm_error("failed to initialize canary TOTP", error))?;
    let totp = match status.mfaregstate {
        CURegState::TotpCheck(secret) => secret,
        state => {
            return Err(io::Error::other(format!(
                "Kanidm returned unexpected TOTP registration state: {state:?}"
            ))
            .into())
        }
    };
    if !matches!(totp.algo, TotpAlgo::Sha256) || totp.step != 30 || totp.digits != 6 {
        return Err(io::Error::other(format!(
            "Kanidm returned unsupported TOTP parameters: algorithm={} period={} digits={}",
            totp.algo, totp.step, totp.digits
        ))
        .into());
    }
    let code = stable_totp(&totp.secret, totp.step, totp.digits).await?;
    admin_client
        .idm_account_credential_update_check_totp(&session, code, "homepage-canary")
        .await
        .map_err(|error| kanidm_error("failed to verify canary TOTP", error))?;

    let seed = totp.get_secret();
    let pending_path = settings.seed_path.with_extension("pending");
    write_secret_atomic(&pending_path, &seed)?;
    admin_client
        .idm_account_credential_update_commit(&session)
        .await
        .map_err(|error| kanidm_error("failed to commit canary credentials", error))?;

    if !credentials_work(
        &settings.kanidm_url,
        &settings.canary_username,
        canary_password,
        &seed,
    )
    .await
    {
        return Err(io::Error::other("new canary credentials failed verification").into());
    }
    write_secret_atomic(&settings.seed_path, &seed)?;
    fs::remove_file(pending_path)?;
    let _ = admin_client.logout().await;
    Ok(())
}

#[tokio::main]
async fn main() -> Result<()> {
    let settings = Settings::from_env()?;
    let canary_password = read_secret(&settings.canary_password_path)?;

    if use_existing_state(&settings, &canary_password).await? {
        println!("Kanidm canary credentials are provisioned and verified.");
        return Ok(());
    }

    let admin_password = read_secret(&settings.admin_password_path)?;
    provision(&settings, &admin_password, &canary_password).await?;
    println!("Kanidm canary credentials were provisioned and verified.");
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn generates_rfc_sha256_totp() {
        let secret = b"12345678901234567890123456789012";
        assert_eq!(totp_sha256(secret, 59, 30, 8).unwrap(), 46_119_246);
    }

    #[test]
    fn atomically_writes_private_seed() {
        let directory = tempfile::tempdir().unwrap();
        let path = directory.path().join("totp-seed");
        write_secret_atomic(&path, "JBSWY3DPEHPK3PXP").unwrap();
        assert_eq!(read_secret(&path).unwrap(), "JBSWY3DPEHPK3PXP");
        assert_eq!(
            fs::metadata(path).unwrap().permissions().mode() & 0o777,
            0o400
        );
    }

    #[test]
    fn rejects_invalid_seed() {
        assert!(decode_seed("not-a-seed").is_err());
    }
}
