use media_manager::media::{LibraryCategory, MediaKind};
use media_manager::{
    catalog::{
        Catalog, CatalogHandle, ScannedItem, INITIAL_SCAN_INTERVAL_MINUTES,
        MAX_SCAN_INTERVAL_MINUTES,
    },
    naming::{canonical_movie_directory, canonical_tv_episode},
    scanner::{scan_root, scan_root_if_needed, ScanRoot},
};

#[test]
fn subtitle_inventory_query_is_scoped_to_the_video_directory() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");
    let mut items = (0..600)
        .map(|index| ScannedItem {
            id: format!("unrelated-{index}"),
            relative_path: format!("Other/{index:04}.srt"),
            media_kind: MediaKind::Subtitle,
            size_bytes: 1,
            modified_ns: 1,
            fingerprint: "1:1".to_string(),
        })
        .collect::<Vec<_>>();
    items.extend([
        ScannedItem {
            id: "arrival-en".to_string(),
            relative_path: "Movies/Arrival (2016).en.srt".to_string(),
            media_kind: MediaKind::Subtitle,
            size_bytes: 1,
            modified_ns: 1,
            fingerprint: "1:1".to_string(),
        },
        ScannedItem {
            id: "arrival-forced".to_string(),
            relative_path: "Movies/Arrival (2016).en.forced.ass".to_string(),
            media_kind: MediaKind::Subtitle,
            size_bytes: 1,
            modified_ns: 1,
            fingerprint: "1:1".to_string(),
        },
    ]);
    catalog
        .reconcile_root("shared-videos", None, &items)
        .expect("reconcile");

    let subtitles = catalog
        .list_subtitles_in_directory("shared-videos", None, "Movies", 256)
        .expect("subtitles");

    assert_eq!(subtitles.len(), 2);
    assert!(subtitles
        .iter()
        .all(|item| item.relative_path.starts_with("Movies/Arrival (2016).")));
}

#[test]
fn unknown_year_is_omitted_from_canonical_names() {
    assert_eq!(
        canonical_movie_directory("Bible Verdict of History", None),
        "Bible Verdict of History"
    );
    assert_eq!(
        canonical_movie_directory("Arrival", Some(2016)),
        "Arrival (2016)"
    );
    assert_eq!(
        canonical_movie_directory("An Old Book", Some(1813)),
        "An Old Book (1813)"
    );
    assert_eq!(
        canonical_tv_episode("Example Show", None, 2, 3, Some("A Beginning"), "mkv"),
        "Example Show - S02E03 - A Beginning.mkv"
    );
}

#[cfg(unix)]
#[test]
fn scanner_indexes_supported_media_without_following_symlinks() {
    use std::{fs, os::unix::fs::symlink};

    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    let outside = dir.path().join("outside");
    fs::create_dir_all(library.join("Season 01")).expect("library directories");
    fs::create_dir_all(&outside).expect("outside directory");
    fs::write(library.join("Season 01/Episode 01.mkv"), b"video").expect("video");
    fs::write(library.join("cover.jpg"), b"art").expect("artwork");
    fs::write(library.join("notes.txt"), b"ignore").expect("unsupported file");
    fs::write(outside.join("escaped.mp3"), b"audio").expect("outside media");
    symlink(&outside, library.join("escape")).expect("symlink");

    let database = dir.path().join("control.sqlite3");
    let mut catalog = Catalog::initialize(&database).expect("catalog");
    let result = scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-videos".to_string(),
            owner_username: None,
            path: library,
            category: LibraryCategory::Videos,
        },
    )
    .expect("scan");

    assert_eq!(result.files_seen, 3);
    assert_eq!(result.items_indexed, 2);
    let items = catalog
        .list_items("shared-videos", None, 100)
        .expect("catalog items");
    assert_eq!(items.len(), 2);
    assert!(items
        .iter()
        .any(|item| item.relative_path == "Season 01/Episode 01.mkv"));
    assert!(items
        .iter()
        .all(|item| !item.relative_path.contains("escaped")));
}

#[cfg(unix)]
#[test]
fn scanner_skips_entries_with_non_utf8_paths_instead_of_failing() {
    use std::ffi::OsStr;
    use std::os::unix::ffi::OsStrExt;

    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    std::fs::create_dir_all(&library).expect("library");
    std::fs::write(library.join("Keep.mkv"), b"video").expect("media");
    let bad_name = OsStr::from_bytes(b"broken-\xff.mkv");
    std::fs::write(library.join(bad_name), b"video").expect("non-utf8 media");

    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");
    let result = scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-videos".to_string(),
            owner_username: None,
            path: library,
            category: LibraryCategory::Videos,
        },
    )
    .expect("scan");

    assert_eq!(result.files_seen, 2);
    assert_eq!(result.items_indexed, 1);
    assert_eq!(result.entries_skipped, 1);
    let items = catalog
        .list_items("shared-videos", None, 100)
        .expect("catalog items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].relative_path, "Keep.mkv");
}

#[test]
fn scanner_skips_the_tombstone_folder() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    std::fs::create_dir_all(&library).expect("library");
    std::fs::write(library.join("Keep.mkv"), b"video").expect("media");
    std::fs::create_dir_all(library.join("_Tombstone")).expect("tombstone");
    std::fs::write(library.join("_Tombstone/Gone.mp4"), b"video").expect("tombstoned media");

    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");
    let result = scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-videos".to_string(),
            owner_username: None,
            path: library,
            category: LibraryCategory::Videos,
        },
    )
    .expect("scan");

    assert_eq!(result.files_seen, 1);
    assert_eq!(result.items_indexed, 1);
    let items = catalog
        .list_items("shared-videos", None, 100)
        .expect("catalog items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].relative_path, "Keep.mkv");
}

#[test]
fn scanner_indexes_additional_artwork_formats() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    std::fs::create_dir_all(library.join("Album")).expect("library directories");
    std::fs::write(library.join("Album/Track.flac"), b"audio").expect("audio");
    for (name, bytes) in [
        ("cover.gif", &b"gif"[..]),
        ("cover.bmp", &b"bmp"[..]),
        ("cover.tiff", &b"tiff"[..]),
        ("cover.avif", &b"avif"[..]),
        ("cover.svg", &b"svg"[..]),
        ("cover.heic", &b"heic"[..]),
        ("cover.jxl", &b"jxl"[..]),
    ] {
        std::fs::write(library.join(name), bytes).expect("artwork");
    }

    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");
    scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-music-art".to_string(),
            owner_username: None,
            path: library,
            category: LibraryCategory::Music,
        },
    )
    .expect("scan");

    let items = catalog
        .list_items("shared-music-art", None, 100)
        .expect("catalog items");
    assert_eq!(items.len(), 8);
    let artwork: Vec<_> = items
        .iter()
        .filter(|item| item.media_kind == MediaKind::Artwork)
        .collect();
    assert_eq!(artwork.len(), 7);
    assert!(items
        .iter()
        .any(|item| item.relative_path == "Album/Track.flac"));
}

#[test]
fn scanner_keeps_podcasts_distinct_from_audiobooks() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("podcasts");
    std::fs::create_dir_all(&library).expect("podcast library");
    std::fs::write(library.join("Episode 1.mp3"), b"podcast").expect("episode");
    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");
    scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-podcasts".to_string(),
            owner_username: None,
            path: library,
            category: LibraryCategory::Podcasts,
        },
    )
    .expect("scan");
    let items = catalog
        .list_items("shared-podcasts", None, 100)
        .expect("podcast items");
    assert_eq!(items.len(), 1);
    assert_eq!(items[0].media_kind, MediaKind::Podcast);
}

#[test]
fn scanner_removes_catalog_rows_for_files_that_disappeared() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    std::fs::create_dir_all(&library).expect("library");
    let media = library.join("Book.epub");
    std::fs::write(&media, b"book").expect("book");
    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");
    let root = ScanRoot {
        id: "shared-books".to_string(),
        owner_username: None,
        path: library,
        category: LibraryCategory::Books,
    };

    scan_root(&mut catalog, &root).expect("first scan");
    std::fs::remove_file(media).expect("remove media");
    let result = scan_root(&mut catalog, &root).expect("second scan");

    assert_eq!(result.items_removed, 1);
    assert!(catalog
        .list_items("shared-books", None, 100)
        .expect("catalog items")
        .is_empty());
}

#[test]
fn concurrent_initial_scans_reconcile_a_root_only_once() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    std::fs::create_dir_all(&library).expect("library");
    std::fs::write(library.join("Book.epub"), b"book").expect("book");
    let handle = CatalogHandle::new(dir.path().join("control.sqlite3"));
    Catalog::initialize(&dir.path().join("control.sqlite3")).expect("initialize catalog");
    let root = ScanRoot {
        id: "shared-books-concurrent".to_string(),
        owner_username: None,
        path: library,
        category: LibraryCategory::Books,
    };

    let first_handle = handle.clone();
    let first_root = root.clone();
    let first = std::thread::spawn(move || scan_root_if_needed(&first_handle, &first_root));
    let second_handle = handle.clone();
    let second_root = root.clone();
    let second = std::thread::spawn(move || scan_root_if_needed(&second_handle, &second_root));
    let outcomes = [
        first
            .join()
            .expect("first scan thread")
            .expect("first scan"),
        second
            .join()
            .expect("second scan thread")
            .expect("second scan"),
    ];

    assert_eq!(outcomes.iter().filter(|result| result.is_some()).count(), 1);
    assert_eq!(outcomes.iter().filter(|result| result.is_none()).count(), 1);
}

#[test]
fn scanner_waits_for_a_concurrent_catalog_writer() {
    use std::{sync::mpsc, thread, time::Duration};

    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    std::fs::create_dir_all(&library).expect("library");
    std::fs::write(library.join("Book.epub"), b"book").expect("book");
    let database = dir.path().join("control.sqlite3");
    let mut catalog = Catalog::initialize(&database).expect("catalog");

    let (writer_ready_tx, writer_ready_rx) = mpsc::channel();
    let writer_database = database.clone();
    let writer = thread::spawn(move || {
        let connection = rusqlite::Connection::open(writer_database).expect("writer connection");
        connection
            .execute_batch("BEGIN IMMEDIATE")
            .expect("reserve catalog writer");
        writer_ready_tx.send(()).expect("signal writer readiness");
        thread::sleep(Duration::from_millis(200));
        connection.execute_batch("COMMIT").expect("release writer");
    });
    writer_ready_rx.recv().expect("wait for catalog writer");

    let result = scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-books-writer-contention".to_string(),
            owner_username: None,
            path: library,
            category: LibraryCategory::Books,
        },
    );
    writer.join().expect("catalog writer thread");

    let result = result.expect("scan waits for the concurrent writer");
    assert_eq!(result.items_indexed, 1);
}

#[test]
fn scan_schedule_backs_off_without_changes_and_resets_on_change() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");

    assert!(catalog.scan_is_due("shared-videos", None, 1_000).unwrap());

    let first = catalog
        .record_scan_outcome("shared-videos", None, false, 1_000)
        .expect("first no-change scan");
    assert_eq!(first.interval_minutes, 30);
    assert_eq!(first.next_scan_at, 1_000 + 30 * 60);
    assert!(!catalog
        .scan_is_due("shared-videos", None, first.next_scan_at - 1)
        .unwrap());
    assert!(catalog
        .scan_is_due("shared-videos", None, first.next_scan_at)
        .unwrap());

    let second = catalog
        .record_scan_outcome("shared-videos", None, false, first.next_scan_at)
        .expect("second no-change scan");
    assert_eq!(second.interval_minutes, 45);
    let third = catalog
        .record_scan_outcome("shared-videos", None, false, second.next_scan_at)
        .expect("third no-change scan");
    assert_eq!(third.interval_minutes, 60);
    let fourth = catalog
        .record_scan_outcome("shared-videos", None, false, third.next_scan_at)
        .expect("first hourly step");
    assert_eq!(fourth.interval_minutes, 120);

    let mut last = fourth;
    for _ in 0..64 {
        last = catalog
            .record_scan_outcome("shared-videos", None, false, last.next_scan_at)
            .expect("backed-off scan");
    }
    assert_eq!(last.interval_minutes, MAX_SCAN_INTERVAL_MINUTES);

    let reset = catalog
        .record_scan_outcome("shared-videos", None, true, last.next_scan_at)
        .expect("change resets backoff");
    assert_eq!(reset.interval_minutes, INITIAL_SCAN_INTERVAL_MINUTES);
    assert_eq!(reset.last_change_at, Some(last.next_scan_at));
}

#[test]
fn reconcile_reports_changed_and_removed_items() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let mut catalog = Catalog::initialize(&dir.path().join("control.sqlite3")).expect("catalog");
    let item = |path: &str, fingerprint: &str| ScannedItem {
        id: format!("id-{path}"),
        relative_path: path.to_string(),
        media_kind: MediaKind::Video,
        size_bytes: 1,
        modified_ns: 1,
        fingerprint: fingerprint.to_string(),
    };

    let first = catalog
        .reconcile_root(
            "shared-videos",
            None,
            &[item("A.mkv", "1:1"), item("B.mkv", "1:1")],
        )
        .expect("first reconcile");
    assert_eq!(first.changed, 2);
    assert_eq!(first.removed, 0);

    let same = catalog
        .reconcile_root(
            "shared-videos",
            None,
            &[item("A.mkv", "1:1"), item("B.mkv", "1:1")],
        )
        .expect("unchanged reconcile");
    assert_eq!(same.changed, 0);
    assert_eq!(same.removed, 0);

    let changed = catalog
        .reconcile_root("shared-videos", None, &[item("A.mkv", "2:2")])
        .expect("changed reconcile");
    assert_eq!(changed.changed, 1);
    assert_eq!(changed.removed, 1);
}
