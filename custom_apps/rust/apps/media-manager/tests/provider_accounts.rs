use media_manager::{
    config::Identity,
    provider_accounts::{ProviderAccountError, ProviderAccountStore},
};
use rusqlite::Connection;
use std::{collections::BTreeMap, os::unix::fs::PermissionsExt};

fn credentials(entries: &[(&str, &str)]) -> BTreeMap<String, String> {
    entries
        .iter()
        .map(|(key, value)| ((*key).to_string(), (*value).to_string()))
        .collect()
}

#[test]
fn credentials_are_owned_by_subject_not_mutable_username() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let store = ProviderAccountStore::open(
        &temp.path().join("provider-accounts.sqlite3"),
        &temp.path().join("master.key"),
    )
    .expect("provider account store");
    let original = Identity::try_new_with_subject("subject-1", "old-name", ["users"])
        .expect("original identity");
    let renamed = Identity::try_new_with_subject("subject-1", "new-name", ["users"])
        .expect("renamed identity");
    let other =
        Identity::try_new_with_subject("subject-2", "old-name", ["users"]).expect("other identity");

    store
        .save(
            &original,
            "tmdb",
            &credentials(&[("apiKey", "top-secret-key")]),
            100,
        )
        .expect("save credentials");

    assert_eq!(
        store
            .load_credentials(&renamed, "tmdb")
            .expect("renamed lookup"),
        Some(credentials(&[("apiKey", "top-secret-key")]))
    );
    assert_eq!(
        store
            .load_credentials(&other, "tmdb")
            .expect("other lookup"),
        None
    );
    let summaries = store.list(&renamed).expect("account summaries");
    assert_eq!(summaries.len(), 1);
    assert_eq!(summaries[0].owner_username, "old-name");
}

#[test]
fn database_and_master_key_do_not_contain_plaintext_credentials() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = temp.path().join("provider-accounts.sqlite3");
    let key = temp.path().join("master.key");
    let store = ProviderAccountStore::open(&database, &key).expect("provider account store");
    let identity =
        Identity::try_new_with_subject("subject-1", "sydney", ["users"]).expect("identity");

    store
        .save(
            &identity,
            "opensubtitles",
            &credentials(&[
                ("apiKey", "api-key-that-must-not-leak"),
                ("password", "password-that-must-not-leak"),
            ]),
            100,
        )
        .expect("save credentials");
    drop(store);

    let database_bytes = std::fs::read(&database).expect("database bytes");
    let key_bytes = std::fs::read(&key).expect("key bytes");
    for forbidden in [
        b"api-key-that-must-not-leak".as_slice(),
        b"password-that-must-not-leak".as_slice(),
    ] {
        assert!(!database_bytes
            .windows(forbidden.len())
            .any(|w| w == forbidden));
        assert!(!key_bytes.windows(forbidden.len()).any(|w| w == forbidden));
    }
    assert_eq!(
        std::fs::metadata(&key)
            .expect("key metadata")
            .permissions()
            .mode()
            & 0o777,
        0o600
    );
}

#[test]
fn an_existing_master_key_with_group_or_world_access_is_rejected() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = temp.path().join("provider-accounts.sqlite3");
    let key = temp.path().join("master.key");
    std::fs::write(&key, [7_u8; 32]).expect("write key");
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o640))
        .expect("set permissive mode");

    assert!(matches!(
        ProviderAccountStore::open(&database, &key),
        Err(ProviderAccountError::InvalidMasterKey)
    ));
}

#[test]
fn ciphertext_cannot_be_rebound_to_another_provider() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let database = temp.path().join("provider-accounts.sqlite3");
    let store = ProviderAccountStore::open(&database, &temp.path().join("master.key"))
        .expect("provider account store");
    let identity =
        Identity::try_new_with_subject("subject-1", "sydney", ["users"]).expect("identity");
    store
        .save(
            &identity,
            "tmdb",
            &credentials(&[("apiKey", "top-secret-key")]),
            100,
        )
        .expect("save credentials");
    drop(store);

    let connection = Connection::open(&database).expect("database");
    connection
        .execute(
            "UPDATE provider_accounts SET provider_id = 'fanart' WHERE provider_id = 'tmdb'",
            [],
        )
        .expect("rebind ciphertext");
    drop(connection);

    let store = ProviderAccountStore::open(&database, &temp.path().join("master.key"))
        .expect("reopen provider account store");
    assert!(matches!(
        store.load_credentials(&identity, "fanart"),
        Err(ProviderAccountError::Decrypt)
    ));
}

#[test]
fn delete_is_owner_scoped_and_idempotent() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let store = ProviderAccountStore::open(
        &temp.path().join("provider-accounts.sqlite3"),
        &temp.path().join("master.key"),
    )
    .expect("provider account store");
    let owner = Identity::try_new_with_subject("subject-1", "sydney", ["users"]).expect("owner");
    let other = Identity::try_new_with_subject("subject-2", "sydney", ["users"]).expect("other");
    store
        .save(
            &owner,
            "tmdb",
            &credentials(&[("apiKey", "top-secret-key")]),
            100,
        )
        .expect("save credentials");

    assert!(!store.delete(&other, "tmdb").expect("other delete"));
    assert!(store
        .load_credentials(&owner, "tmdb")
        .expect("owner lookup")
        .is_some());
    assert!(store.delete(&owner, "tmdb").expect("owner delete"));
    assert!(!store.delete(&owner, "tmdb").expect("repeat delete"));
}
