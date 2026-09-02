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
    let first = Catalog::open(&path).expect("create catalog");
    drop(first);
    let second = Catalog::open(&path).expect("reopen catalog");

    assert_eq!(second.schema_version().expect("schema version"), 3);
    assert_eq!(second.journal_mode().expect("journal mode"), "wal");
}
