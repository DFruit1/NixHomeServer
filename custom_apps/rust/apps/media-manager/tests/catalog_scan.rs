use media_manager::{
    catalog::{Catalog, CatalogHandle},
    naming::{canonical_movie_directory, canonical_tv_episode},
    scanner::{scan_root, scan_root_if_needed, ScanRoot},
};

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
    let mut catalog = Catalog::open(&database).expect("catalog");
    let result = scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-videos".to_string(),
            owner_username: None,
            path: library,
            category: "videos".to_string(),
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

    let mut catalog = Catalog::open(&dir.path().join("control.sqlite3")).expect("catalog");
    scan_root(
        &mut catalog,
        &ScanRoot {
            id: "shared-music-art".to_string(),
            owner_username: None,
            path: library,
            category: "music".to_string(),
        },
    )
    .expect("scan");

    let items = catalog
        .list_items("shared-music-art", None, 100)
        .expect("catalog items");
    assert_eq!(items.len(), 8);
    let artwork: Vec<_> = items
        .iter()
        .filter(|item| item.media_kind == "artwork")
        .collect();
    assert_eq!(artwork.len(), 7);
    assert!(items
        .iter()
        .any(|item| item.relative_path == "Album/Track.flac"));
}

#[test]
fn scanner_removes_catalog_rows_for_files_that_disappeared() {
    let dir = tempfile::tempdir().expect("temporary directory");
    let library = dir.path().join("library");
    std::fs::create_dir_all(&library).expect("library");
    let media = library.join("Book.epub");
    std::fs::write(&media, b"book").expect("book");
    let mut catalog = Catalog::open(&dir.path().join("control.sqlite3")).expect("catalog");
    let root = ScanRoot {
        id: "shared-books".to_string(),
        owner_username: None,
        path: library,
        category: "books".to_string(),
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
    handle.open().expect("initialize catalog");
    let root = ScanRoot {
        id: "shared-books-concurrent".to_string(),
        owner_username: None,
        path: library,
        category: "books".to_string(),
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
