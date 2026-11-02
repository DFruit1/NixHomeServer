//! Local-only key provisioning. Immich's API cannot issue another user's key.
//! Only this root maintenance process touches the version-checked key table;
//! the web broker never receives database credentials or administrator tokens.
use media_manager::{config::Identity, provider_accounts::ProviderAccountStore};
use serde_json::json;
use std::{
    collections::BTreeMap,
    io::Write,
    path::PathBuf,
    process::{Command, Stdio},
};
use zeroize::{Zeroize, Zeroizing};

fn main() {
    if let Err(error) = run() {
        // Every error is a fixed local diagnostic; subprocess output and
        // credential-store errors are deliberately mapped before reaching here.
        eprintln!(
            "{}",
            json!({"service":"media-manager-immich-provision", "event":"reconciliation_failed", "error":error})
        );
        std::process::exit(1);
    }
}
fn env(name: &str) -> Result<String, String> {
    std::env::var(name).map_err(|_| format!("missing {name}"))
}
fn output(command: &mut Command, input: Option<&[u8]>) -> Result<Vec<u8>, String> {
    let mut child = command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|_| "provision subprocess failed")?;
    if let Some(input) = input {
        child
            .stdin
            .take()
            .ok_or("missing stdin")?
            .write_all(input)
            .map_err(|_| "provision input failed")?;
    }
    let result = child
        .wait_with_output()
        .map_err(|_| "provision subprocess failed")?;
    if !result.status.success() || result.stdout.len() > 1024 * 1024 {
        return Err("provision subprocess failed".into());
    }
    Ok(result.stdout)
}
fn uuid(value: &str) -> bool {
    value.len() == 36
        && value.bytes().enumerate().all(|(i, b)| {
            if [8, 13, 18, 23].contains(&i) {
                b == b'-'
            } else {
                b.is_ascii_hexdigit()
            }
        })
}
fn sql(value: &str) -> String {
    format!(
        "convert_from(decode('{}','hex'),'UTF8')",
        value
            .bytes()
            .map(|b| format!("{b:02x}"))
            .collect::<String>()
    )
}
fn database(query: &str) -> Result<String, String> {
    let mut command = Command::new(env("IMMICH_PROVISION_RUNUSER")?);
    command.args([
        "-u",
        &env("IMMICH_PROVISION_DB_USER")?,
        "--",
        &env("IMMICH_PROVISION_PSQL")?,
        "--no-psqlrc",
        "-qAt",
        "--set",
        "ON_ERROR_STOP=1",
        "--dbname",
        &env("IMMICH_PROVISION_DB")?,
    ]);
    String::from_utf8(output(&mut command, Some(query.as_bytes()))?)
        .map_err(|_| "invalid database output".into())
}
fn credential(username: &str, subject: &str) -> Result<(), String> {
    let identity = Identity::try_new_with_subject(subject, username, std::iter::empty::<&str>())?;
    let root = PathBuf::from(env("MEDIA_MANAGER_PROVIDER_STATE_DIR")?);
    let store = ProviderAccountStore::open(
        &root.join("provider-accounts.sqlite3"),
        &root.join("master.key"),
    )
    .map_err(|_| "provider store unavailable")?;
    let saved = store
        .load_credentials(&identity, "immich-managed")
        .map_err(|_| "provider store unavailable")?;
    let secret = Zeroizing::new(match saved.and_then(|mut c| c.remove("apiKey")) {
        Some(key) if !key.is_empty() => key,
        _ => {
            let secret = homelab_common::random_hex(32);
            let mut credentials = BTreeMap::from([("apiKey".to_string(), secret.clone())]);
            let saved = store.save(
                &identity,
                "immich-managed",
                &credentials,
                media_manager::transcription::worker::now() as i64,
            );
            for value in credentials.values_mut() {
                value.zeroize();
            }
            saved.map_err(|_| "provider save failed")?;
            secret
        }
    });
    // This mode is only a private pipe to the root parent, never a service's
    // journal or a web response. The encrypted save precedes the key-table write
    // so a crash can resume with the same secret rather than orphaning a key.
    std::io::stdout()
        .write_all(secret.as_bytes())
        .map_err(|_| "credential pipe failed".into())
}
fn run() -> Result<(), String> {
    let args: Vec<_> = std::env::args().collect();
    if args.get(1).is_some_and(|a| a == "--credential") {
        if args.len() != 4 {
            return Err("invalid credential command".into());
        }
        return credential(&args[2], &args[3]);
    }
    if unsafe { libc::geteuid() } != 0 {
        return Err("root provisioner required".into());
    }
    if !env("IMMICH_PROVISION_VERSION")?.starts_with("3.") {
        return Err("unsupported Immich key schema".into());
    }
    let preferred_users: Vec<String> = serde_json::from_str(&env("IMMICH_PROVISION_USERS_JSON")?)
        .map_err(|_| "invalid user list")?;
    let subjects: Vec<String> = serde_json::from_str(&database("select coalesce(json_agg(\"oauthId\"), '[]'::json) from \"user\" where \"deletedAt\" is null and length(\"oauthId\") > 0;")?).map_err(|_| "invalid Immich identity snapshot")?;
    if subjects.len() > 10000 {
        return Err("identity snapshot exceeds limit".into());
    }
    let mut seen = std::collections::BTreeSet::new();
    let mut mappings = Vec::new();
    for subject in subjects.into_iter().filter(|subject| uuid(subject)) {
        if !seen.insert(subject.clone()) {
            return Err("ambiguous Immich identity".into());
        }
        // SQLite has no decode()/convert_from(). Build an explicit hex literal.
        let hex: String = subject.bytes().map(|b| format!("{b:02x}")).collect();
        let mut command = Command::new(env("IMMICH_PROVISION_SQLITE")?);
        command.args([
            "-readonly",
            "-json",
            "/var/lib/kanidm/kanidm.db",
            &format!("select name from idx_name2uuid where uuid = cast(X'{hex}' as text);"),
        ]);
        let snapshot = String::from_utf8(output(&mut command, None)?)
            .map_err(|_| "invalid identity mapping")?
            .trim()
            .to_string();
        let rows: Vec<serde_json::Value> = if snapshot.is_empty() {
            Vec::new()
        } else {
            serde_json::from_str(&snapshot).map_err(|_| "invalid Kanidm identity snapshot")?
        };
        let names: Vec<String> = rows
            .iter()
            .filter_map(|r| r["name"].as_str())
            .filter(|name| media_manager::transcription::worker::valid_user(name))
            .map(str::to_string)
            .collect();
        let username = match names.as_slice() {
            [] => continue, // Deleted/unlinked identity; never guess by email.
            [name] => name.clone(),
            _ => {
                let preferred: Vec<_> = names
                    .iter()
                    .filter(|name| preferred_users.contains(name))
                    .collect();
                if preferred.len() != 1 {
                    return Err("ambiguous Kanidm identity".into());
                }
                preferred[0].clone()
            }
        };
        mappings.push((username, subject));
    }
    for (username, subject) in mappings {
        let mut command = Command::new(env("IMMICH_PROVISION_RUNUSER")?);
        command
            .args(["-u", "media-manager-provider", "--"])
            .arg(std::env::current_exe().map_err(|_| "missing executable")?)
            .args(["--credential", &username, &subject]);
        let secret = Zeroizing::new(output(&mut command, None)?);
        if secret.len() != 64 || !secret.iter().all(u8::is_ascii_hexdigit) {
            return Err("invalid managed key".into());
        }
        let hash = homelab_common::sha256_hex(&secret);
        let digest =
            homelab_common::sha256_hex(format!("media-manager:immich:{subject}").as_bytes());
        let id = format!(
            "{}-{}-4{}-8{}-{}",
            &digest[..8],
            &digest[8..12],
            &digest[13..16],
            &digest[17..20],
            &digest[20..32]
        );
        let unchanged = database(&format!("select count(*) from api_key k join \"user\" u on u.id=k.\"userId\" where k.id='{id}' and k.name='NixHomeServer Media Manager' and u.\"oauthId\"={} and u.\"deletedAt\" is null and k.key=decode('{hash}','hex') and k.permissions=ARRAY['asset.read','asset.view','user.read','tag.read','tag.create','tag.asset']::varchar[];", sql(&subject)))?;
        if unchanged.trim() == "1" {
            continue;
        }
        // bytea and permissions follow Immich 3.x's pinned ApiKeyTable schema.
        // A deterministic ID permits idempotent repair without rotating keys or
        // overwriting a human-managed key with the same display name.
        let query = format!("begin; set local lock_timeout='5s'; set local statement_timeout='15s'; insert into api_key (id,name,key,\"userId\",permissions) select '{id}','NixHomeServer Media Manager',decode('{hash}','hex'),id,ARRAY['asset.read','asset.view','user.read','tag.read','tag.create','tag.asset']::varchar[] from \"user\" where \"oauthId\"={} and \"deletedAt\" is null on conflict(id) do update set key=excluded.key, permissions=excluded.permissions where api_key.\"userId\"=excluded.\"userId\" and api_key.name=excluded.name returning id; commit;", sql(&subject));
        if database(&query)?.trim() != id {
            return Err("managed key ownership mismatch".into());
        }
    }
    println!("{}", json!({"event":"immich_provider_accounts_reconciled"}));
    Ok(())
}
