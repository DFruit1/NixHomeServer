use media_manager::{
    catalog::Catalog,
    config::{AppConfig, Identity, RootScope},
};

#[test]
fn personal_roots_resolve_from_the_authenticated_username() {
    let config = AppConfig::for_test("/data/shared", "/data/users");
    let identity = Identity::new("sydney", ["users"]);

    let root = config
        .visible_roots(&identity)
        .into_iter()
        .find(|root| root.id == "personal-videos")
        .expect("personal videos root");

    assert_eq!(root.scope, RootScope::Personal);
    assert_eq!(root.resolved_path, "/data/users/sydney/_Videos");
}

#[test]
fn unsafe_forwarded_usernames_are_rejected_before_path_resolution() {
    assert!(Identity::try_new("../other-user", ["users"]).is_err());
    assert!(Identity::try_new("name/child", ["users"]).is_err());
    assert!(Identity::try_new(".", ["users"]).is_err());
}

#[test]
fn stable_subject_is_distinct_from_the_mutable_path_username() {
    let identity = Identity::try_new_with_subject(
        "kanidm:4689a2b2-62ba-4131-bc32-4cca2ca7859c",
        "sydney",
        ["users"],
    )
    .expect("authenticated identity");

    assert_eq!(
        identity.subject,
        "kanidm:4689a2b2-62ba-4131-bc32-4cca2ca7859c"
    );
    assert_eq!(identity.username, "sydney");
}

#[test]
fn empty_or_control_character_subjects_are_rejected() {
    assert!(Identity::try_new_with_subject("", "sydney", ["users"]).is_err());
    assert!(Identity::try_new_with_subject("subject\nother", "sydney", ["users"]).is_err());
}

#[test]
fn editor_permission_requires_the_dedicated_group() {
    assert!(!Identity::new("viewer", ["users"]).can_edit("media-manager-editors"));
    assert!(Identity::new("editor", ["users", "media-manager-editors"])
        .can_edit("media-manager-editors"));
}

#[test]
fn catalog_initialization_is_repeatable_and_uses_wal() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let path = dir.path().join("control.sqlite3");
    let first = Catalog::initialize(&path).expect("create catalog");
    assert_eq!(first.schema_version().unwrap(), 4);
    assert_eq!(first.get_playback_position("item", "user").unwrap(), None);
    drop(first);
    let second = Catalog::open(&path).expect("reopen catalog");

    assert_eq!(second.schema_version().expect("schema version"), 4);
    assert_eq!(second.journal_mode().expect("journal mode"), "wal");
}

#[test]
fn opening_a_catalog_does_not_need_a_write_lock() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.sqlite3");
    Catalog::initialize(&path).unwrap();
    let writer = rusqlite::Connection::open(&path).unwrap();
    writer.execute_batch("BEGIN IMMEDIATE").unwrap();
    let catalog = Catalog::open(&path).expect("ordinary opens must not migrate");
    assert_eq!(catalog.schema_version().unwrap(), 4);
}

#[test]
fn unsupported_catalog_versions_are_not_modified() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.sqlite3");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch("PRAGMA user_version = 99;")
        .unwrap();
    assert!(Catalog::initialize(&path).is_err());
    assert!(Catalog::open(&path).is_err());
    let count: i64 = connection
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(count, 0);
}

#[test]
fn version_two_catalog_upgrades_in_one_initialization() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.sqlite3");
    Catalog::initialize(&path).unwrap();
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch("DROP TABLE playback_positions; PRAGMA user_version = 2;")
        .unwrap();
    let catalog = Catalog::initialize(&path).unwrap();
    assert_eq!(catalog.schema_version().unwrap(), 4);
    assert_eq!(catalog.get_playback_position("item", "user").unwrap(), None);
}

#[test]
fn version_one_catalog_upgrades_all_steps_and_preserves_plans() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.sqlite3");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE mutation_plans (
            id TEXT PRIMARY KEY, owner_username TEXT NOT NULL, digest TEXT NOT NULL,
            request_json TEXT NOT NULL, state TEXT NOT NULL, created_at TEXT NOT NULL,
            expires_at TEXT NOT NULL
         );
         INSERT INTO mutation_plans VALUES ('plan', 'alice', 'digest', '{}', 'queued',
            '2026-01-01 00:00:00', '2026-01-02 00:00:00');
         PRAGMA user_version = 1;",
        )
        .unwrap();
    let catalog = Catalog::initialize(&path).unwrap();
    assert_eq!(catalog.schema_version().unwrap(), 4);
    assert_eq!(
        catalog.get_playback_position("item", "alice").unwrap(),
        None
    );
    let (state, expires): (String, i64) = connection
        .query_row(
            "SELECT state, expires_at FROM mutation_plans WHERE id = 'plan'",
            [],
            |row| Ok((row.get(0)?, row.get(1)?)),
        )
        .unwrap();
    assert_eq!(state, "rejected");
    assert_eq!(expires, 1767312000);
}

#[test]
fn failed_catalog_migration_rolls_back_schema_and_version() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("control.sqlite3");
    let connection = rusqlite::Connection::open(&path).unwrap();
    connection
        .execute_batch(
            "CREATE TABLE mutation_plans (id TEXT PRIMARY KEY);
         INSERT INTO mutation_plans VALUES ('preserved'); PRAGMA user_version = 1;",
        )
        .unwrap();
    assert!(Catalog::initialize(&path).is_err());
    let version: i64 = connection
        .pragma_query_value(None, "user_version", |row| row.get(0))
        .unwrap();
    assert_eq!(version, 1);
    let tables: i64 = connection
        .query_row(
            "SELECT count(*) FROM sqlite_master WHERE type = 'table'",
            [],
            |row| row.get(0),
        )
        .unwrap();
    assert_eq!(tables, 1);
    let id: String = connection
        .query_row("SELECT id FROM mutation_plans", [], |row| row.get(0))
        .unwrap();
    assert_eq!(id, "preserved");
}
