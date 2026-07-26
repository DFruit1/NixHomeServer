use super::*;
use std::sync::{Mutex, OnceLock};
use tempfile::TempDir;

static ENV_LOCK: OnceLock<Mutex<()>> = OnceLock::new();

fn env_lock() -> &'static Mutex<()> {
    ENV_LOCK.get_or_init(|| Mutex::new(()))
}

fn with_env_var<F, R>(key: &str, value: &str, test: F) -> R
where
    F: FnOnce() -> R,
{
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let previous = env::var_os(key);
    env::set_var(key, value);
    let result = test();
    if let Some(previous) = previous {
        env::set_var(key, previous);
    } else {
        env::remove_var(key);
    }
    result
}

fn test_config(tempdir: &TempDir) -> AppConfig {
    let data_dir = tempdir.path().join("data");
    let store_root = tempdir.path().join("store");
    let account_state_root = data_dir.join("accounts");
    let runtime_dir = tempdir.path().join("runtime");
    let lock_dir = tempdir.path().join("locks");

    AppConfig {
        address: Arc::<str>::from("127.0.0.1"),
        port: 9011,
        data_dir: Arc::<str>::from(data_dir.to_string_lossy().to_string()),
        store_root: Arc::<str>::from(store_root.to_string_lossy().to_string()),
        account_state_root: Arc::<str>::from(account_state_root.to_string_lossy().to_string()),
        runtime_dir: Arc::<str>::from(runtime_dir.to_string_lossy().to_string()),
        lock_dir: Arc::<str>::from(lock_dir.to_string_lossy().to_string()),
        paperless_consume_root: None,
        paperless_handoff_staging_root: None,
        paperless_database_path: None,
        visible_mirror_read_group: None,
        default_tags: Arc::from(vec!["new".to_string()]),
        frontend_dist_dir: Arc::<str>::from(
            tempdir
                .path()
                .join("frontend-dist")
                .to_string_lossy()
                .to_string(),
        ),
    }
}

fn prepare_test_layout(config: &AppConfig) {
    ensure_app_layout(config).expect("layout");
    fs::create_dir_all(config.store_root.as_ref()).expect("store root");
    initialize_db(config).expect("db");
}

#[test]
fn landlock_roots_include_runtime_store_and_account_paths() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);

    let (read_only, read_write) = landlock_roots(&config);

    assert!(read_only.contains(&PathBuf::from("/nix/store")));
    assert!(read_only.contains(&PathBuf::from("/etc")));
    assert!(read_write.contains(&PathBuf::from(config.data_dir.as_ref())));
    assert!(read_write.contains(&PathBuf::from(config.store_root.as_ref())));
    assert!(read_write.contains(&PathBuf::from(config.account_state_root.as_ref())));
    assert!(read_write.contains(&PathBuf::from(config.runtime_dir.as_ref())));
    assert!(read_write.contains(&PathBuf::from(config.lock_dir.as_ref())));

    let mut config = config;
    config.paperless_handoff_staging_root = Some(Arc::from(
        tempdir
            .path()
            .join("handoff-staging")
            .to_string_lossy()
            .to_string(),
    ));
    let (_read_only, read_write) = landlock_roots(&config);
    assert!(read_write.contains(&PathBuf::from(
        config.paperless_handoff_staging_root.as_deref().unwrap()
    )));
}

fn example_account() -> AccountRecord {
    AccountRecord {
        id: 42,
        username: "alice".to_string(),
        provider_kind: "gmail".to_string(),
        display_name: "Personal Gmail".to_string(),
        imap_host: "imap.gmail.com".to_string(),
        imap_port: 993,
        imap_username: "alice@gmail.com".to_string(),
        folder_mode: "gmail_default".to_string(),
        folder_patterns_json: serde_json::to_string(&gmail_default_patterns()).expect("json"),
        encrypted_secret: "ignored".to_string(),
        sync_enabled: true,
        created_at: String::new(),
        updated_at: String::new(),
        last_sync_started_at: None,
        last_sync_finished_at: None,
        last_sync_status: None,
        last_sync_error: None,
        last_sync_phase: None,
        last_sync_code: None,
        last_sync_summary: None,
        last_sync_detail: None,
    }
}

fn sample_status_payload() -> AccountStatusPayload {
    AccountStatusPayload {
            id: 42,
            status_class: "error".to_string(),
            status_label: "sync failed".to_string(),
            index_label: "Indexed".to_string(),
            last_activity: "2026-04-25T21:37:55Z".to_string(),
            archived_message_count: 6_668,
            indexed_message_count: 6_668,
            pending_index_count: 0,
            index_coverage_percent: 100,
            archive_file_count: 8_002,
            overlap_file_count: 1_334,
            progress_note: "Search index is caught up with the archived messages."
                .to_string(),
            overlap_note: Some(
                "Archive contains 8002 physical message files representing 6668 logical messages because synced folders overlap.".to_string(),
            ),
            last_sync_error: Some("mbsync: authentication failed".to_string()),
            diagnostic_phase: Some("download".to_string()),
            diagnostic_code: Some("download_failed".to_string()),
            diagnostic_summary: Some(
                "Mailbox download failed before new mail could be indexed.".to_string(),
            ),
            diagnostic_detail: Some("mbsync: authentication failed".to_string()),
            diagnostic_impact: Some(
                "The sync did not reach the indexing step, so newly downloaded mail may still be missing."
                    .to_string(),
            ),
            recommended_action: Some(
                "Check the mailbox credentials, then use Sync Now again.".to_string(),
            ),
            progress_warning: None,
            progress_warning_detail: None,
            progress_warning_action: None,
        }
}

fn sample_identity() -> Identity {
    Identity {
        username: "alice".to_string(),
        email: Some("alice@example.com".to_string()),
    }
}

fn test_message_filters(query: &str) -> MessageSearchFilters {
    MessageSearchFilters {
        q: query.to_string(),
        ..Default::default()
    }
}

fn with_stubbed_path<F>(commands: &[(&str, &str)], test: F)
where
    F: FnOnce(PathBuf),
{
    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let tempdir = TempDir::new().expect("tempdir");
    let bin_dir = tempdir.path().join("bin");
    fs::create_dir_all(&bin_dir).expect("bin dir");
    let bash_path = find_command_path("bash")
        .or_else(|| env::var_os("SHELL").map(PathBuf::from))
        .expect("bash path");

    for (name, script_body) in commands {
        let path = bin_dir.join(name);
        let script = format!("#!{}\nset -eu\n{}", bash_path.display(), script_body);
        write_private_file(&path, script.as_bytes()).expect("write stub");
        let mut perms = fs::metadata(&path).expect("metadata").permissions();
        use std::os::unix::fs::PermissionsExt;
        perms.set_mode(0o755);
        fs::set_permissions(&path, perms).expect("chmod");
    }

    let original_path = env::var("PATH").unwrap_or_default();
    env::set_var("PATH", format!("{}:{}", bin_dir.display(), original_path));
    test(bin_dir);
    env::set_var("PATH", original_path);
}

fn seed_account(config: &AppConfig, username: &str, secret: &str) -> i64 {
    seed_account_with_flags(config, username, secret, true)
}

fn seed_account_with_flags(
    config: &AppConfig,
    username: &str,
    secret: &str,
    sync_enabled: bool,
) -> i64 {
    insert_account(
        config,
        username,
        ValidatedAccount {
            provider_kind: "gmail".to_string(),
            display_name: "Personal Gmail".to_string(),
            imap_host: "imap.gmail.com".to_string(),
            imap_port: 993,
            imap_username: "alice@gmail.com".to_string(),
            folder_mode: "gmail_default".to_string(),
            folder_patterns: gmail_default_patterns(),
            secret: Some(secret.to_string()),
            sync_enabled,
        },
    )
    .expect("insert account");

    let connection = open_db(config).expect("db");
    connection
        .query_row(
            "SELECT id FROM accounts WHERE username = ?1 ORDER BY id DESC LIMIT 1",
            params![username],
            |row| row.get(0),
        )
        .expect("account id")
}

fn read_account(config: &AppConfig, username: &str, account_id: i64) -> AccountRecord {
    load_account_for_user(config, username, account_id).expect("load account")
}

fn read_notmuch_config(config: &AppConfig, account: &AccountRecord) -> String {
    let paths = ensure_account_paths(config, account).expect("paths");
    ensure_notmuch_config(config, account, &paths).expect("config");
    fs::read_to_string(paths.notmuch_config).expect("notmuch config")
}

fn write_maildir_message(
    account_paths: &AccountPaths,
    relative_path: &str,
    contents: &str,
) -> PathBuf {
    let path = account_paths.maildir.join(relative_path);
    fs::create_dir_all(path.parent().expect("mail parent")).expect("maildir parent");
    write_private_file(&path, contents.as_bytes()).expect("mail message");
    path
}

fn count_attachment_catalog_rows(config: &AppConfig) -> i64 {
    let connection = open_db(config).expect("db");
    connection
        .query_row("SELECT COUNT(*) FROM attachment_catalog", [], |row| {
            row.get(0)
        })
        .expect("attachment catalog rows")
}

fn count_message_catalog_rows(config: &AppConfig) -> i64 {
    let connection = open_db(config).expect("db");
    connection
        .query_row("SELECT COUNT(*) FROM message_catalog", [], |row| row.get(0))
        .expect("message catalog rows")
}

fn load_account_progress_snapshot_for_test(
    config: &AppConfig,
    account_id: i64,
) -> AccountProgressSnapshotRecord {
    load_account_progress_snapshot(config, account_id)
        .expect("snapshot query")
        .expect("snapshot row")
}

fn first_attachment_item(config: &AppConfig, username: &str) -> AttachmentListItem {
    let page = load_attachment_page_data(
        config,
        username,
        &AttachmentListParams {
            q: None,
            account_id: None,
            priority: None,
            extension: None,
            include_inline: None,
            include_inline_images: None,
            show_mime_details: None,
            download_subfolder: None,
            page: None,
            flash: None,
            error: None,
            ..Default::default()
        },
    )
    .expect("attachment page");
    page.items.into_iter().next().expect("attachment item")
}

fn configure_test_paperless_handoff(config: &mut AppConfig, tempdir: &TempDir) {
    config.paperless_consume_root = Some(Arc::from(
        tempdir
            .path()
            .join("paperless-consume")
            .to_string_lossy()
            .to_string(),
    ));
    config.paperless_handoff_staging_root = Some(Arc::from(
        tempdir
            .path()
            .join("paperless-handoff-staging")
            .to_string_lossy()
            .to_string(),
    ));
}

fn configure_test_paperless_database(config: &mut AppConfig, tempdir: &TempDir) -> PathBuf {
    let db_path = tempdir.path().join("paperless.sqlite3");
    config.paperless_database_path = Some(Arc::from(db_path.to_string_lossy().to_string()));
    let connection = Connection::open(&db_path).expect("paperless db");
    connection
        .execute_batch(
            r#"
                CREATE TABLE documents_document (
                    id INTEGER PRIMARY KEY,
                    title TEXT NOT NULL,
                    checksum TEXT NOT NULL,
                    archive_checksum TEXT,
                    deleted_at TEXT
                );
                "#,
        )
        .expect("paperless schema");
    db_path
}

fn mail_export_stub_commands() -> [(&'static str, &'static str); 4] {
    [
            (
                "mbsync",
                "exit 0\n",
            ),
            (
                "notmuch",
                "parse_notmuch_value() {\n  key=\"$1\"\n  awk -F= -v key=\"$key\" '\n    /^\\[database\\]$/ { in_db = 1; next }\n    /^\\[/ { in_db = 0 }\n    in_db && $1 == key { print substr($0, index($0, \"=\") + 1); exit }\n  ' \"$NOTMUCH_CONFIG\"\n}\nSTATE_DIR=\"$HOME/.notmuch-stub\"\nMAILDIR=\"$(parse_notmuch_value mail_root)\"\nDB_DIR=\"$(parse_notmuch_value path)\"\nmkdir -p \"$STATE_DIR\"\ncmd=\"${1:-}\"\nshift || true\ncase \"$cmd\" in\n  new)\n    mkdir -p \"$DB_DIR\"\n    ;;\n  count)\n    find \"$MAILDIR\" -type f \\( -path '*/cur/*' -o -path '*/new/*' \\) | wc -l | tr -d ' '\n    ;;\n  search)\n    if printf '%s ' \"$@\" | grep -q -- '--format=json'; then\n      printf '[]'\n      exit 0\n    fi\n    reviewed=\"$STATE_DIR/reviewed\"\n    touch \"$reviewed\"\n    while IFS= read -r path; do\n      rel=\"${path#${MAILDIR}/}\"\n      if grep -Fxq \"$rel\" \"$reviewed\"; then\n        continue\n      fi\n      printf '%s\\n' \"$path\"\n    done < <(find \"$MAILDIR\" -type f \\( -path '*/cur/*' -o -path '*/new/*' \\) | sort)\n    ;;\n  tag)\n    tag_spec=\"$1\"\n    shift\n    if [[ \"${1:-}\" == '--' ]]; then\n      shift\n    fi\n    query=\"${1:-}\"\n    rel=\"${query#path:\\\"}\"\n    rel=\"${rel%\\\"}\"\n    rel=\"${rel//\\\\\\\"/\\\"}\"\n    rel=\"${rel//\\\\\\\\/\\\\}\"\n    case \"$tag_spec\" in\n      +archive-reviewed)\n        touch \"$STATE_DIR/reviewed\"\n        printf '%s\\n' \"$rel\" >> \"$STATE_DIR/reviewed\"\n        sort -u \"$STATE_DIR/reviewed\" -o \"$STATE_DIR/reviewed\"\n        ;;\n      +archive-filed)\n        touch \"$STATE_DIR/filed\"\n        printf '%s\\n' \"$rel\" >> \"$STATE_DIR/filed\"\n        sort -u \"$STATE_DIR/filed\" -o \"$STATE_DIR/filed\"\n        ;;\n      *)\n        echo \"unsupported tag command: $tag_spec\" >&2\n        exit 1\n        ;;\n    esac\n    ;;\n  *)\n    echo \"unsupported notmuch command: $cmd\" >&2\n    exit 1\n    ;;\nesac\n",
            ),
            (
                "ripmime",
                "input=''\noutput=''\nwhile [[ $# -gt 0 ]]; do\n  case \"$1\" in\n    -i)\n      input=\"$2\"\n      shift 2\n      ;;\n    -d)\n      output=\"$2\"\n      shift 2\n      ;;\n    *)\n      shift\n      ;;\n  esac\ndone\nmkdir -p \"$output\"\ncontents=\"$(cat \"$input\")\"\nif [[ \"$contents\" == *'ATTACH:none'* ]]; then\n  exit 0\nfi\nif [[ \"$contents\" == *'ATTACH:body-parts'* ]]; then\n  : > \"$output/textfile0\"\n  printf 'plain body\\n' > \"$output/textfile1\"\n  printf '<p>html body</p>\\n' > \"$output/textfile2\"\nfi\nif [[ \"$contents\" == *'ATTACH:duplicate-pdf'* ]]; then\n  printf 'duplicate payload\\n' > \"$output/invoice.pdf\"\nfi\nif [[ \"$contents\" == *'ATTACH:pdf-and-zip'* ]]; then\n  printf 'pdf payload\\n' > \"$output/invoice.pdf\"\n  printf 'zip payload\\n' > \"$output/archive.zip\"\nfi\nif [[ \"$contents\" == *'ATTACH:pdf'* ]]; then\n  printf 'pdf payload\\n' > \"$output/invoice.pdf\"\nfi\nif [[ \"$contents\" == *'ATTACH:text'* ]]; then\n  printf 'plain text payload\\n' > \"$output/note.txt\"\nfi\nif [[ \"$contents\" == *'ATTACH:tiny-image'* ]]; then\n  printf 'tiny' > \"$output/logo.png\"\nfi\nif [[ \"$contents\" == *'ATTACH:two-files-bad'* ]]; then\n  printf 'first payload\\n' > \"$output/good.pdf\"\n  printf 'second payload\\n' > \"$output/second.bin\"\nfi\nif [[ \"$contents\" == *'ATTACH:two-files'* ]]; then\n  printf 'first payload\\n' > \"$output/good.pdf\"\n  printf 'second payload\\n' > \"$output/second.docx\"\nfi\n",
            ),
            (
                "file",
                "target=\"${@: -1}\"\ncase \"$target\" in\n  *textfile0)\n    printf 'inode/x-empty\\n'\n    ;;\n  *textfile1)\n    printf 'text/plain\\n'\n    ;;\n  *textfile2)\n    printf 'text/html\\n'\n    ;;\n  *.pdf)\n    printf 'application/pdf\\n'\n    ;;\n  *.txt)\n    printf 'text/plain\\n'\n    ;;\n  *.docx)\n    printf 'application/vnd.openxmlformats-officedocument.wordprocessingml.document\\n'\n    ;;\n  *.png)\n    printf 'image/png\\n'\n    ;;\n  *.zip)\n    printf 'application/zip\\n'\n    ;;\n  *.bin)\n    echo 'unknown binary attachment' >&2\n    exit 1\n    ;;\n  *)\n    printf 'application/octet-stream\\n'\n    ;;\nesac\n",
            ),
        ]
}

fn mail_export_acl_stub_commands() -> Vec<(&'static str, &'static str)> {
    let mut commands = mail_export_stub_commands().to_vec();
    commands.push((
        "setfacl",
        "printf '%s %s %s\\n' \"$1\" \"$2\" \"$3\" >> \"$SETFACL_LOG\"\n",
    ));
    commands
}

fn mail_export_failing_acl_stub_commands() -> Vec<(&'static str, &'static str)> {
    let mut commands = mail_export_stub_commands().to_vec();
    commands.push(("setfacl", "echo 'setfacl denied' >&2\nexit 1\n"));
    commands
}

#[test]
fn account_paths_live_under_the_users_email_tree() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account = example_account();

    let paths = ensure_account_paths(&config, &account).expect("paths");

    assert_eq!(
        paths.maildir,
        tempdir
            .path()
            .join("store")
            .join("alice")
            .join("_Emails")
            .join(".internal-sync")
            .join("personal-gmail--42")
            .join("maildir")
    );
    assert_eq!(
        paths.account_state_root,
        tempdir
            .path()
            .join("data")
            .join("accounts")
            .join("alice")
            .join("42")
    );
}

#[test]
fn visible_message_filename_caps_long_subjects() {
    let long_subject = "10197254.".to_string() + &"LongToken".repeat(80);
    let filename = visible_message_filename(
        1_632_991_000,
        &long_subject,
        "message-id:very-long-subject@example.com",
    );

    assert!(filename.ends_with(".eml"));
    assert!(filename.len() < 255);
    assert!(filename.contains("["));
}

#[test]
fn forwarded_header_identity_requires_group_membership() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-forwarded-preferred-username",
        "alice".parse().expect("valid username header"),
    );
    headers.insert(
        "x-forwarded-email",
        "alice@example.com".parse().expect("valid email header"),
    );
    headers.insert(
        "x-forwarded-groups",
        "users,mail-archive-users"
            .parse()
            .expect("valid groups header"),
    );

    let identity = identity_from_headers(&headers).expect("identity should be accepted");
    assert_eq!(identity.username, "alice");
    assert_eq!(identity.email.as_deref(), Some("alice@example.com"));
}

#[test]
fn forwarded_header_identity_rejects_missing_access_group() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-forwarded-preferred-username",
        "alice".parse().expect("valid username header"),
    );
    headers.insert(
        "x-forwarded-groups",
        "users".parse().expect("valid groups header"),
    );

    assert_eq!(
        identity_from_headers(&headers)
            .expect_err("missing group should be rejected")
            .0,
        StatusCode::FORBIDDEN
    );
}

#[test]
fn state_changing_requests_require_same_origin() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-forwarded-host",
        "emails.example.com".parse().expect("host"),
    );
    headers.insert("x-forwarded-proto", "https".parse().expect("proto"));
    headers.insert(
        "origin",
        "https://emails.example.com".parse().expect("origin"),
    );

    verify_same_origin_request(&headers).expect("same origin");
}

#[test]
fn state_changing_requests_reject_cross_origin() {
    let mut headers = HeaderMap::new();
    headers.insert(
        "x-forwarded-host",
        "emails.example.com".parse().expect("host"),
    );
    headers.insert("x-forwarded-proto", "https".parse().expect("proto"));
    headers.insert(
        "referer",
        "https://evil.example.net/form".parse().expect("referer"),
    );

    assert_eq!(
        verify_same_origin_request(&headers)
            .expect_err("cross origin should fail")
            .0,
        StatusCode::FORBIDDEN
    );
}

#[test]
fn gmail_defaults_render_expected_sync_config() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account = example_account();
    let paths = ensure_account_paths(&config, &account).expect("paths");
    let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");
    let mbsyncrc = write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("mbsyncrc");
    let rendered = fs::read_to_string(&mbsyncrc.path).expect("read mbsyncrc");

    assert!(rendered.contains("Host imap.gmail.com"));
    assert!(rendered.contains("\"[Gmail]/All Mail\""));
    assert!(rendered.contains("Sync Pull New Flags"));
    assert!(rendered.contains(&format!("Path {}/", paths.maildir.display())));
    assert!(rendered.contains(&format!(
        "SyncState {}",
        paths.sync_state_dir.join("state").display()
    )));
}

#[test]
fn generic_imap_defaults_render_expected_sync_config() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let mut account = example_account();
    account.id = 7;
    account.provider_kind = "generic_imap".to_string();
    account.display_name = "Work Mail".to_string();
    account.imap_host = "imap.example.com".to_string();
    account.imap_username = "alice@example.com".to_string();
    account.folder_mode = "generic_default".to_string();
    account.folder_patterns_json =
        serde_json::to_string(&generic_default_patterns()).expect("json");

    let paths = ensure_account_paths(&config, &account).expect("paths");
    let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");
    let mbsyncrc = write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("mbsyncrc");
    let rendered = fs::read_to_string(&mbsyncrc.path).expect("read mbsyncrc");

    assert!(rendered.contains("Host imap.example.com"));
    assert!(rendered.contains("User \"alice@example.com\""));
    assert!(rendered.contains(&format!(
        "SyncState {}",
        paths.sync_state_dir.join("state").display()
    )));
    assert!(rendered.contains("\"Archive\""));
}

#[test]
fn encrypted_secret_round_trip_restores_plaintext() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);

    let key = load_or_create_master_key(&config).expect("master key");
    let encrypted = encrypt_secret(&key, "super-secret-value").expect("encrypt");
    let decrypted = decrypt_secret(&key, &encrypted).expect("decrypt");

    assert_eq!(decrypted, "super-secret-value");
}

#[test]
fn temp_secret_cleanup_removes_file() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);

    let secret_path = {
        let secret = write_temp_secret(&config, 9, "sekret").expect("secret");
        assert!(secret.path.exists());
        secret.path.clone()
    };

    assert!(!secret_path.exists());
}

#[test]
fn temp_config_cleanup_removes_file() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account = example_account();
    let paths = ensure_account_paths(&config, &account).expect("paths");
    let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");

    let config_path = {
        let temp_config =
            write_temp_mbsyncrc(&config, &account, &paths, &secret.path).expect("config");
        assert!(temp_config.path.exists());
        temp_config.path.clone()
    };

    assert!(!config_path.exists());
}

#[test]
fn notmuch_summary_json_is_parsed_into_search_results() {
    let parsed: Vec<serde_json::Value> = serde_json::from_str(
            r#"[{"timestamp":1713412350,"date_relative":"2d","authors":"Alice Example","subject":"Invoice ready","tags":["inbox","unread"]}]"#,
        )
        .expect("json should parse");

    assert_eq!(parsed[0]["authors"].as_str(), Some("Alice Example"));
    assert_eq!(parsed[0]["subject"].as_str(), Some("Invoice ready"));
    assert_eq!(parsed[0]["tags"].as_array().expect("tags").len(), 2);
}

#[test]
fn per_account_lock_prevents_overlap() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);

    let first_lock = acquire_account_lock(&config, 9).expect("first lock");
    let second = acquire_account_lock(&config, 9).expect_err("second lock must fail");
    drop(first_lock);

    assert!(second.contains("already running"));
}

#[test]
fn stale_lock_is_replaced_when_pid_is_not_active() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);

    let lock_path = sync_lock_path(&config, 9);
    write_private_file(&lock_path, b"999999").expect("stale lock");

    let lock = acquire_account_lock(&config, 9).expect("lock should be reacquired");
    let contents = fs::read_to_string(&lock.path).expect("lock contents");
    assert_eq!(contents.trim(), format!("pid:{}", std::process::id()));
}

#[test]
fn reconcile_interrupted_sync_marks_running_account_as_error() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "secret");

    update_sync_started(&config, account_id).expect("mark running");
    let lock_path = sync_lock_path(&config, account_id);
    write_private_file(&lock_path, b"999999").expect("stale lock");

    reconcile_interrupted_syncs(&config).expect("reconcile");

    let account = read_account(&config, "alice", account_id);
    assert_eq!(account.last_sync_status.as_deref(), Some("error"));
    assert_eq!(
        account.last_sync_error.as_deref(),
        Some("The account was marked running but no active sync lock remained.")
    );
    assert_eq!(account.last_sync_phase.as_deref(), Some("reconcile"));
    assert_eq!(account.last_sync_code.as_deref(), Some("interrupted"));
    assert_eq!(
        account.last_sync_summary.as_deref(),
        Some("A previous sync stopped before indexing finished.")
    );
    assert!(!lock_path.exists());
}

#[test]
fn dashboard_load_reconciles_stale_running_syncs() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "secret");

    update_sync_started(&config, account_id).expect("mark running");
    let lock_path = sync_lock_path(&config, account_id);
    write_private_file(&lock_path, b"999999").expect("stale lock");

    let views = load_dashboard_account_views(&config, "alice").expect("dashboard views");

    assert_eq!(views.len(), 1);
    assert_eq!(views[0].status.status_label, "sync failed");
    assert_eq!(
        views[0].status.diagnostic_code.as_deref(),
        Some("interrupted")
    );
    assert!(!lock_path.exists());
}

#[test]
fn sync_failure_classifies_download_phase() {
    with_stubbed_path(
        &[
            ("mbsync", "echo 'authentication failed' >&2\nexit 1\n"),
            ("notmuch", "exit 0\n"),
        ],
        |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account(&config, "alice", "secret");

            let error =
                run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                    .expect_err("sync should fail");

            assert_eq!(error.phase, Some(SyncPhase::Download));
            assert_eq!(error.code, "download_failed");
            assert_eq!(
                error.summary,
                "Mailbox download failed before new mail could be indexed."
            );
            assert!(error.detail.contains("authentication failed"));

            let account = read_account(&config, "alice", account_id);
            assert_eq!(account.last_sync_phase.as_deref(), Some("download"));
            assert_eq!(account.last_sync_code.as_deref(), Some("download_failed"));
        },
    );
}

#[test]
fn sync_failure_classifies_index_phase() {
    with_stubbed_path(
        &[
            ("mbsync", "exit 0\n"),
            ("notmuch", "echo 'database locked' >&2\nexit 1\n"),
        ],
        |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            let account_id = seed_account(&config, "alice", "secret");

            let error =
                run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
                    .expect_err("sync should fail");

            assert_eq!(error.phase, Some(SyncPhase::Index));
            assert_eq!(error.code, "index_failed");
            assert!(error.summary.contains("indexing failed"));
            assert!(error.detail.contains("database locked"));
        },
    );
}

#[test]
fn html_page_references_stylesheet_and_security_headers() {
    with_env_var("MAIL_ARCHIVE_UI_FRONTEND_MODE", "vite", || {
        let identity = Identity {
            username: "alice".to_string(),
            email: Some("alice@example.com".to_string()),
        };

        let html = layout(
            "Mail Archive",
            Some(&identity),
            "dashboard",
            "<section>Body</section>",
        );
        assert!(html.contains("@vite/client"));
        assert!(html.contains("/src/entry.dev.tsx"));
        assert!(html.contains("mail-archive-ui-islands"));
        assert!(html.contains("Signed in as alice"));

        let response = html_response(html);
        assert_eq!(
            response.headers().get("X-Frame-Options").expect("header"),
            "DENY"
        );
        assert!(response
            .headers()
            .get("Content-Security-Policy")
            .expect("csp")
            .to_str()
            .expect("csp string")
            .contains("http://127.0.0.1:5173"));
    });
}

#[test]
fn production_frontend_tags_are_read_from_vite_manifest() {
    let tempdir = TempDir::new().expect("tempdir");
    let manifest_dir = tempdir.path().join(".vite");
    fs::create_dir_all(&manifest_dir).expect("manifest dir");
    fs::write(
        manifest_dir.join("manifest.json"),
        r#"{
              "src/entry.prod.tsx": {
                "file": "assets/entry.prod-abc.js",
                "css": ["assets/entry.prod-abc.css"]
              }
            }"#,
    )
    .expect("manifest");

    let tags = production_asset_tags(
        tempdir.path().to_str().expect("utf8 path"),
        FRONTEND_ENTRYPOINT,
    )
    .expect("tags");

    assert!(tags.contains("/static/frontend/assets/entry.prod-abc.css"));
    assert!(tags.contains("/static/frontend/assets/entry.prod-abc.js"));
}

#[test]
fn production_frontend_tags_report_missing_manifest_clearly() {
    let tempdir = TempDir::new().expect("tempdir");
    let error = production_asset_tags(
        tempdir.path().to_str().expect("utf8 path"),
        FRONTEND_ENTRYPOINT,
    )
    .expect_err("missing manifest should fail");

    assert!(error.contains("failed to read Vite manifest"));
}

#[test]
fn csp_only_allows_vite_origin_in_vite_mode() {
    with_env_var("MAIL_ARCHIVE_UI_FRONTEND_MODE", "production", || {
        let csp = content_security_policy();
        assert!(!csp.contains("127.0.0.1:5173"));
    });
    with_env_var("MAIL_ARCHIVE_UI_FRONTEND_MODE", "vite", || {
        let csp = content_security_policy();
        assert!(csp.contains("http://127.0.0.1:5173"));
        assert!(csp.contains("ws://127.0.0.1:5173"));
    });
}

#[test]
fn dashboard_card_renders_structured_sync_notice() {
    let view = DashboardAccountView {
        account: example_account(),
        status: sample_status_payload(),
    };

    let html = render_account_card(&view);
    assert!(html.contains("Mailbox download failed before new mail could be indexed."));
    assert!(html.contains("Troubleshooting details"));
    assert!(html.contains("Check the mailbox credentials"));
    assert!(html.contains("Sync Now"));
    assert!(html.contains("data-health-light=\"mailbox\""));
    assert!(!html.contains("physical message files representing 6668 logical messages"));
    assert!(!html.contains("Search index is caught up with the archived messages."));
    assert!(!html.contains("Search ready"));
}

#[test]
fn dashboard_keeps_large_hero_panel() {
    let html = render_dashboard(&sample_identity(), &[], None, None);

    assert!(html.contains("class=\"hero dashboard-hero\""));
    assert!(html.contains("Mail Archive"));
    assert!(html.contains("Search saved messages and find documents in attachments."));
    assert!(html.contains("Search attachments"));
}

#[test]
fn metrics_progress_warning_is_exposed_in_status_payload() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "secret");
    let account = read_account(&config, "alice", account_id);
    let paths = ensure_account_paths(&config, &account).expect("paths");
    fs::create_dir_all(&paths.notmuch_db_root).expect("db");
    store_account_progress_snapshot(
        &config,
        account_id,
        &AccountProgressCounts::default(),
        None,
        "error",
        Some("database unavailable"),
    )
    .expect("snapshot");

    let view = build_dashboard_account_view(&config, account);

    assert_eq!(
        view.status.progress_warning.as_deref(),
        Some("Archive counts could not be verified for this mailbox.")
    );
    assert_eq!(view.status.status_label, "check archive");
    assert!(view
        .status
        .progress_warning_detail
        .as_deref()
        .expect("warning detail")
        .contains("database unavailable"));
}

#[test]
fn legacy_last_sync_error_still_renders_reasonable_summary() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "secret");
    let connection = open_db(&config).expect("db");
    connection
        .execute(
            r#"
                UPDATE accounts
                SET
                    last_sync_status = 'error',
                    last_sync_error = 'legacy failure detail',
                    last_sync_phase = NULL,
                    last_sync_code = NULL,
                    last_sync_summary = NULL,
                    last_sync_detail = NULL
                WHERE id = ?1
                "#,
            params![account_id],
        )
        .expect("update");

    let view = build_dashboard_account_view(&config, read_account(&config, "alice", account_id));
    assert_eq!(
        view.status.diagnostic_summary.as_deref(),
        Some("The last sync reported an error.")
    );
    assert_eq!(
        view.status.diagnostic_detail.as_deref(),
        Some("legacy failure detail")
    );
}

#[test]
fn dashboard_status_payload_serializes_diagnostic_fields() {
    let payload = DashboardStatusPayload {
        generated_at: "2026-04-26T00:00:00Z".to_string(),
        totals: DashboardTotals::default(),
        accounts: vec![sample_status_payload()],
    };

    let json = serde_json::to_value(payload).expect("json");
    let account = &json["accounts"][0];
    assert!(account.get("archived_message_count").is_some());
    assert!(account.get("archive_file_count").is_some());
    assert!(account.get("overlap_file_count").is_some());
    assert!(account.get("overlap_note").is_some());
    assert!(account.get("diagnostic_summary").is_some());
    assert!(account.get("diagnostic_detail").is_some());
    assert!(account.get("recommended_action").is_some());
    assert!(account.get("progress_warning").is_some());
}

#[test]
fn styled_error_page_uses_shared_layout() {
    let response = auth_error(StatusCode::FORBIDDEN, "nope");
    assert_eq!(response.status(), StatusCode::FORBIDDEN);

    let html = layout(
            "Access denied",
            None,
            "",
            "<section class=\"panel stack\"><p class=\"eyebrow\">Access denied</p><h1>Request blocked</h1><div class=\"error\">nope</div></section>",
        );
    assert!(html.contains("page-footer"));
    assert!(html.contains("Request blocked"));
}

#[test]
fn update_with_blank_secret_preserves_encrypted_secret() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "old-secret");
    let before = read_account(&config, "alice", account_id);

    update_account_for_user(
        &config,
        "alice",
        account_id,
        ValidatedAccount {
            provider_kind: "gmail".to_string(),
            display_name: "Updated".to_string(),
            imap_host: "imap.gmail.com".to_string(),
            imap_port: 993,
            imap_username: "alice@gmail.com".to_string(),
            folder_mode: "gmail_default".to_string(),
            folder_patterns: gmail_default_patterns(),
            secret: None,
            sync_enabled: false,
        },
    )
    .expect("update");

    let after = read_account(&config, "alice", account_id);
    assert_eq!(before.encrypted_secret, after.encrypted_secret);
    assert!(!after.sync_enabled);
}

#[test]
fn update_with_new_secret_rotates_encrypted_secret() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "old-secret");
    let before = read_account(&config, "alice", account_id);

    update_account_for_user(
        &config,
        "alice",
        account_id,
        ValidatedAccount {
            provider_kind: "gmail".to_string(),
            display_name: "Updated".to_string(),
            imap_host: "imap.gmail.com".to_string(),
            imap_port: 993,
            imap_username: "alice@gmail.com".to_string(),
            folder_mode: "gmail_default".to_string(),
            folder_patterns: gmail_default_patterns(),
            secret: Some("new-secret".to_string()),
            sync_enabled: true,
        },
    )
    .expect("update");

    let after = read_account(&config, "alice", account_id);
    assert_ne!(before.encrypted_secret, after.encrypted_secret);
}

#[test]
fn toggle_sync_flips_only_sync_flag() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "secret");

    let enabled = toggle_sync_for_user(&config, "alice", account_id).expect("toggle");
    assert!(!enabled);
    let account = read_account(&config, "alice", account_id);
    assert!(!account.sync_enabled);
}

#[test]
fn notmuch_config_is_reconciled_after_account_update() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account_id = seed_account(&config, "alice", "secret");
    let account = read_account(&config, "alice", account_id);
    let initial = read_notmuch_config(&config, &account);
    let paths = ensure_account_paths(&config, &account).expect("paths");
    assert!(initial.contains("primary_email=alice@gmail.com"));
    assert!(initial.contains(&format!("mail_root={}", paths.maildir.display())));
    assert!(initial.contains(&format!("path={}", paths.notmuch_db_root.display())));
    assert!(initial.contains("[index]\nas_text="));
    assert!(initial.contains("^application/pdf$"));
    assert!(initial.contains(
        "^application/vnd[.]openxmlformats-officedocument[.]wordprocessingml[.]document$"
    ));

    update_account_for_user(
        &config,
        "alice",
        account_id,
        ValidatedAccount {
            provider_kind: "gmail".to_string(),
            display_name: "Updated".to_string(),
            imap_host: "imap.gmail.com".to_string(),
            imap_port: 993,
            imap_username: "archive@example.com".to_string(),
            folder_mode: "gmail_default".to_string(),
            folder_patterns: gmail_default_patterns(),
            secret: None,
            sync_enabled: true,
        },
    )
    .expect("update");

    let updated = read_account(&config, "alice", account_id);
    let reconciled = read_notmuch_config(&config, &updated);
    assert!(reconciled.contains("primary_email=archive@example.com"));
}

#[test]
fn reindex_runs_notmuch_without_mbsync() {
    with_stubbed_path(
            &[
                (
                    "notmuch",
                    "mkdir -p \"$HOME/.reindex-log\"\nprintf '%s\n' \"$*\" >> \"$HOME/.reindex-log/commands\"\nawk -F= '\n  /^\\[database\\]$/ { in_db = 1; next }\n  /^\\[/ { in_db = 0 }\n  in_db && $1 == \"path\" { print substr($0, index($0, \"=\") + 1); exit }\n' \"$NOTMUCH_CONFIG\" | xargs -r mkdir -p\n",
                ),
                (
                    "mbsync",
                    "exit 1\n",
                ),
            ],
            |_| {
                let tempdir = TempDir::new().expect("tempdir");
                let config = test_config(&tempdir);
                prepare_test_layout(&config);
                let account_id = seed_account(&config, "alice", "secret");
                let account = read_account(&config, "alice", account_id);
                let paths = ensure_account_paths(&config, &account).expect("paths");
                ensure_notmuch_config(&config, &account, &paths).expect("config");

                run_account_action_for_user(&config, "alice", account_id, AccountAction::Reindex)
                    .expect("reindex");

                let log = fs::read_to_string(
                    paths
                        .account_state_root
                        .join(".reindex-log/commands"),
                )
                .expect("log");
                assert!(log.contains("new"));
                assert!(paths.notmuch_db_root.exists());
            },
        );
}

#[test]
fn search_preferences_round_trip() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);

    save_search_preferences(&config, "alice", "from:billing", Some(9)).expect("save prefs");
    let preferences = load_search_preferences(&config, "alice").expect("load prefs");

    assert_eq!(preferences.last_query.as_deref(), Some("from:billing"));
    assert_eq!(preferences.default_account_id, Some(9));
}

#[test]
fn account_index_state_tracks_config_and_database() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let account = example_account();
    let paths = ensure_account_paths(&config, &account).expect("paths");

    assert_eq!(account_index_state(&paths), IndexState::NotConfigured);
    ensure_notmuch_config(&config, &account, &paths).expect("config");
    assert_eq!(
        account_index_state(&paths),
        IndexState::ConfiguredNoDatabase
    );
    fs::create_dir_all(&paths.notmuch_db_root).expect("db");
    assert_eq!(account_index_state(&paths), IndexState::Indexed);
}

#[test]
fn health_payload_reports_success_with_stubbed_commands() {
    with_stubbed_path(
        &[
            ("mbsync", "exit 0\n"),
            ("notmuch", "exit 0\n"),
            ("ripmime", "exit 0\n"),
            ("file", "exit 0\n"),
        ],
        |_| {
            let tempdir = TempDir::new().expect("tempdir");
            let config = test_config(&tempdir);
            prepare_test_layout(&config);
            initialize_db(&config).expect("db");

            let (status, payload) = health_payload(&config);
            assert_eq!(status, StatusCode::OK);
            assert_eq!(payload.status, "ok");
            assert_eq!(payload.checks.mbsync, "ok");
        },
    );
}

#[test]
fn health_payload_reports_missing_tools() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    initialize_db(&config).expect("db");

    let _guard = env_lock()
        .lock()
        .unwrap_or_else(|poisoned| poisoned.into_inner());
    let original_path = env::var("PATH").unwrap_or_default();
    env::set_var("PATH", tempdir.path().join("empty-bin"));
    let (status, payload) = health_payload(&config);
    env::set_var("PATH", original_path);

    assert_eq!(status, StatusCode::SERVICE_UNAVAILABLE);
    assert_eq!(payload.status, "degraded");
    assert!(payload.checks.notmuch.contains("notmuch"));
}

#[test]
fn search_mail_uses_stubbed_notmuch_and_returns_results() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");
        let account = read_account(&config, "alice", account_id);
        let paths = ensure_account_paths(&config, &account).expect("paths");
        ensure_notmuch_config(&config, &account, &paths).expect("config");
        fs::create_dir_all(&paths.notmuch_db_root).expect("db");
        write_maildir_message(
                &paths,
                "Inbox/cur/msg-1",
                "Message-ID: <search@example.com>\nFrom: Alice Example <alice@example.com>\nSubject: Invoice ready\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

        let results = search_mail(
            &config,
            "alice",
            Some(account_id),
            test_message_filters("subject:invoice"),
            SenderPriorityFilter::All,
        )
        .expect("search");
        assert_eq!(results.len(), 1);
        assert_eq!(results[0].subject, "Invoice ready");
    });
}

#[test]
fn sender_identity_parsing_normalizes_address_and_exact_domain() {
    let parsed = sender_identity_from_header("Billing Team <Billing@Example.COM>").expect("sender");
    assert_eq!(parsed.address, "billing@example.com");
    assert_eq!(parsed.domain, "example.com");

    let fallback =
        sender_identity_from_header("broken <fallback@example.org>").expect("fallback sender");
    assert_eq!(fallback.address, "fallback@example.org");
    assert!(sender_identity_from_header("Unknown sender").is_none());
}

#[test]
fn sender_priority_rules_are_per_user_and_address_overrides_domain() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);

    upsert_sender_priority_rule(&config, "alice", "domain", "example.com", "low")
        .expect("domain rule");
    upsert_sender_priority_rule(&config, "alice", "address", "vip@example.com", "high")
        .expect("address rule");
    upsert_sender_priority_rule(&config, "bob", "domain", "example.com", "high").expect("bob rule");

    let alice = load_sender_priority_rules(&config, "alice").expect("alice rules");
    assert_eq!(
        alice
            .view_for_sender("Billing <billing@example.com>")
            .priority,
        SenderPriority::Low
    );
    assert_eq!(
        alice.view_for_sender("VIP <vip@example.com>").priority,
        SenderPriority::High
    );
    assert_eq!(
        alice
            .view_for_sender("Subdomain <person@news.example.com>")
            .priority,
        SenderPriority::Normal
    );

    let bob = load_sender_priority_rules(&config, "bob").expect("bob rules");
    assert_eq!(
        bob.view_for_sender("Billing <billing@example.com>")
            .priority,
        SenderPriority::High
    );

    clear_sender_priority_rule(&config, "alice", "address", "vip@example.com").expect("clear");
    let alice = load_sender_priority_rules(&config, "alice").expect("alice after clear");
    assert_eq!(
        alice.view_for_sender("VIP <vip@example.com>").priority,
        SenderPriority::Low
    );
}

#[test]
fn sender_priority_setter_clears_rule_when_normal_is_selected() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);

    set_sender_priority_rule(&config, "alice", "address", "vip@example.com", "high")
        .expect("set high")
        .expect("saved rule");
    let alice = load_sender_priority_rules(&config, "alice").expect("alice rules");
    assert_eq!(
        alice.view_for_sender("VIP <vip@example.com>").priority,
        SenderPriority::High
    );

    let cleared =
        set_sender_priority_rule(&config, "alice", "address", "vip@example.com", "normal")
            .expect("clear normal");
    assert!(cleared.is_none());
    let alice = load_sender_priority_rules(&config, "alice").expect("alice after clear");
    assert_eq!(
        alice.view_for_sender("VIP <vip@example.com>").priority,
        SenderPriority::Normal
    );
}

#[test]
fn search_mail_sorts_and_filters_by_sender_priority_without_query_changes() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account(&config, "alice", "secret");
        let account = read_account(&config, "alice", account_id);
        let paths = ensure_account_paths(&config, &account).expect("paths");
        ensure_notmuch_config(&config, &account, &paths).expect("config");
        fs::create_dir_all(&paths.notmuch_db_root).expect("db");
        write_maildir_message(
                &paths,
                "Inbox/cur/low",
                "Message-ID: <low@example.com>\nFrom: Low <billing@example.com>\nSubject: Low newest\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nbody\n",
            );
        write_maildir_message(
                &paths,
                "Inbox/cur/normal",
                "Message-ID: <normal@example.com>\nFrom: Normal <alerts@news.example.com>\nSubject: Normal middle\nDate: Fri, 19 Apr 2024 14:32:00 +0000\n\nbody\n",
            );
        write_maildir_message(
                &paths,
                "Inbox/cur/high",
                "Message-ID: <high@example.com>\nFrom: High <vip@example.com>\nSubject: High oldest\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );
        upsert_sender_priority_rule(&config, "alice", "domain", "example.com", "low")
            .expect("domain low");
        upsert_sender_priority_rule(&config, "alice", "address", "vip@example.com", "high")
            .expect("address high");

        let results = search_mail(
            &config,
            "alice",
            Some(account_id),
            test_message_filters(""),
            SenderPriorityFilter::All,
        )
        .expect("search all");
        assert_eq!(
            results
                .iter()
                .map(|result| result.subject.as_str())
                .collect::<Vec<_>>(),
            ["High oldest", "Normal middle", "Low newest"]
        );

        let low = search_mail(
            &config,
            "alice",
            Some(account_id),
            test_message_filters(""),
            SenderPriorityFilter::Low,
        )
        .expect("search low");
        assert_eq!(low.len(), 1);
        assert_eq!(low[0].subject, "Low newest");
    });
}

#[test]
fn search_mail_applies_structured_sender_subject_date_and_attachment_filters() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-match",
                "Message-ID: <match@example.com>\nFrom: Billing Team <billing@example.com>\nSubject: Invoice ready\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-no-attachment",
                "Message-ID: <plain@example.com>\nFrom: Billing Team <billing@example.com>\nSubject: Invoice ready\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:none\n",
            );
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-domain",
                "Message-ID: <other@example.net>\nFrom: Billing Team <billing@example.net>\nSubject: Invoice ready\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let results = search_mail(
            &config,
            "alice",
            Some(account_id),
            MessageSearchFilters {
                sender_name: "Billing".to_string(),
                sender_domain: "example.com".to_string(),
                subject: "invoice".to_string(),
                date_from: "2024-04-20".to_string(),
                date_to: "2024-04-20".to_string(),
                has_attachments: Some(true),
                ..Default::default()
            },
            SenderPriorityFilter::All,
        )
        .expect("search");

        assert_eq!(results.len(), 1);
        assert_eq!(results[0].subject, "Invoice ready");
        assert_eq!(results[0].from, "Billing Team <billing@example.com>");
    });
}

#[test]
fn search_empty_state_distinguishes_prefill_from_submitted_no_results() {
    let identity = Identity {
        username: "alice".to_string(),
        email: Some("alice@example.com".to_string()),
    };
    let html_prefill = render_search(
        &identity,
        &[],
        &test_message_filters(""),
        None,
        &[],
        &SearchViewState {
            submitted: false,
            result_count: 0,
            empty_message: Some(
                "Saved search defaults are prefilled below. Submit a query to search indexed mail."
                    .to_string(),
            ),
            priority_filter: SenderPriorityFilter::All,
        },
        None,
        None,
    );
    let html_submitted = render_search(
        &identity,
        &[],
        &test_message_filters("from:billing"),
        None,
        &[],
        &SearchViewState {
            submitted: true,
            result_count: 0,
            empty_message: Some("No indexed messages matched this query.".to_string()),
            priority_filter: SenderPriorityFilter::All,
        },
        None,
        None,
    );

    assert!(html_prefill.contains("Saved search defaults"));
    assert!(html_submitted.contains("0 results"));
    assert!(html_submitted.contains("No indexed messages matched this query."));
}

#[test]
fn search_page_uses_compact_heading_and_sticky_result_header() {
    let priority_rules = SenderPriorityRules::default();
    let result = SearchResult {
        account_name: "Personal Gmail".to_string(),
        message_relpath: "Inbox/message.eml".to_string(),
        timestamp: 0,
        date_label: "2024-04-18 14:32 UTC".to_string(),
        from: "Billing <billing@example.com>".to_string(),
        subject: "Invoice ready".to_string(),
        tags: vec!["inbox".to_string()],
        sender_priority: priority_rules.view_for_sender("Billing <billing@example.com>"),
    };
    let html = render_search(
        &sample_identity(),
        &[],
        &test_message_filters("subject:invoice"),
        None,
        &[result],
        &SearchViewState {
            submitted: true,
            result_count: 1,
            empty_message: None,
            priority_filter: SenderPriorityFilter::All,
        },
        None,
        None,
    );

    assert!(html.contains("page-heading"));
    assert!(html.contains("Search mail"));
    assert!(html.contains("mail-list-header"));
    assert!(html.contains("Sender importance"));
    assert!(!html.contains("Query your downloaded mail with notmuch."));
}

#[test]
fn search_reset_link_clears_saved_query() {
    let html = render_search(
        &sample_identity(),
        &[],
        &test_message_filters("remembered query"),
        None,
        &[],
        &SearchViewState {
            submitted: false,
            result_count: 0,
            empty_message: None,
            priority_filter: SenderPriorityFilter::All,
        },
        None,
        None,
    );

    assert!(html.contains("href=\"/search?q=\""));
    assert!(!html.contains("href=\"/search\" title=\"Reset filters\""));
}

#[test]
fn redirect_feedback_renders_as_toasts_not_page_banners() {
    let html = render_search(
        &sample_identity(),
        &[],
        &test_message_filters(""),
        None,
        &[],
        &SearchViewState {
            submitted: false,
            result_count: 0,
            empty_message: None,
            priority_filter: SenderPriorityFilter::All,
        },
        Some("Sender+importance+cleared"),
        Some("Sender+importance+task+failed"),
    );

    assert!(html.contains("toast-stack"));
    assert!(html.contains("class=\"toast success\""));
    assert!(html.contains("class=\"toast error\""));
    assert!(html.contains("Sender importance cleared"));
    assert!(html.contains("Sender importance task failed"));
    assert!(!html.contains("class=\"flash\""));
}

#[test]
fn validate_account_form_requires_secret_only_for_create() {
    let form = CreateAccountForm {
        provider_kind: "gmail".to_string(),
        display_name: "Personal".to_string(),
        imap_host: "ignored".to_string(),
        imap_port: "993".to_string(),
        imap_username: "alice@gmail.com".to_string(),
        secret: String::new(),
        folder_patterns: String::new(),
        sync_enabled: Some("on".to_string()),
    };

    assert!(validate_account_form(&form, true).is_err());
    assert!(validate_account_form(&form, false).is_ok());
}

#[test]
fn generic_imap_fields_reject_mbsync_directive_injection() {
    let mut form = CreateAccountForm {
        provider_kind: "generic_imap".to_string(),
        display_name: "Personal".to_string(),
        imap_host: "imap.example.com\nPassCmd malicious".to_string(),
        imap_port: "993".to_string(),
        imap_username: "alice@example.com".to_string(),
        secret: "secret".to_string(),
        folder_patterns: "INBOX".to_string(),
        sync_enabled: Some("on".to_string()),
    };

    assert!(validate_account_form(&form, true).is_err());
    form.imap_host = "imap.example.com".to_string();
    form.imap_username = "alice@example.com\nTunnel malicious".to_string();
    assert!(validate_account_form(&form, true).is_err());
    form.imap_username = "alice@example.com".to_string();
    form.folder_patterns = "INBOX\nbad\u{0000}folder".to_string();
    assert!(validate_account_form(&form, true).is_err());
}

#[test]
fn mbsync_rendering_rejects_legacy_unsafe_account_values() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let mut account = example_account();
    account.imap_host = "imap.example.com\nPassCmd malicious".to_string();
    let paths = ensure_account_paths(&config, &account).expect("paths");
    let secret = write_temp_secret(&config, account.id, "sekret").expect("secret");

    assert!(write_temp_mbsyncrc(&config, &account, &paths, &secret.path).is_err());
}

#[test]
fn saved_query_detection_only_runs_on_explicit_q_param() {
    assert!(has_explicit_query_param("q=from%3Abilling"));
    assert!(!has_explicit_query_param("account_id=4"));
}

#[test]
fn rfc2047_headers_decode_to_display_symbols() {
    let tempdir = TempDir::new().expect("tempdir");
    let message_path = tempdir.path().join("message.eml");
    write_private_file(
            &message_path,
            b"Message-ID: <encoded@example.com>\r\nFrom: =?UTF-8?Q?Billing_=E2=9C=85?= <billing@example.com>\r\nSubject: =?UTF-8?Q?Invoice?=\r\n =?UTF-8?Q?_=E2=9C=85?=\r\nDate: Thu, 18 Apr 2024 14:32:00 +0000\r\n\r\nBody\r\n",
        )
        .expect("message");

    let metadata = read_message_metadata(&message_path).expect("metadata");

    assert_eq!(metadata.subject, "Invoice ✅");
    assert!(metadata.from.contains("Billing ✅"));
    assert_eq!(
        metadata.normalized_message_id.as_deref(),
        Some("encoded@example.com")
    );
}

#[test]
fn windows_1252_encoded_subject_decodes_spaces_and_punctuation() {
    let decoded =
        decode_display_header_value("=?Windows-1252?Q?Strata_Plan_79638_=96_Inspection?=");

    assert_eq!(decoded, "Strata Plan 79638 – Inspection");
}

#[test]
fn attachment_general_query_matches_attachment_and_message_fields() {
    let item = AttachmentListItem {
        attachment: AttachmentRecord {
            attachment_key: "key".to_string(),
            account_id: 1,
            message_key: "message".to_string(),
            attachment_index: 0,
            attachment_sha256: "sha".to_string(),
            original_filename: "Annual Inspection notice.pdf".to_string(),
            safe_filename: "Annual Inspection notice.pdf".to_string(),
            extension: "pdf".to_string(),
            mime_type: "application/pdf".to_string(),
            size_bytes: 128,
            is_inline_artifact: false,
            blob_relpath: None,
            source_message_sha256: None,
            last_verified_at: None,
            created_at: String::new(),
            updated_at: String::new(),
            last_seen_at: String::new(),
        },
        message: AttachmentMessageRecord {
            account_id: 1,
            message_key: "message".to_string(),
            message_relpath: "Inbox/message.eml".to_string(),
            message_mtime: 0,
            message_size: 0,
            subject: "Strata plan".to_string(),
            from: "Starr Partners <fire@example.com>".to_string(),
            timestamp: 0,
            last_scanned_at: String::new(),
            has_attachments: true,
        },
        account_name: "Personal Gmail".to_string(),
        sender_priority: SenderPriorityView {
            identity: None,
            priority: SenderPriority::Normal,
            address_rule: None,
        },
        paperless_sent_at: None,
        message_preview: None,
        message_preview_truncated: false,
        message_cc: None,
    };

    assert!(attachment_general_query_matches(&item, "inspection", false));
    assert!(attachment_general_query_matches(&item, "starr", false));
    assert!(attachment_general_query_matches(&item, "body-only", true));
    assert!(!attachment_general_query_matches(&item, "council", false));
}

#[test]
fn malformed_headers_fall_back_without_panicking() {
    let tempdir = TempDir::new().expect("tempdir");
    let message_path = tempdir.path().join("message.eml");
    write_private_file(&message_path, b"Subject: =?UTF-8?Q?broken\r\n\r\nBody\r\n")
        .expect("message");

    let metadata = read_message_metadata(&message_path).expect("metadata");

    assert!(!metadata.subject.is_empty());
    assert_eq!(metadata.from, "Unknown sender");
}

#[test]
fn compact_search_result_markup_truncates_long_values() {
    let priority_rules = SenderPriorityRules::default();
    let result = SearchResult {
        account_name: "Personal Gmail".to_string(),
        message_relpath: "Inbox/very/long/path/that/should/not/overflow/message.eml".to_string(),
        timestamp: 0,
        date_label: format_timestamp_date_label(0),
        from: "Billing ✅ <billing@example.com>".to_string(),
        subject: "Invoice ✅ with a very long subject that should truncate".to_string(),
        tags: vec!["inbox".to_string()],
        sender_priority: priority_rules.view_for_sender("Billing ✅ <billing@example.com>"),
    };

    let html = render_search_result(&result, "/search?q=invoice");

    assert!(html.contains("mail-row"));
    assert!(html.contains("Billing ✅"));
    assert!(html.contains("billing@example.com"));
    assert!(html.contains("Invoice ✅"));
    assert!(html.contains("truncate"));
    assert!(html.contains(&format_timestamp_tooltip_label(0)));
    assert!(!html.contains("Normal priority"));
    assert!(html.contains("Sender importance"));
    assert!(html.contains("name=\"priority\""));
    assert!(html.contains("priority-select-normal"));
    assert!(html.contains("data-priority-select"));
    assert!(html.contains("data-sender-kind=\"address\""));
    assert!(html.contains("data-sender-value=\"billing@example.com\""));
    assert!(
        html.contains("Personal Gmail · Inbox/very/long/path/that/should/not/overflow/message.eml")
    );
    assert!(!html.contains("Delete local archive copy"));
}

#[test]
fn empty_account_query_value_is_treated_as_all_mailboxes() {
    assert_eq!(parse_optional_query_i64(None).expect("none"), None);
    assert_eq!(parse_optional_query_i64(Some("")).expect("empty"), None);
    assert_eq!(parse_optional_query_i64(Some("  ")).expect("blank"), None);
    assert_eq!(
        parse_optional_query_i64(Some("7")).expect("number"),
        Some(7)
    );
}

#[test]
fn maildir_inventory_tracks_root_and_nested_folders() {
    let tempdir = TempDir::new().expect("tempdir");
    let maildir = tempdir.path().join("maildir");

    fs::create_dir_all(maildir.join("cur")).expect("root cur");
    fs::create_dir_all(maildir.join("new")).expect("root new");
    fs::create_dir_all(maildir.join(".Archive/cur")).expect("archive cur");
    fs::create_dir_all(maildir.join(".Archive/tmp")).expect("archive tmp");
    fs::create_dir_all(maildir.join(".notmuch")).expect("notmuch");

    write_private_file(
        &maildir.join("cur/root-message"),
        b"Message-ID: <root@example.com>\n\n1",
    )
    .expect("root cur message");
    write_private_file(
        &maildir.join("new/root-new"),
        b"Message-ID: <new@example.com>\n\n1",
    )
    .expect("root new message");
    write_private_file(
        &maildir.join(".Archive/cur/sub-message"),
        b"Message-ID: <archive@example.com>\n\n1",
    )
    .expect("archive cur message");
    write_private_file(&maildir.join(".Archive/tmp/not-a-message"), b"1").expect("tmp file");
    write_private_file(&maildir.join(".notmuch/metadata"), b"1").expect("metadata");

    let inventory = scan_maildir_inventory(&maildir).expect("inventory");
    assert_eq!(inventory.archive_file_count, 3);
    assert_eq!(inventory.logical_message_count, 3);
    assert_eq!(inventory.overlap_file_count, 0);
}

#[test]
fn maildir_inventory_collapses_duplicate_message_ids_across_folders() {
    let tempdir = TempDir::new().expect("tempdir");
    let maildir = tempdir.path().join("maildir");

    fs::create_dir_all(maildir.join("cur")).expect("root cur");
    fs::create_dir_all(maildir.join(".Archive/cur")).expect("archive cur");

    write_private_file(
        &maildir.join("cur/root-message"),
        b"Message-ID: <duplicate@example.com>\n\nsame",
    )
    .expect("root cur message");
    write_private_file(
        &maildir.join(".Archive/cur/sub-message"),
        b"Message-ID: <duplicate@example.com>\n\nsame",
    )
    .expect("archive cur message");

    let inventory = scan_maildir_inventory(&maildir).expect("inventory");
    assert_eq!(inventory.archive_file_count, 2);
    assert_eq!(inventory.logical_message_count, 1);
    assert_eq!(inventory.overlap_file_count, 1);
}

#[test]
fn maildir_inventory_falls_back_to_sha256_when_message_id_is_missing() {
    let tempdir = TempDir::new().expect("tempdir");
    let maildir = tempdir.path().join("maildir");

    fs::create_dir_all(maildir.join("cur")).expect("root cur");
    fs::create_dir_all(maildir.join(".Archive/cur")).expect("archive cur");

    write_private_file(&maildir.join("cur/root-message"), b"same body").expect("root cur message");
    write_private_file(&maildir.join(".Archive/cur/sub-message"), b"same body")
        .expect("archive cur message");
    write_private_file(
        &maildir.join(".Archive/cur/other-message"),
        b"different body",
    )
    .expect("other archive cur message");

    let inventory = scan_maildir_inventory(&maildir).expect("inventory");
    assert_eq!(inventory.archive_file_count, 3);
    assert_eq!(inventory.logical_message_count, 2);
    assert_eq!(inventory.overlap_file_count, 1);
}

#[test]
fn progress_counts_use_logical_messages_for_pending_index() {
    let counts = progress_counts(
        &MaildirInventory {
            archive_file_count: 5,
            logical_message_count: 3,
            overlap_file_count: 2,
        },
        3,
    );

    assert_eq!(counts.archived_message_count, 3);
    assert_eq!(counts.archive_file_count, 5);
    assert_eq!(counts.overlap_file_count, 2);
    assert_eq!(counts.pending_index_count, 0);
    assert_eq!(counts.index_coverage_percent, 100);
}

#[test]
fn overlap_does_not_mark_a_caught_up_index_as_behind() {
    let mut account = example_account();
    account.last_sync_status = Some("ok".to_string());
    let counts = progress_counts(
        &MaildirInventory {
            archive_file_count: 5,
            logical_message_count: 3,
            overlap_file_count: 2,
        },
        3,
    );

    assert_eq!(
        account_status(&account, IndexState::Indexed, &counts, None, None),
        ("ok", "healthy")
    );
    assert_eq!(
        account_progress_note(&account, &counts, IndexState::Indexed, None, None),
        "Search index is caught up with the archived messages."
    );
    assert_eq!(
            account_overlap_note(&counts, None),
            Some(
                "Archive contains 5 physical message files representing 3 logical messages because synced folders overlap."
                    .to_string()
            )
        );
}

#[test]
fn true_logical_index_lag_still_marks_the_account_as_behind() {
    let mut account = example_account();
    account.last_sync_status = Some("ok".to_string());
    let counts = progress_counts(
        &MaildirInventory {
            archive_file_count: 12,
            logical_message_count: 10,
            overlap_file_count: 2,
        },
        8,
    );

    assert_eq!(counts.pending_index_count, 2);
    assert_eq!(
        account_status(&account, IndexState::Indexed, &counts, None, None),
        ("pending", "index behind")
    );
}

#[test]
fn attachment_tables_are_initialized() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let connection = open_db(&config).expect("db");

    let names = [
        "attachment_messages",
        "attachment_catalog",
        "attachment_paperless_handoffs",
        "attachment_paperless_tasks",
        "attachment_paperless_task_runs",
    ];
    for name in names {
        let count = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .expect("table count");
        assert_eq!(count, 1, "expected table {name} to exist");
    }
    for name in ["attachment_actions", "paperless_attachment_exports"] {
        let count = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .expect("table count");
        assert_eq!(count, 0, "expected table {name} to stay absent");
    }
}

#[test]
fn legacy_paperless_task_schema_is_migrated_in_place() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    ensure_app_layout(&config).expect("layout");
    let connection = open_db(&config).expect("db");
    connection
        .execute_batch(
            r#"
                CREATE TABLE attachment_paperless_tasks (
                    id INTEGER PRIMARY KEY AUTOINCREMENT,
                    username TEXT NOT NULL,
                    name TEXT NOT NULL,
                    query TEXT NOT NULL,
                    schedule_time TEXT NOT NULL,
                    enabled INTEGER NOT NULL DEFAULT 1,
                    last_run_date TEXT,
                    last_run_at TEXT,
                    last_summary TEXT,
                    created_at TEXT NOT NULL,
                    updated_at TEXT NOT NULL,
                    UNIQUE (username, name)
                );
                "#,
        )
        .expect("legacy schema");
    drop(connection);

    initialize_db(&config).expect("migrate");
    let connection = open_db(&config).expect("db");
    for column in [
        "schedule_mode",
        "interval_minutes",
        "max_attachments",
        "retry_enabled",
        "last_status",
        "next_retry_at",
        "consecutive_failures",
        "successful_runs",
        "failed_runs",
        "lease_until",
    ] {
        let found = connection
            .prepare("PRAGMA table_info(attachment_paperless_tasks)")
            .expect("table info")
            .query_map([], |row| row.get::<_, String>(1))
            .expect("columns")
            .collect::<Result<Vec<_>, _>>()
            .expect("column names")
            .into_iter()
            .any(|name| name == column);
        assert!(found, "expected migrated column {column}");
    }
}

#[test]
fn sender_priority_table_is_initialized_and_deleted_tables_are_dropped() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let connection = open_db(&config).expect("db");

    let names = ["sender_priorities"];
    for name in names {
        let count = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .expect("table count");
        assert_eq!(count, 1, "expected table {name} to exist");
    }
    for name in ["deleted_messages", "deleted_message_attachments"] {
        let count = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .expect("table count");
        assert_eq!(count, 0, "expected table {name} to stay absent");
    }
}

#[test]
fn message_catalog_and_progress_snapshot_tables_are_initialized() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let connection = open_db(&config).expect("db");

    let names = [
        "account_progress_snapshots",
        "message_catalog",
        "message_mailbox_instances",
    ];
    for name in names {
        let count = connection
            .query_row(
                "SELECT COUNT(*) FROM sqlite_master WHERE type = 'table' AND name = ?1",
                params![name],
                |row| row.get::<_, i64>(0),
            )
            .expect("table count");
        assert_eq!(count, 1, "expected table {name} to exist");
    }
}

#[test]
fn sync_refreshes_attachment_catalog_and_exposes_unsaved_items() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <catalog@example.com>\nFrom: Billing <billing@example.com>\nSubject: Invoice ready\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        assert_eq!(count_attachment_catalog_rows(&config), 1);
        let item = first_attachment_item(&config, "alice");
        assert_eq!(item.attachment.original_filename, "invoice.pdf");
        assert!(item.attachment.blob_relpath.is_some());
        assert_eq!(item.message.subject, "Invoice ready");
    });
}

#[test]
fn attachment_page_and_bulk_download_respect_sender_priority_filter() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-low",
                "Message-ID: <attach-low@example.com>\nFrom: Billing <billing@example.com>\nSubject: Low attachment\nDate: Sat, 20 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-normal",
                "Message-ID: <attach-normal@example.com>\nFrom: Normal <alerts@news.example.com>\nSubject: Normal attachment\nDate: Fri, 19 Apr 2024 14:32:00 +0000\n\nATTACH:text\n",
            );
        upsert_sender_priority_rule(&config, "alice", "domain", "example.com", "low")
            .expect("domain low");

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let low_page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                q: None,
                account_id: None,
                priority: Some("low".to_string()),
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                page: None,
                flash: None,
                error: None,
                ..Default::default()
            },
        )
        .expect("low page");
        assert_eq!(low_page.items.len(), 1);
        assert_eq!(low_page.items[0].message.subject, "Low attachment");
        assert_eq!(
            low_page.items[0].sender_priority.priority,
            SenderPriority::Low
        );

        let keys = download_attachment_keys_for_form(
            &config,
            "alice",
            &AttachmentDownloadForm {
                attachment_keys: Vec::new(),
                selection_scope: Some(ATTACHMENT_SELECTION_ALL_MATCHING.to_string()),
                q: None,
                account_id: None,
                priority: Some("low".to_string()),
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                return_to: None,
                ..Default::default()
            },
        )
        .expect("bulk keys");
        assert_eq!(
            keys,
            vec![low_page.items[0].attachment.attachment_key.clone()]
        );
    });
}

#[test]
fn extracted_textfile_body_parts_are_hidden_by_default() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <body-parts@example.com>\nSubject: Body parts\nDate: Fri, 01 May 2026 09:00:00 +0000\n\nATTACH:body-parts\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");
        assert_eq!(count_attachment_catalog_rows(&config), 3);

        let default_page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                page: None,
                flash: None,
                error: None,
                ..Default::default()
            },
        )
        .expect("default page");
        assert!(default_page.items.is_empty());
        assert_eq!(default_page.state.result_count, 0);

        let included_page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: Some("1".to_string()),
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                page: None,
                flash: None,
                error: None,
                ..Default::default()
            },
        )
        .expect("included page");
        assert_eq!(included_page.state.result_count, 3);
        assert!(included_page
            .items
            .iter()
            .all(|item| item.attachment.is_inline_artifact));
    });
}

#[test]
fn inline_images_are_excluded_by_default_and_can_be_included() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
            &account_paths,
            "Inbox/cur/msg-1",
            concat!(
                "Message-ID: <inline-image@example.com>\n",
                "Subject: Inline image\n",
                "Date: Fri, 01 May 2026 09:00:00 +0000\n",
                "MIME-Version: 1.0\n",
                "Content-Type: multipart/related; boundary=\"b\"\n",
                "\n",
                "--b\n",
                "Content-Type: text/html; charset=utf-8\n\n",
                "<img src=\"cid:logo\">\n",
                "--b\n",
                "Content-Type: image/png; name=\"logo ✅.png\"\n",
                "Content-Disposition: inline; filename=\"logo ✅.png\"\n",
                "Content-ID: <logo>\n",
                "\n",
                "inline image bytes\n",
                "--b--\n",
            ),
        );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");
        assert_eq!(count_attachment_catalog_rows(&config), 1);

        let default_page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                page: None,
                flash: None,
                error: None,
                ..Default::default()
            },
        )
        .expect("default page");
        assert!(default_page.items.is_empty());

        let included_page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: None,
                include_inline_images: Some("1".to_string()),
                show_mime_details: None,
                download_subfolder: None,
                page: None,
                flash: None,
                error: None,
                ..Default::default()
            },
        )
        .expect("included page");
        assert_eq!(included_page.items.len(), 1);
        assert_eq!(
            included_page.items[0].attachment.original_filename,
            "logo ✅.png"
        );
        assert!(attachment_is_inline_image(
            &included_page.items[0].attachment
        ));
    });
}

#[test]
fn attachment_verification_checks_materialized_blobs() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
            &account_paths,
            "Inbox/cur/msg-1",
            "Message-ID: <verify@example.com>\nSubject: Verify\n\nATTACH:pdf\n",
        );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let report_path = tempdir.path().join("report.json");
        let report = verify_attachment_archive(&config, true, Some(&report_path)).expect("verify");
        assert_eq!(report.attachments_checked, 1);
        assert!(!report.has_errors());
        assert!(report_path.exists());
    });
}

#[test]
fn sync_builds_visible_mailbox_mirror_and_progress_snapshot() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        let hidden_path = write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <mirror@example.com>\nSubject: Friendly invoice\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        assert_eq!(count_message_catalog_rows(&config), 1);
        let snapshot = load_account_progress_snapshot_for_test(&config, account_id);
        assert_eq!(snapshot.snapshot_status, "ready");
        assert_eq!(snapshot.archived_message_count, 1);

        let visible_filename = visible_message_filename(
            1_713_450_720,
            "Friendly invoice",
            "message-id:mirror@example.com",
        );
        let visible_path = account_paths
            .visible_emails_root
            .join("personal-gmail-inbox/2024/04")
            .join(visible_filename);
        assert!(visible_path.exists());
        assert!(same_file_identity(&hidden_path, &visible_path).expect("same inode"));
    });
}

#[test]
fn sync_applies_visible_mirror_read_acl_to_new_and_existing_hard_links() {
    with_stubbed_path(&mail_export_acl_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let log_path = tempdir.path().join("setfacl.log");
        env::set_var("SETFACL_LOG", &log_path);
        let mut config = test_config(&tempdir);
        config.visible_mirror_read_group = Some(Arc::<str>::from("filestash"));
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        let hidden_path = write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-acl",
                "Message-ID: <acl@example.com>\nSubject: ACL repair\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("initial sync");
        let visible_filename =
            visible_message_filename(1_713_450_720, "ACL repair", "message-id:acl@example.com");
        let visible_path = account_paths
            .visible_emails_root
            .join("personal-gmail-inbox/2024/04")
            .join(&visible_filename);
        assert!(same_file_identity(&hidden_path, &visible_path).expect("same inode"));

        fs::write(&log_path, "").expect("clear acl log");
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Reindex)
            .expect("reindex repairs acl");

        let log = fs::read_to_string(&log_path).expect("acl log");
        assert!(log.contains("g:filestash:r--"));
        assert!(log.contains(visible_path.to_string_lossy().as_ref()));
        assert!(log.contains("g:filestash:r-x"));
        assert!(!log.contains(".internal-sync"));
        env::remove_var("SETFACL_LOG");
    });
}

#[test]
fn visible_mirror_acl_failure_fails_sync_reconciliation() {
    with_stubbed_path(&mail_export_failing_acl_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        config.visible_mirror_read_group = Some(Arc::<str>::from("filestash"));
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-acl-fail",
                "Message-ID: <acl-fail@example.com>\nSubject: ACL fail\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nbody\n",
            );

        let error = run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect_err("sync should fail when visible mirror acl cannot be applied");

        assert_eq!(error.code, "mailbox_mirror_rebuild_failed");
        assert!(error.detail.contains("setfacl denied"));
    });
}
#[test]
fn attachment_lookup_is_scoped_to_the_authenticated_user() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let alice_account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let bob_account_id = seed_account_with_flags(&config, "bob", "secret", true);
        let alice_account = read_account(&config, "alice", alice_account_id);
        let bob_account = read_account(&config, "bob", bob_account_id);
        let alice_paths = ensure_account_paths(&config, &alice_account).expect("alice paths");
        let bob_paths = ensure_account_paths(&config, &bob_account).expect("bob paths");
        write_maildir_message(
            &alice_paths,
            "Inbox/cur/msg-1",
            "Message-ID: <alice-only@example.com>\n\nATTACH:pdf\n",
        );
        write_maildir_message(
            &bob_paths,
            "Inbox/cur/msg-1",
            "Message-ID: <bob@example.com>\n\n1\n",
        );

        run_account_action_for_user(&config, "alice", alice_account_id, AccountAction::Sync)
            .expect("alice sync");
        run_account_action_for_user(&config, "bob", bob_account_id, AccountAction::Sync)
            .expect("bob sync");

        let item = first_attachment_item(&config, "alice");
        assert!(load_attachment_for_user(&config, "bob", &item.attachment.attachment_key).is_err());
    });
}

#[test]
fn attachments_page_renders_bulk_download_controls_without_action_state() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <render@example.com>\nFrom: Render Sender <render@example.com>\n\nATTACH:pdf-and-zip\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                page: None,
                flash: None,
                error: None,
                ..Default::default()
            },
        )
        .expect("page");
        let html = render_attachments_page(&sample_identity(), &page, None, None);
        assert!(!html.contains("save_state"));
        assert!(!html.contains("/save/files"));
        assert!(!html.contains("/save/paperless"));
        assert!(html.contains("aria-label=\"Download selected attachments\""));
        assert!(html.contains("aria-label=\"Send selected attachments to Paperless\""));
        assert!(html.contains("href=\"/attachments?q=\""));
        assert!(!html.contains("href=\"/attachments\" title=\"Reset filters\""));
        assert!(html.contains("title=\"Download attachment locally\""));
        assert!(html.contains("/attachments/send-paperless"));
        assert!(html.contains("data-attachment-row"));
        assert!(html.contains("data-attachment-key"));
        assert!(html.contains("priority-select-normal"));
        assert!(!html.contains("Find files in saved mail."));
        assert!(html.contains("attachment-list-header"));
        assert!(html.contains("<span>Date</span>"));
        assert!(!html.contains("<span>Select</span>"));
        assert!(!html.contains("<span>Tags</span>"));
        assert!(html.contains("Sender importance"));
        assert!(html.contains("name=\"priority\""));
        assert!(html.contains("basic-filter-column"));
        assert!(html.contains("attachment-control-column"));
        assert!(!html.contains("Selected mailbox"));
        assert!(html.contains("Filter presets"));
        assert!(html.contains("Reset filters"));
        assert!(!html.contains("Select page"));
        assert!(!html.contains("Refresh attachment list"));
        assert!(html.contains("results selected"));
        assert!(!html.contains("attachments matching the current view"));
        assert!(html.contains("class=\"attachment-context\" hidden"));
        assert!(!html.contains(">Email context<"));
        assert!(html.contains("id=\"attachment-advanced-dialog\""));
        assert!(html.contains("data-open-dialog=\"attachment-advanced-dialog\""));
        assert!(!html.contains("<summary>Basic filters</summary>"));
        assert!(html.contains("<select name=\"extension\">"));
        assert!(html.contains("<option value=\"pdf\""));
        assert!(html.contains("name=\"extension_custom\""));
        assert!(!html.contains("name=\"has_attachments\""));
        assert!(!html.contains("name=\"mime_type\""));
        assert!(!html.contains("name=\"min_attachments\""));
        assert!(!html.contains("name=\"max_attachments\""));
        assert!(html.contains("Technical file type"));
        assert!(!html.contains("Min attachments"));
        assert!(!html.contains("Max attachments"));
        assert!(!html.contains("<span>Source</span>"));
        assert!(html.contains("Source: "));
        assert!(!html.contains("Search and download archived mail attachments."));
        assert!(!html.contains("Delete local archive copy"));
        assert!(!html.contains("Restore on next sync"));
        assert!(!html.contains("/messages/"));
    });
}

#[test]
fn attachment_filter_presets_are_user_scoped_and_rendered() {
    let tempdir = TempDir::new().expect("tempdir");
    let config = test_config(&tempdir);
    prepare_test_layout(&config);
    let preset = save_attachment_filter_preset_for_user(
        &config,
        "alice",
        &AttachmentPresetSaveForm {
            preset_name: "  Invoices  ".to_string(),
            q: Some("rent review".to_string()),
            priority: Some("high".to_string()),
            extension: Some("PDF".to_string()),
            include_inline: Some("1".to_string()),
            download_subfolder: Some("Invoices".to_string()),
            ..Default::default()
        },
    )
    .expect("save preset");

    assert_eq!(preset.name, "Invoices");
    assert!(preset.query.contains("q=rent+review"));
    assert!(preset.query.contains("priority=high"));
    assert!(preset.query.contains("extension=pdf"));
    assert!(preset.query.contains("include_inline=1"));
    assert!(preset.query.contains("download_subfolder=Invoices"));
    assert!(list_attachment_filter_presets(&config, "bob")
        .expect("bob presets")
        .is_empty());

    let page = load_attachment_page_data(&config, "alice", &AttachmentListParams::default())
        .expect("page");
    let html = render_attachments_page(&sample_identity(), &page, None, None);
    assert!(html.contains("Invoices"));
    assert!(html.contains("/attachments/presets/delete"));
    assert!(html.contains("Auto-export to Paperless"));
    assert!(html.contains("q=rent+review"));
}

#[test]
fn attachment_preset_updates_and_delete_cascade_to_auto_export_task() {
    let tempdir = TempDir::new().expect("tempdir");
    let mut config = test_config(&tempdir);
    configure_test_paperless_handoff(&mut config, &tempdir);
    prepare_test_layout(&config);

    save_attachment_filter_preset_for_user(
        &config,
        "alice",
        &AttachmentPresetSaveForm {
            preset_name: "Invoices".to_string(),
            q: Some("old filter".to_string()),
            ..Default::default()
        },
    )
    .expect("save preset");
    let task = save_attachment_paperless_task_for_user(
        &config,
        "alice",
        &AttachmentPaperlessTaskSaveForm {
            task_name: "Invoices".to_string(),
            schedule_time: "06:30".to_string(),
            q: Some("old filter".to_string()),
            ..Default::default()
        },
    )
    .expect("save task");

    let preset = save_attachment_filter_preset_for_user(
        &config,
        "alice",
        &AttachmentPresetSaveForm {
            preset_name: "Invoices".to_string(),
            q: Some("new filter".to_string()),
            ..Default::default()
        },
    )
    .expect("update preset");
    let updated_task_query = open_db(&config)
        .expect("db")
        .query_row(
            "SELECT query FROM attachment_paperless_tasks WHERE id = ?1",
            params![task.id],
            |row| row.get::<_, String>(0),
        )
        .expect("task query");
    assert!(updated_task_query.contains("q=new+filter"));

    delete_attachment_filter_preset_for_user(&config, "alice", preset.id).expect("delete preset");
    let task_count = open_db(&config)
        .expect("db")
        .query_row(
            "SELECT COUNT(*) FROM attachment_paperless_tasks WHERE username = ?1 AND name = ?2",
            params!["alice", "Invoices"],
            |row| row.get::<_, i64>(0),
        )
        .expect("task count");
    assert_eq!(task_count, 0);
}

#[test]
fn paperless_consume_filename_removes_generated_mail_archive_prefix() {
    assert_eq!(
        paperless_consume_filename(
            "mail-archive-20260517-121917-40f5e5d32565ade4-Statement #95 - OWN02063 .pdf"
        ),
        "Statement #95 - OWN02063 .pdf"
    );
    assert_eq!(
        paperless_consume_filename("Statement #95 - OWN02063 .pdf"),
        "Statement #95 - OWN02063 .pdf"
    );
}

#[test]
fn daily_paperless_task_sends_matching_attachments() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-task",
                "Message-ID: <paperless-task@example.com>\nFrom: Docs <docs@example.com>\nSubject: Paperless invoice\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let task = save_attachment_paperless_task_for_user(
            &config,
            "alice",
            &AttachmentPaperlessTaskSaveForm {
                task_name: "Invoices".to_string(),
                schedule_time: "00:00".to_string(),
                subject: Some("invoice".to_string()),
                extension: Some("pdf".to_string()),
                ..Default::default()
            },
        )
        .expect("save task");
        assert!(task.enabled);
        assert_eq!(task.schedule_time, "00:00");

        let had_errors = run_due_paperless_tasks(&config).expect("run tasks");
        assert!(!had_errors);

        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        assert!(consume_root.join("invoice.pdf").is_file());
        let tasks = list_attachment_paperless_tasks(&config, "alice").expect("tasks");
        assert_eq!(tasks.len(), 1);
        assert!(tasks[0].last_run_date.is_some());
        assert_eq!(
            tasks[0].last_summary.as_deref(),
            Some("1 attachment sent to Paperless")
        );
        assert_eq!(tasks[0].last_status.as_deref(), Some("success"));
        assert_eq!(tasks[0].successful_runs, 1);
        let run_count = open_db(&config)
            .expect("db")
            .query_row(
                "SELECT COUNT(*) FROM attachment_paperless_task_runs WHERE task_id = ?1",
                params![task.id],
                |row| row.get::<_, i64>(0),
            )
            .expect("run history");
        assert_eq!(run_count, 1);
    });
}

#[test]
fn paperless_task_custom_schedule_is_validated_and_execution_is_leased() {
    let tempdir = TempDir::new().expect("tempdir");
    let mut config = test_config(&tempdir);
    configure_test_paperless_handoff(&mut config, &tempdir);
    prepare_test_layout(&config);

    let task = save_attachment_paperless_task_for_user(
        &config,
        "alice",
        &AttachmentPaperlessTaskSaveForm {
            task_name: "Frequent invoices".to_string(),
            schedule_time: "06:30".to_string(),
            schedule_mode: Some("interval".to_string()),
            interval_minutes: Some("30".to_string()),
            paperless_max_documents: Some("37".to_string()),
            retry_enabled: Some("0".to_string()),
            subject: Some("invoice".to_string()),
            ..Default::default()
        },
    )
    .expect("save task");

    assert_eq!(task.schedule_mode, "interval");
    assert_eq!(task.interval_minutes, 30);
    assert_eq!(task.max_attachments, 37);
    assert!(!task.retry_enabled);
    assert!(due_paperless_tasks(&config)
        .expect("due tasks")
        .iter()
        .any(|candidate| candidate.id == task.id));
    assert!(claim_paperless_task(&config, task.id).expect("first claim"));
    assert!(!claim_paperless_task(&config, task.id).expect("duplicate claim"));

    assert!(normalize_paperless_schedule(Some("interval"), Some("14")).is_err());
    assert!(normalize_paperless_task_max_attachments(Some("2001")).is_err());
    assert!(normalize_paperless_task_max_attachments(Some("many")).is_err());
}

#[test]
fn failed_paperless_task_records_history_and_exponential_retry() {
    let tempdir = TempDir::new().expect("tempdir");
    let mut config = test_config(&tempdir);
    configure_test_paperless_handoff(&mut config, &tempdir);
    prepare_test_layout(&config);

    let task = save_attachment_paperless_task_for_user(
        &config,
        "alice",
        &AttachmentPaperlessTaskSaveForm {
            task_name: "Retry invoices".to_string(),
            schedule_time: "00:00".to_string(),
            subject: Some("invoice".to_string()),
            ..Default::default()
        },
    )
    .expect("save task");
    assert!(claim_paperless_task(&config, task.id).expect("claim"));
    let started_at = Utc::now().to_rfc3339();
    record_paperless_task_run(
        &config,
        &task,
        &started_at,
        &Local::now().format("%Y-%m-%d").to_string(),
        &PaperlessTaskRunResult {
            status: "failed",
            summary: "Failed: temporary consume error".to_string(),
            handoff: PaperlessHandoffSummary::default(),
        },
    )
    .expect("record failure");

    let updated = list_attachment_paperless_tasks(&config, "alice")
        .expect("tasks")
        .remove(0);
    assert_eq!(updated.last_status.as_deref(), Some("failed"));
    assert_eq!(updated.consecutive_failures, 1);
    assert_eq!(updated.failed_runs, 1);
    assert!(updated.next_retry_at.is_some());
    assert!(due_paperless_tasks(&config)
        .expect("due tasks")
        .iter()
        .all(|candidate| candidate.id != task.id));
    assert_eq!(paperless_retry_delay_minutes(1), 5);
    assert_eq!(paperless_retry_delay_minutes(2), 10);
    assert_eq!(paperless_retry_delay_minutes(20), 360);
}

#[test]
fn attachment_search_filters_by_structured_fields_and_paperless_handoff_records_state() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <paperless@example.com>\nFrom: Docs <docs@example.com>\nSubject: Paperless invoice\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf-and-zip\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("invoice".to_string()),
                sender_address: Some("docs@example.com".to_string()),
                attachment_name: Some("invoice".to_string()),
                extension: Some("pdf".to_string()),
                mime_type: Some("pdf".to_string()),
                min_attachments: Some("2".to_string()),
                max_attachments: Some("2".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        assert_eq!(page.items.len(), 1);
        let key = page.items[0].attachment.attachment_key.clone();

        let sent = send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&key))
            .expect("send");
        assert_eq!(sent.sent, 1);
        assert!(sent.failures.is_empty());
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        let consume_files = fs::read_dir(&consume_root)
            .expect("consume dir")
            .collect::<Result<Vec<_>, _>>()
            .expect("consume files");
        assert_eq!(consume_files.len(), 1);
        assert_eq!(
            consume_files[0].file_name().to_string_lossy(),
            "invoice.pdf"
        );
        assert!(!consume_files[0]
            .file_name()
            .to_string_lossy()
            .starts_with("mail-archive-"));
        let staging_root = PathBuf::from(config.paperless_handoff_staging_root.as_deref().unwrap());
        assert_eq!(
            fs::read_dir(&staging_root)
                .expect("staging dir")
                .collect::<Result<Vec<_>, _>>()
                .expect("staging files")
                .len(),
            0
        );
        let recorded_consume_filename = open_db(&config)
                .expect("db")
                .query_row(
                    "SELECT consume_filename FROM attachment_paperless_handoffs WHERE attachment_key = ?1",
                    params![key],
                    |row| row.get::<_, String>(0),
                )
                .expect("handoff filename");
        assert_eq!(recorded_consume_filename, "invoice.pdf");

        let refreshed = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                attachment_name: Some("invoice".to_string()),
                extension: Some("pdf".to_string()),
                ..Default::default()
            },
        )
        .expect("refreshed page");
        assert!(refreshed.items[0].paperless_sent_at.is_some());
        let html = render_attachment_item(&refreshed.items[0], "/attachments", false);
        assert!(html.contains("Successfully sent to Paperless on"));
        assert!(html.contains("paperless-sent-button"));

        let repeated = send_attachments_to_paperless(&config, "alice", &[key])
            .expect("repeated handoff is idempotent");
        assert_eq!(repeated.sent, 0);
        assert_eq!(repeated.already_uploaded, 1);
        assert!(repeated.failures.is_empty());
    });
}

#[test]
fn consumed_paperless_handoff_records_remain_marked_sent() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <consumed-paperless@example.com>\nFrom: Docs <docs@example.com>\nSubject: Consumed Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Consumed Paperless".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        assert_eq!(page.items.len(), 1);
        let key = page.items[0].attachment.attachment_key.clone();
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        fs::create_dir_all(&consume_root).expect("consume root");

        let connection = open_db(&config).expect("db");
        connection
                .execute(
                    "INSERT OR REPLACE INTO attachment_paperless_handoffs (username, attachment_key, attachment_sha256, original_filename, consume_filename, sent_at) VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
                    params![
                        "alice",
                        &key,
                        page.items[0].attachment.attachment_sha256,
                        page.items[0].attachment.original_filename,
                        "invoice.pdf",
                        Utc::now().to_rfc3339(),
                    ],
                )
                .expect("manual handoff insert");

        let reloaded = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Consumed Paperless".to_string()),
                ..Default::default()
            },
        )
        .expect("reloaded page");
        assert!(reloaded.items[0].paperless_sent_at.is_some());

        let remaining = connection
                .query_row(
                    "SELECT COUNT(*) FROM attachment_paperless_handoffs WHERE username = ?1 AND attachment_key = ?2",
                    params!["alice", &key],
                    |row| row.get::<_, i64>(0),
                )
                .expect("handoff row check");
        assert_eq!(remaining, 1);

        let repeated = send_attachments_to_paperless(&config, "alice", &[key])
            .expect("consumed handoff remains idempotent");
        assert_eq!(repeated.already_uploaded, 1);
        assert!(repeated.failures.is_empty());
    });
}

#[test]
fn paperless_handoff_fails_closed_when_duplicate_snapshot_is_unavailable() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        config.paperless_database_path = Some(Arc::from(
            tempdir
                .path()
                .join("missing-paperless-snapshot.sqlite3")
                .to_string_lossy()
                .to_string(),
        ));
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <missing-paperless-snapshot@example.com>\nSubject: Snapshot unavailable\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");
        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Snapshot unavailable".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        let key = page.items[0].attachment.attachment_key.clone();

        let error = send_attachments_to_paperless(&config, "alice", &[key])
            .expect_err("missing snapshot must block publication");
        assert!(error.contains("duplicate-check snapshot is unavailable"));
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        assert_eq!(
            fs::read_dir(consume_root)
                .expect("consume directory")
                .count(),
            0
        );
    });
}

#[test]
fn paperless_handoff_lock_prevents_concurrent_duplicate_publication() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <concurrent-paperless@example.com>\nSubject: Concurrent Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");
        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Concurrent Paperless".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        let key = page.items[0].attachment.attachment_key.clone();
        let lock = acquire_paperless_handoff_lock(&config, "alice", &key).expect("lock");

        let blocked = send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&key))
            .expect("blocked handoff summary");
        assert_eq!(blocked.sent, 0);
        assert_eq!(blocked.failures.len(), 1);
        assert!(blocked.failures[0].error.contains("already being sent"));
        drop(lock);

        let sent = send_attachments_to_paperless(&config, "alice", &[key])
            .expect("handoff after lock release");
        assert_eq!(sent.sent, 1);
        assert!(sent.failures.is_empty());
    });
}

#[test]
fn paperless_handoff_records_same_hash_attachments_as_already_uploaded() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <already-paperless-1@example.com>\nSubject: Existing Paperless One\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-2",
                "Message-ID: <already-paperless-2@example.com>\nSubject: Existing Paperless Two\nDate: Fri, 19 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Existing Paperless".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        assert_eq!(page.items.len(), 2);
        let first_key = page.items[0].attachment.attachment_key.clone();
        let second_key = page.items[1].attachment.attachment_key.clone();

        let first_summary =
            send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&first_key))
                .expect("first send");
        assert_eq!(first_summary.sent, 1);

        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        fs::remove_file(consume_root.join("invoice.pdf")).expect("simulate paperless consume");

        let second_summary =
            send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&second_key))
                .expect("same hash already uploaded");
        assert_eq!(second_summary.sent, 0);
        assert_eq!(second_summary.already_uploaded, 1);
        assert!(second_summary.sent_attachment_keys.contains(&second_key));
        assert!(!consume_root.join("invoice.pdf").exists());
        let handoff_count = open_db(&config)
            .expect("db")
            .query_row(
                "SELECT COUNT(*) FROM attachment_paperless_handoffs",
                [],
                |row| row.get::<_, i64>(0),
            )
            .expect("handoff count");
        assert_eq!(handoff_count, 2);
    });
}

#[test]
fn paperless_handoff_records_matching_pending_consume_file_as_already_uploaded() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <pending-paperless@example.com>\nSubject: Pending Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Pending Paperless".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        assert_eq!(page.items.len(), 1);
        let key = page.items[0].attachment.attachment_key.clone();
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        fs::create_dir_all(&consume_root).expect("consume root");
        fs::write(consume_root.join("invoice.pdf"), b"pdf payload\n").expect("pending invoice");

        let summary = send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&key))
            .expect("pending already uploaded");
        assert_eq!(summary.sent, 0);
        assert_eq!(summary.already_uploaded, 1);
        assert!(summary.sent_attachment_keys.contains(&key));
        assert_eq!(
            fs::read(consume_root.join("invoice.pdf")).expect("invoice"),
            b"pdf payload\n"
        );
        assert_eq!(
            fs::read_dir(&consume_root)
                .expect("consume dir")
                .collect::<Result<Vec<_>, _>>()
                .expect("consume files")
                .len(),
            1
        );
    });
}

#[test]
fn paperless_handoff_detects_matching_pending_consume_file_with_different_name() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <pending-renamed-paperless@example.com>\nSubject: Pending Renamed Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Pending Renamed Paperless".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        let key = page.items[0].attachment.attachment_key.clone();
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        fs::create_dir_all(&consume_root).expect("consume root");
        fs::write(consume_root.join("renamed-upload.pdf"), b"pdf payload\n")
            .expect("pending invoice");

        let summary = send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&key))
            .expect("pending already uploaded");
        assert_eq!(summary.sent, 0);
        assert_eq!(summary.already_uploaded, 1);
        assert!(summary.sent_attachment_keys.contains(&key));
        assert!(consume_root.join("renamed-upload.pdf").is_file());
        assert!(!consume_root.join("invoice.pdf").exists());
    });
}

#[test]
fn paperless_handoff_detects_existing_paperless_document_checksum() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        let paperless_db = configure_test_paperless_database(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <existing-paperless-db@example.com>\nSubject: Existing Paperless DB\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Existing Paperless DB".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        let key = page.items[0].attachment.attachment_key.clone();
        let (_account, _message, attachment) =
            load_attachment_for_user(&config, "alice", &key).expect("attachment");
        let blob_path = account_paths
            .hidden_sync_root
            .join(attachment.blob_relpath.as_deref().expect("blob"));
        let checksum = md5_file(&blob_path).expect("md5");
        Connection::open(&paperless_db)
                .expect("paperless db")
                .execute(
                    "INSERT INTO documents_document (id, title, checksum, archive_checksum, deleted_at) VALUES (?1, ?2, ?3, NULL, NULL)",
                    params![42_i64, "Existing Paperless DB", checksum],
                )
                .expect("paperless document");

        let summary = send_attachments_to_paperless(&config, "alice", std::slice::from_ref(&key))
            .expect("paperless checksum already uploaded");
        assert_eq!(summary.sent, 0);
        assert_eq!(summary.already_uploaded, 1);
        assert!(summary.sent_attachment_keys.contains(&key));
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        assert!(!consume_root.join("invoice.pdf").exists());
        let recorded_consume_filename = open_db(&config)
                .expect("db")
                .query_row(
                    "SELECT consume_filename FROM attachment_paperless_handoffs WHERE attachment_key = ?1",
                    params![key],
                    |row| row.get::<_, String>(0),
                )
                .expect("handoff filename");
        assert_eq!(recorded_consume_filename, "paperless-document-42");
    });
}

#[test]
fn bulk_paperless_handoff_uses_suffix_when_consume_name_exists() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <bulk-paperless@example.com>\nFrom: Docs <docs@example.com>\nSubject: Bulk Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf-and-zip\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                subject: Some("Bulk Paperless".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        let keys = page
            .items
            .iter()
            .map(|item| item.attachment.attachment_key.clone())
            .collect::<Vec<_>>();
        assert_eq!(keys.len(), 2);
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        fs::create_dir_all(&consume_root).expect("consume root");
        fs::write(consume_root.join("invoice.pdf"), b"existing").expect("existing invoice");

        let summary = send_attachments_to_paperless(&config, "alice", &keys).expect("send");

        assert_eq!(summary.sent, 2);
        assert!(summary.failures.is_empty());
        assert!(consume_root.join("archive.zip").is_file());
        assert!(consume_root.join("invoice (2).pdf").is_file());
        assert_eq!(
            fs::read(consume_root.join("invoice.pdf")).expect("invoice"),
            b"existing"
        );
    });
}

#[test]
fn paperless_task_batch_limit_advances_past_prior_handoffs() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-batched",
                "Message-ID: <batched-paperless@example.com>\nSubject: Batched Paperless\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf-and-zip\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let first =
            send_attachment_filter_to_paperless(&config, "alice", "subject=Batched+Paperless", 1)
                .expect("first batch");
        let second =
            send_attachment_filter_to_paperless(&config, "alice", "subject=Batched+Paperless", 1)
                .expect("second batch");
        let finished =
            send_attachment_filter_to_paperless(&config, "alice", "subject=Batched+Paperless", 1)
                .expect("finished batch");

        assert_eq!(first.sent, 1);
        assert_eq!(second.sent, 1);
        assert_eq!(finished.sent, 0);
        assert!(finished.failures.is_empty());
    });
}

#[test]
fn duplicate_paperless_filenames_get_readable_suffixes() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let mut config = test_config(&tempdir);
        configure_test_paperless_handoff(&mut config, &tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <duplicate-paperless-1@example.com>\nSubject: Duplicate One\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-2",
                "Message-ID: <duplicate-paperless-2@example.com>\nSubject: Duplicate Two\nDate: Fri, 19 Apr 2024 14:32:00 +0000\n\nATTACH:duplicate-pdf\n",
            );
        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");

        let page = load_attachment_page_data(
            &config,
            "alice",
            &AttachmentListParams {
                attachment_name: Some("invoice".to_string()),
                ..Default::default()
            },
        )
        .expect("page");
        let keys = page
            .items
            .iter()
            .map(|item| item.attachment.attachment_key.clone())
            .collect::<Vec<_>>();
        assert_eq!(keys.len(), 2);

        let summary = send_attachments_to_paperless(&config, "alice", &keys).expect("send");

        assert_eq!(summary.sent, 2);
        assert!(summary.failures.is_empty());
        let consume_root = PathBuf::from(config.paperless_consume_root.as_deref().unwrap());
        let consume_files = fs::read_dir(&consume_root)
            .expect("consume dir")
            .collect::<Result<Vec<_>, _>>()
            .expect("consume files");
        let mut consume_filenames = consume_files
            .iter()
            .map(|entry| entry.file_name().to_string_lossy().to_string())
            .collect::<Vec<_>>();
        consume_filenames.sort();
        assert_eq!(consume_filenames, vec!["invoice (2).pdf", "invoice.pdf"]);
    });
}

#[test]
fn paperless_handoff_staging_cleanup_only_removes_old_tmp_files() {
    let tempdir = TempDir::new().expect("tempdir");
    let staging_root = tempdir.path().join("staging");
    fs::create_dir_all(&staging_root).expect("staging root");
    let stale_tmp = staging_root.join(".mail-archive-old.tmp");
    let keep_txt = staging_root.join("mail-archive-old.tmp");
    let keep_other = staging_root.join(".mail-archive-old.txt");
    fs::write(&stale_tmp, b"stale").expect("stale");
    fs::write(&keep_txt, b"keep").expect("keep txt");
    fs::write(&keep_other, b"keep").expect("keep other");

    cleanup_paperless_handoff_staging_older_than(&staging_root, -1).expect("cleanup");

    assert!(!stale_tmp.exists());
    assert!(keep_txt.exists());
    assert!(keep_other.exists());
}

#[test]
fn selected_attachment_keys_build_download_zip() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
                &account_paths,
                "Inbox/cur/msg-1",
                "Message-ID: <zip@example.com>\nSubject: Zip ✅\nDate: Thu, 18 Apr 2024 14:32:00 +0000\n\nATTACH:pdf\n",
            );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");
        let item = first_attachment_item(&config, "alice");
        let zip_file = build_attachments_zip(
            &config,
            "alice",
            &AttachmentDownloadForm {
                attachment_keys: vec![item.attachment.attachment_key],
                selection_scope: None,
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: None,
                return_to: None,
                ..Default::default()
            },
        )
        .expect("zip");

        let file = fs::File::open(&zip_file.path).expect("zip file");
        let mut archive = zip::ZipArchive::new(file).expect("archive");
        assert_eq!(archive.len(), 2);
        let entry = archive.by_index(0).expect("entry");
        assert_eq!(
            entry.name(),
            "Personal Gmail/2024-04-18 - Zip ✅/invoice.pdf"
        );
        drop(entry);
        assert!(archive.by_name("manifest.json").is_ok());
    });
}

#[test]
fn attachment_action_forms_accept_single_and_repeated_keys() {
    let single_download =
        parse_attachment_download_form_body(b"attachment_keys=one&return_to=%2Fattachments");
    assert_eq!(single_download.attachment_keys, vec!["one".to_string()]);
    assert_eq!(single_download.return_to.as_deref(), Some("/attachments"));

    let repeated_download = parse_attachment_download_form_body(
        b"attachment_keys=one&attachment_keys=two&selection_scope=all_matching&q=invoice",
    );
    assert_eq!(
        repeated_download.attachment_keys,
        vec!["one".to_string(), "two".to_string()]
    );
    assert_eq!(
        repeated_download.selection_scope.as_deref(),
        Some(ATTACHMENT_SELECTION_ALL_MATCHING)
    );
    assert_eq!(repeated_download.q.as_deref(), Some("invoice"));

    let paperless = parse_attachment_paperless_form_body(
        b"attachment_keys=one&attachment_keys=two&return_to=%2Fattachments%3Fextension%3Dpdf",
    );
    assert_eq!(
        paperless.attachment_keys,
        vec!["one".to_string(), "two".to_string()]
    );
    assert_eq!(
        paperless.return_to.as_deref(),
        Some("/attachments?extension=pdf")
    );
}

#[test]
fn attachment_downloads_preserve_unicode_filenames_and_zip_subfolder() {
    with_stubbed_path(&mail_export_stub_commands(), |_| {
        let tempdir = TempDir::new().expect("tempdir");
        let config = test_config(&tempdir);
        prepare_test_layout(&config);
        let account_id = seed_account_with_flags(&config, "alice", "secret", true);
        let account = read_account(&config, "alice", account_id);
        let account_paths = ensure_account_paths(&config, &account).expect("paths");
        write_maildir_message(
            &account_paths,
            "Inbox/cur/msg-1",
            concat!(
                "Message-ID: <unicode-attachment@example.com>\n",
                "Subject: Résumé ✅ files\n",
                "Date: Thu, 18 Apr 2024 14:32:00 +0000\n",
                "MIME-Version: 1.0\n",
                "Content-Type: multipart/mixed; boundary=\"b\"\n",
                "\n",
                "--b\n",
                "Content-Type: text/plain; charset=utf-8\n\n",
                "body\n",
                "--b\n",
                "Content-Type: application/pdf; name=\"Résumé ✅.pdf\"\n",
                "Content-Disposition: attachment; filename=\"Résumé ✅.pdf\"\n",
                "\n",
                "pdf bytes\n",
                "--b--\n",
            ),
        );

        run_account_action_for_user(&config, "alice", account_id, AccountAction::Sync)
            .expect("sync");
        let item = first_attachment_item(&config, "alice");
        assert_eq!(item.attachment.original_filename, "Résumé ✅.pdf");

        let response = attachment_download_response(
            &item.attachment.original_filename,
            &item.attachment.mime_type,
            Vec::new(),
        );
        let disposition = response
            .headers()
            .get(CONTENT_DISPOSITION)
            .expect("content disposition")
            .to_str()
            .expect("ascii header");
        assert!(disposition.contains("filename=\""));
        assert!(disposition.contains("filename*=UTF-8''R%C3%A9sum%C3%A9%20%E2%9C%85.pdf"));

        let zip_file = build_attachments_zip(
            &config,
            "alice",
            &AttachmentDownloadForm {
                attachment_keys: vec![item.attachment.attachment_key],
                selection_scope: None,
                q: None,
                account_id: None,
                priority: None,
                extension: None,
                include_inline: None,
                include_inline_images: None,
                show_mime_details: None,
                download_subfolder: Some("Downloaded/Invoices ✅".to_string()),
                return_to: None,
                ..Default::default()
            },
        )
        .expect("zip");

        let file = fs::File::open(&zip_file.path).expect("zip file");
        let mut archive = zip::ZipArchive::new(file).expect("archive");
        let entry = archive.by_index(0).expect("entry");
        assert_eq!(
            entry.name(),
            "Downloaded/Invoices ✅/Personal Gmail/2024-04-18 - Résumé ✅ files/Résumé ✅.pdf"
        );
    });
}

#[test]
fn duplicate_zip_entry_names_get_human_numeric_suffixes() {
    let mut used = HashMap::new();
    assert_eq!(
        unique_zip_entry_name(
            "mailbox/2026-05-01 - invoice/report.pdf".to_string(),
            &mut used
        ),
        "mailbox/2026-05-01 - invoice/report.pdf"
    );
    assert_eq!(
        unique_zip_entry_name(
            "mailbox/2026-05-01 - invoice/report.pdf".to_string(),
            &mut used
        ),
        "mailbox/2026-05-01 - invoice/report (1).pdf"
    );
}
