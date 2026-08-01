#![cfg(target_os = "linux")]

use media_manager::{
    broker::{
        apply_install_metadata_sidecar, apply_install_subtitle, apply_move,
        discard_staged_broker_action, file_fingerprint, move_destination_matches,
        open_regular_file_beneath, BrokerAction, InstallMetadataSidecarAction,
        InstallSubtitleAction, MoveAction,
    },
    config::AppConfig,
};
use std::{fs, io::Read};

#[test]
fn broker_renames_within_a_registered_root_without_overwrite() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let shared = temp.path().join("shared");
    let users = temp.path().join("users");
    fs::create_dir_all(shared.join("_Videos/Movies")).expect("movie root");
    fs::write(shared.join("_Videos/Movies/Arrival.mkv"), b"video").expect("source");
    let config = AppConfig::for_test(
        shared.to_str().expect("shared path"),
        users.to_str().expect("users path"),
    );
    let expected =
        file_fingerprint(&shared.join("_Videos/Movies/Arrival.mkv")).expect("fingerprint");
    let action = MoveAction {
        source_root_id: "shared-videos".to_string(),
        source_relative_path: "Movies/Arrival.mkv".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "Movies/Arrival (2016).mkv".to_string(),
        expected,
    };

    apply_move(&config, "editor", &action).expect("safe move");
    assert!(!shared.join("_Videos/Movies/Arrival.mkv").exists());
    assert_eq!(
        fs::read(shared.join("_Videos/Movies/Arrival (2016).mkv")).expect("destination"),
        b"video"
    );
    assert!(move_destination_matches(&config, "editor", &action).expect("idempotency check"));

    fs::write(shared.join("_Videos/Movies/Second.mkv"), b"other").expect("second source");
    let collision = MoveAction {
        source_relative_path: "Movies/Second.mkv".to_string(),
        expected: file_fingerprint(&shared.join("_Videos/Movies/Second.mkv"))
            .expect("second fingerprint"),
        ..action
    };
    assert!(apply_move(&config, "editor", &collision).is_err());
    assert!(shared.join("_Videos/Movies/Second.mkv").exists());
}

#[test]
fn broker_installs_metadata_sidecars_without_replacing_existing_metadata() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let shared = temp.path().join("shared");
    let users = temp.path().join("users");
    let state = temp.path().join("state");
    fs::create_dir_all(shared.join("_Audiobooks/Author/Book")).expect("audiobook root");
    fs::create_dir_all(state.join("provider-staging")).expect("staging root");
    fs::write(
        state.join("provider-staging/metadata-1.opf"),
        b"<?xml version=\"1.0\"?><package><metadata/></package>",
    )
    .expect("metadata");
    let mut config = AppConfig::for_test(
        shared.to_str().expect("shared path"),
        users.to_str().expect("users path"),
    );
    config.state_dir = state.clone();
    let action = InstallMetadataSidecarAction {
        staging_filename: "metadata-1.opf".to_string(),
        destination_root_id: "shared-audiobooks".to_string(),
        destination_relative_path: "Author/Book/metadata.opf".to_string(),
        expected: file_fingerprint(&state.join("provider-staging/metadata-1.opf"))
            .expect("fingerprint"),
    };

    apply_install_metadata_sidecar(&config, "editor", &action).expect("install metadata");
    assert!(shared
        .join("_Audiobooks/Author/Book/metadata.opf")
        .is_file());

    fs::write(
        state.join("provider-staging/metadata-2.opf"),
        b"replacement",
    )
    .expect("replacement stage");
    let collision = InstallMetadataSidecarAction {
        staging_filename: "metadata-2.opf".to_string(),
        expected: file_fingerprint(&state.join("provider-staging/metadata-2.opf"))
            .expect("replacement fingerprint"),
        ..action
    };
    assert!(apply_install_metadata_sidecar(&config, "editor", &collision).is_err());
    assert!(state.join("provider-staging/metadata-2.opf").exists());
}

#[test]
fn broker_installs_a_staged_subtitle_as_a_no_replace_sidecar() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let shared = temp.path().join("shared");
    let users = temp.path().join("users");
    let state = temp.path().join("state");
    std::fs::create_dir_all(shared.join("_Videos/Movies")).expect("movie root");
    std::fs::create_dir_all(state.join("provider-staging")).expect("staging root");
    std::fs::write(
        state.join("provider-staging/subtitle-1.srt"),
        b"1\n00:00:01,000 --> 00:00:02,000\nHello\n",
    )
    .expect("subtitle");
    let mut config = AppConfig::for_test(
        shared.to_str().expect("shared path"),
        users.to_str().expect("users path"),
    );
    config.state_dir = state.clone();
    let action = InstallSubtitleAction {
        staging_filename: "subtitle-1.srt".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "Movies/Arrival (2016).en.srt".to_string(),
        expected: file_fingerprint(&state.join("provider-staging/subtitle-1.srt"))
            .expect("staged fingerprint"),
    };

    apply_install_subtitle(&config, "editor", &action).expect("install subtitle");
    assert_eq!(
        std::fs::read(shared.join("_Videos/Movies/Arrival (2016).en.srt"))
            .expect("installed subtitle"),
        b"1\n00:00:01,000 --> 00:00:02,000\nHello\n"
    );
    assert!(!state.join("provider-staging/subtitle-1.srt").exists());

    std::fs::write(
        state.join("provider-staging/subtitle-2.srt"),
        b"replacement",
    )
    .expect("second subtitle");
    let collision = InstallSubtitleAction {
        staging_filename: "subtitle-2.srt".to_string(),
        expected: file_fingerprint(&state.join("provider-staging/subtitle-2.srt"))
            .expect("second fingerprint"),
        ..action
    };
    assert!(apply_install_subtitle(&config, "editor", &collision).is_err());
    assert!(state.join("provider-staging/subtitle-2.srt").exists());
}

#[test]
fn broker_discards_only_the_fingerprint_bound_file_for_an_expired_preview() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let shared = temp.path().join("shared");
    let users = temp.path().join("users");
    let state = temp.path().join("state");
    fs::create_dir_all(state.join("provider-staging")).expect("staging root");
    let staged = state.join("provider-staging/subtitle-expired.srt");
    fs::write(&staged, b"expired subtitle").expect("staged subtitle");
    let mut config = AppConfig::for_test(
        shared.to_str().expect("shared path"),
        users.to_str().expect("users path"),
    );
    config.state_dir = state;
    let action = BrokerAction::InstallSubtitle(InstallSubtitleAction {
        staging_filename: "subtitle-expired.srt".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "Movies/Arrival (2016).en.srt".to_string(),
        expected: file_fingerprint(&staged).expect("fingerprint"),
    });

    discard_staged_broker_action(&config, &action).expect("discard expired staging file");
    assert!(!staged.exists());

    fs::write(&staged, b"replacement contents").expect("replacement");
    assert!(discard_staged_broker_action(&config, &action).is_err());
    assert!(staged.exists());
}

#[test]
fn broker_rejects_changed_inputs_and_symlink_parents() {
    use std::os::unix::fs::symlink;

    let temp = tempfile::tempdir().expect("temporary directory");
    let shared = temp.path().join("shared");
    let users = temp.path().join("users");
    let outside = temp.path().join("outside");
    fs::create_dir_all(shared.join("_Videos/Movies")).expect("movie root");
    fs::create_dir_all(&outside).expect("outside");
    fs::write(shared.join("_Videos/Movies/Movie.mkv"), b"old").expect("source");
    let config = AppConfig::for_test(
        shared.to_str().expect("shared path"),
        users.to_str().expect("users path"),
    );
    let expected = file_fingerprint(&shared.join("_Videos/Movies/Movie.mkv")).expect("fingerprint");
    fs::write(
        shared.join("_Videos/Movies/Movie.mkv"),
        b"changed after preview",
    )
    .expect("change source");
    let changed = MoveAction {
        source_root_id: "shared-videos".to_string(),
        source_relative_path: "Movies/Movie.mkv".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "Movies/Renamed.mkv".to_string(),
        expected,
    };
    assert!(apply_move(&config, "editor", &changed).is_err());

    fs::remove_file(shared.join("_Videos/Movies/Movie.mkv")).expect("remove changed file");
    symlink(&outside, shared.join("_Videos/Escape")).expect("escape symlink");
    fs::write(outside.join("Movie.mkv"), b"outside").expect("outside file");
    let escaped = MoveAction {
        source_relative_path: "Escape/Movie.mkv".to_string(),
        destination_relative_path: "Escape/Renamed.mkv".to_string(),
        expected: file_fingerprint(&outside.join("Movie.mkv")).expect("outside fingerprint"),
        ..changed
    };
    assert!(apply_move(&config, "editor", &escaped).is_err());
    assert!(open_regular_file_beneath(&shared.join("_Videos"), "Escape/Movie.mkv").is_err());
    assert!(outside.join("Movie.mkv").exists());
}

#[test]
fn contained_reader_opens_a_regular_catalog_file() {
    let temp = tempfile::tempdir().expect("temporary directory");
    let root = temp.path().join("videos");
    fs::create_dir_all(root.join("Movies")).expect("movie directory");
    fs::write(root.join("Movies/Movie.mkv"), b"movie bytes").expect("movie");

    let mut file =
        open_regular_file_beneath(&root, "Movies/Movie.mkv").expect("contained regular file");
    let mut bytes = Vec::new();
    file.read_to_end(&mut bytes).expect("read movie");

    assert_eq!(bytes, b"movie bytes");
}

#[test]
fn broker_rejects_relative_path_traversal() {
    let config = AppConfig::for_test("/tmp/shared", "/tmp/users");
    let action = MoveAction {
        source_root_id: "shared-videos".to_string(),
        source_relative_path: "../other/file.mkv".to_string(),
        destination_root_id: "shared-videos".to_string(),
        destination_relative_path: "file.mkv".to_string(),
        expected: "0:0".to_string(),
    };
    assert!(apply_move(&config, "editor", &action).is_err());
}
