use media_manager::config::AppConfig;

#[test]
fn all_scan_specs_enumerates_shared_and_valid_personal_roots() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let users = dir.path().join("users");
    let shared = dir.path().join("shared");
    std::fs::create_dir_all(users.join("dsaw/_Videos")).expect("personal videos");
    std::fs::create_dir_all(users.join("dsaw/_Music")).expect("personal music");
    std::fs::create_dir_all(users.join("not a user")).expect("invalid username directory");
    std::fs::write(users.join("notes.txt"), b"not a directory").expect("non-directory entry");
    std::fs::create_dir_all(shared.join("_Videos")).expect("shared videos");

    let config = AppConfig::for_test(
        shared.to_str().expect("shared path"),
        users.to_str().expect("users path"),
    );
    let specs = config.all_scan_specs();

    let ids: Vec<&str> = specs.iter().map(|spec| spec.id.as_str()).collect();
    for shared_id in [
        "shared-videos",
        "shared-music",
        "shared-audiobooks",
        "shared-podcasts",
        "shared-books",
    ] {
        assert!(ids.contains(&shared_id), "missing {shared_id} in {ids:?}");
    }
    let personal = specs
        .iter()
        .filter(|spec| spec.id == "personal-videos")
        .collect::<Vec<_>>();
    assert_eq!(personal.len(), 1);
    assert_eq!(personal[0].owner_username.as_deref(), Some("dsaw"));
    assert_eq!(personal[0].path, users.join("dsaw").join("_Videos"));
    assert!(specs
        .iter()
        .all(|spec| spec.owner_username.as_deref() != Some("not a user")));
}
