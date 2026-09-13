//! Folder-level audiobook/music play-order analysis.
//!
//! Audiobookshelf orders the tracks of a book by disc number, then track
//! number, choosing per file between the number parsed from the filename and
//! the embedded audio tag. When those two sources disagree (the classic
//! off-by-one: `00_lawson.mp3` holding tag `1/31`), or when a playlist
//! references files that do not resolve on a case-sensitive filesystem, books
//! play out of order or lose files. The per-file metadata editor cannot show
//! this: the unit of ordering is the folder, so this module assesses a whole
//! folder at once and reports **one grouped problem per album**, with the
//! affected files attached, instead of one warning per file.

use crate::{
    broker::{open_directory_beneath, open_regular_file_beneath},
    media::{classify, LibraryCategory},
};
use serde::Serialize;
use std::collections::{BTreeMap, BTreeSet, HashMap};
use std::io::Read;
use std::os::unix::io::AsRawFd;
use std::path::Path;

/// Maximum playlist entries parsed from a single sidecar playlist.
pub const MAX_PLAYLIST_ENTRIES: usize = 2000;
/// Maximum folder siblings inspected for a single track-order report.
pub const MAX_TRACK_ORDER_FILES: usize = 500;
/// How many affected file names a grouped problem carries inline.
pub const MAX_AFFECTED_FILES: usize = 25;

/// Audio extensions the scanner catalogs per library category. Files with
/// other audio extensions (wav, aac, wma, ...) are playable by
/// Audiobookshelf/Jellyfin but invisible to the media library; they surface
/// as a grouped `unrecognised-audio-files` problem instead of per-file noise.
pub const UNRECOGNISED_AUDIO_EXTENSIONS: &[&str] = &[
    "wav", "aiff", "aif", "aac", "wma", "mka", "dsf", "dff", "alac", "ape", "wv",
];

/// Playlist sidecars understood as ordering references.
pub const PLAYLIST_EXTENSIONS: &[&str] = &["m3u", "m3u8"];

/// One audio file in the assessed folder.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TrackOrderFile {
    pub file_name: String,
    pub tag_disc: Option<u64>,
    pub tag_track: Option<u64>,
}

/// A grouped ordering problem: one per album, never one per file.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrackOrderProblem {
    pub code: String,
    pub severity: String,
    pub title: String,
    pub message: String,
    /// Affected file names (bounded to [`MAX_AFFECTED_FILES`]).
    pub affected_files: Vec<String>,
    /// Total affected files, including those elided from `affected_files`.
    pub affected_file_count: usize,
}

/// One row of the self-service track-order table.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrackOrderFileRow {
    pub file_name: String,
    pub filename_number: Option<u64>,
    pub tag_disc: Option<u64>,
    pub tag_track: Option<u64>,
    pub playlist_position: Option<usize>,
    /// 1-based position in the effective (tag-first) playback order.
    pub effective_position: usize,
    pub status: String,
}

/// The full folder-level report served to the editor and health checker.
#[derive(Clone, Debug, Serialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct TrackOrderReport {
    /// `ok`, `warning`, or `error`.
    pub status: String,
    pub file_count: usize,
    pub playlist_name: Option<String>,
    pub files: Vec<TrackOrderFileRow>,
    pub problems: Vec<TrackOrderProblem>,
}

/// Parse the leading `(disc, track)` sequence number from a file name.
///
/// Understands `01`, `01 - title`, `1-02`, `CD2-03`, `Disc 1 - 04`,
/// `Part 2`, `track 07`, and `07/31` (track/total). Returns `None` when the
/// name carries no leading number. Numbers are bounded so pathological names
/// cannot produce absurd orderings.
pub fn filename_sequence_number(file_name: &str) -> Option<(u64, u64)> {
    let stem = file_name
        .rsplit_once('.')
        .map(|(stem, _)| stem)
        .unwrap_or(file_name);
    // Markers are ASCII, so byte offsets in the lowercased copy match `stem`.
    let lower = stem.to_ascii_lowercase();
    let mut rest = lower.as_str();
    let mut disc = 1u64;
    let mut explicit_disc = false;
    for marker in ["disc", "disk", "cd"] {
        if let Some(tail) = rest.strip_prefix(marker) {
            let tail = tail.trim_start_matches([' ', '-', '_', '.']);
            match leading_number(tail) {
                Some((number, consumed)) if (1..=99).contains(&number) => {
                    disc = number;
                    explicit_disc = true;
                    rest = tail[consumed..].trim_start_matches([' ', '-', '_', '.']);
                }
                _ => return None,
            }
            break;
        }
    }
    if !explicit_disc
        && rest.starts_with('d')
        && rest[1..].chars().next().is_some_and(|character| character.is_ascii_digit())
    {
        let tail = &rest[1..];
        if let Some((number, consumed)) = leading_number(tail) {
            if (1..=99).contains(&number) {
                disc = number;
                explicit_disc = true;
                rest = tail[consumed..].trim_start_matches([' ', '-', '_', '.']);
            }
        }
    }
    for word in ["part", "track", "trk"] {
        if let Some(tail) = rest.strip_prefix(word) {
            let tail = tail.trim_start_matches([' ', '-', '_', '.', '#']);
            if tail.chars().next().is_some_and(|character| character.is_ascii_digit()) {
                rest = tail;
                break;
            }
        }
    }
    let (first, consumed) = leading_number(rest)?;
    if first > 9999 {
        return None;
    }
    // A second number after a separator ("1-02", "1.02", "07/31") only
    // overrides the track when an explicit disc marker was seen; otherwise
    // the leading number is the track (covers track/total forms).
    let mut track = first;
    if explicit_disc {
        let tail = rest[consumed..].trim_start_matches([' ', '-', '_', '.', '/']);
        if let Some((second, _)) = leading_number(tail) {
            if second <= 9999 {
                track = second;
            }
        }
    }
    Some((disc, track))
}

fn leading_number(text: &str) -> Option<(u64, usize)> {
    let end = text
        .char_indices()
        .take_while(|(_, character)| character.is_ascii_digit())
        .last()
        .map(|(index, character)| index + character.len_utf8())?;
    let number = text[..end].parse::<u64>().ok()?;
    Some((number, end))
}

/// Parse an m3u/m3u8 playlist into its referenced entry names.
///
/// Skips `#` directives (`#EXTM3U`, `#EXTINF`, ...), trims whitespace and
/// carriage returns, and keeps only the final path segment so `dir/file.mp3`
/// entries resolve against the folder listing. Bounded to
/// [`MAX_PLAYLIST_ENTRIES`] entries.
pub fn parse_m3u_playlist(text: &str) -> Vec<String> {
    let mut entries = Vec::new();
    for line in text.lines() {
        let line = line.trim().trim_matches('\r').trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let name = line.rsplit(['/', '\\']).next().unwrap_or(line).trim();
        if name.is_empty() || name == "." || name == ".." || name.contains('\0') {
            continue;
        }
        entries.push(name.to_string());
        if entries.len() >= MAX_PLAYLIST_ENTRIES {
            break;
        }
    }
    entries
}

/// Assess the play order of one folder.
///
/// `files` are the audio siblings, `playlist_name`/`playlist_entries` the
/// optional ordering reference, and `unrecognised_audio` the audio files the
/// scanner skips but players may still read. Returns a single grouped
/// report: at most one problem per code per album.
pub fn assess_track_order(
    files: Vec<TrackOrderFile>,
    playlist_name: Option<String>,
    playlist_entries: Vec<String>,
    unrecognised_audio: Vec<String>,
) -> TrackOrderReport {
    let mut files = files;
    files.sort_by(|left, right| {
        filename_sequence_number(&left.file_name)
            .cmp(&filename_sequence_number(&right.file_name))
            .then_with(|| left.file_name.cmp(&right.file_name))
    });
    if files.len() > MAX_TRACK_ORDER_FILES {
        files.truncate(MAX_TRACK_ORDER_FILES);
    }
    let index_of: HashMap<&str, usize> = files
        .iter()
        .enumerate()
        .map(|(index, file)| (file.file_name.as_str(), index))
        .collect();

    let playlist_positions: BTreeMap<String, usize> = playlist_entries
        .iter()
        .enumerate()
        .map(|(index, entry)| (entry.clone(), index + 1))
        .collect();

    // Effective order: embedded tag first (the player's preference when tags
    // exist), filename number second, lexical last.
    let mut effective: Vec<usize> = (0..files.len()).collect();
    effective.sort_by(|&left, &right| {
        let key = |index: usize| {
            (
                files[index].tag_disc.unwrap_or(u64::MAX),
                files[index].tag_track.unwrap_or(u64::MAX),
                filename_sequence_number(&files[index].file_name)
                    .unwrap_or((u64::MAX, u64::MAX)),
                &files[index].file_name,
            )
        };
        key(left).cmp(&key(right))
    });
    let effective_position: HashMap<usize, usize> = effective
        .iter()
        .enumerate()
        .map(|(position, &index)| (index, position + 1))
        .collect();

    let mut filename_rank: HashMap<usize, usize> = HashMap::new();
    {
        let mut order: Vec<usize> = (0..files.len()).collect();
        order.sort_by(|&left, &right| {
            filename_sequence_number(&files[left].file_name)
                .cmp(&filename_sequence_number(&files[right].file_name))
                .then_with(|| files[left].file_name.cmp(&files[right].file_name))
        });
        for (rank, index) in order.into_iter().enumerate() {
            filename_rank.insert(index, rank + 1);
        }
    }

    let mut problems = Vec::new();

    // Filename-vs-tag mismatches: the out-of-order root cause.
    let mismatched: Vec<String> = (0..files.len())
        .filter(|&index| {
            let filename_number =
                filename_sequence_number(&files[index].file_name).map(|(_, track)| track);
            match (filename_number, files[index].tag_track) {
                (Some(filename), Some(tag)) => {
                    filename != tag || filename_rank[&index] != effective_position[&index]
                }
                _ => false,
            }
        })
        .map(|index| files[index].file_name.clone())
        .collect();
    if !mismatched.is_empty() {
        problems.push(grouped_problem(
            "track-order-mismatch",
            "warning",
            "Filename numbering disagrees with embedded track tags",
            format!(
                "The player picks per file between the filename number and the embedded tag, so {} of {} files can sort away from the intended order. Align the filename numbers with the embedded track numbers, then rescan the library and refresh the player.",
                mismatched.len(),
                files.len(),
            ),
            mismatched,
        ));
    }

    // Gaps and duplicates in the filename sequence.
    let mut numbers = BTreeMap::<u64, Vec<String>>::new();
    let mut unnumbered = Vec::new();
    for file in &files {
        match filename_sequence_number(&file.file_name).map(|(_, track)| track) {
            Some(number) => numbers.entry(number).or_default().push(file.file_name.clone()),
            None => unnumbered.push(file.file_name.clone()),
        }
    }
    let duplicates: Vec<String> = numbers
        .values()
        .filter(|names| names.len() > 1)
        .flat_map(|names| names.clone())
        .collect();
    let sorted_numbers: Vec<u64> = numbers.keys().copied().collect();
    let has_gap = sorted_numbers.windows(2).any(|pair| pair[1] != pair[0] + 1);
    let starts_at_zero = sorted_numbers.first().is_some_and(|&first| first == 0);
    if !duplicates.is_empty() || has_gap {
        let affected: Vec<String> = numbers.values().flat_map(|names| names.clone()).collect();
        problems.push(grouped_problem(
            "track-sequence-gap-or-duplicate",
            "warning",
            "Filename sequence has gaps or duplicates",
            "The filename sequence has gaps or duplicates, so plain filename sorting drifts from the intended playback order. Renumber the files with zero-padded track numbers and rescan.".to_string(),
            affected,
        ));
    } else if starts_at_zero && files.iter().any(|file| file.tag_track.is_some_and(|tag| tag >= 1)) {
        // The Lawson shape: 00-based files against 01-based tags. Either
        // scheme alone sorts the same files, but the player mixes the two
        // per file and collides them.
        let affected: Vec<String> = files.iter().map(|file| file.file_name.clone()).collect();
        problems.push(grouped_problem(
            "track-sequence-gap-or-duplicate",
            "warning",
            "Filenames start at 00 while tags start at 01",
            "The filename sequence starts at 00 while embedded tags start at 01; the player can collide the two schemes and play chapters out of order. Renumber the files 01..N to match the tags and rescan.".to_string(),
            affected,
        ));
    }
    if unnumbered.len() == files.len() && files.len() > 1 {
        problems.push(grouped_problem(
            "missing-track-numbers",
            "info",
            "No file carries a sequence number or track tag",
            "Neither filenames nor embedded tags carry track numbers, so playback order falls back to plain filename sorting. Add zero-padded leading numbers and rescan.".to_string(),
            unnumbered,
        ));
    }

    // Playlist agreement, resolved case-sensitively like the server FS.
    if playlist_name.is_some() {
        let present: BTreeSet<&str> = files.iter().map(|file| file.file_name.as_str()).collect();
        let lower_present: BTreeMap<String, &str> = files
            .iter()
            .map(|file| {
                (
                    file.file_name.to_ascii_lowercase(),
                    file.file_name.as_str(),
                )
            })
            .collect();
        let mut unresolved = Vec::new();
        let mut case_hints = Vec::new();
        for entry in &playlist_entries {
            if !present.contains(entry.as_str()) {
                unresolved.push(entry.clone());
                if let Some(actual) = lower_present.get(&entry.to_ascii_lowercase()) {
                    case_hints.push(format!("{entry} should be {actual}"));
                }
            }
        }
        if !unresolved.is_empty() {
            let mut message = format!(
                "The playlist references {} file{} that do not resolve on the case-sensitive library filesystem; those tracks cannot play from the playlist.",
                unresolved.len(),
                if unresolved.len() == 1 { "" } else { "s" },
            );
            if !case_hints.is_empty() {
                message.push_str(&format!(
                    " Case mismatches: {}.",
                    case_hints
                        .iter()
                        .take(5)
                        .cloned()
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
            }
            problems.push(grouped_problem(
                "unresolved-playlist-entries",
                "error",
                "Playlist entries do not resolve to library files",
                message,
                unresolved,
            ));
        }
        let playlist_rank: HashMap<&str, usize> = playlist_entries
            .iter()
            .enumerate()
            .map(|(index, entry)| (entry.as_str(), index))
            .collect();
        let listed: Vec<&TrackOrderFile> = files
            .iter()
            .filter(|file| playlist_rank.contains_key(file.file_name.as_str()))
            .collect();
        let mut by_effective = listed.clone();
        by_effective.sort_by_key(|file| effective_position[&index_of[file.file_name.as_str()]]);
        let differs = listed
            .iter()
            .map(|file| file.file_name.as_str())
            .ne(by_effective.iter().map(|file| file.file_name.as_str()));
        if differs {
            let affected: Vec<String> = listed
                .iter()
                .map(|file| file.file_name.clone())
                .collect();
            problems.push(grouped_problem(
                "playlist-order-differs",
                "warning",
                "Playlist order differs from playback order",
                "The playlist lists the tracks in a different order than the effective disc/track playback order. Reorder the playlist to match, or align filenames and tags, then rescan.".to_string(),
                affected,
            ));
        }
    }

    if !unrecognised_audio.is_empty() {
        problems.push(grouped_problem(
            "unrecognised-audio-files",
            "info",
            "Some audio files are invisible to the media library",
            "These extensions play in the player app but the library scanner does not catalog them, so they are missing from metadata views. Convert them to a cataloged format (mp3, m4a, flac, ogg, opus) to manage them here.".to_string(),
            unrecognised_audio,
        ));
    }

    let rows = files
        .iter()
        .enumerate()
        .map(|(index, file)| {
            let filename_number =
                filename_sequence_number(&file.file_name).map(|(_, track)| track);
            let agreed = match (filename_number, file.tag_track) {
                (Some(filename), Some(tag)) => {
                    filename == tag && filename_rank[&index] == effective_position[&index]
                }
                (None, None) => true,
                _ => false,
            };
            TrackOrderFileRow {
                file_name: file.file_name.clone(),
                filename_number,
                tag_disc: file.tag_disc,
                tag_track: file.tag_track,
                playlist_position: playlist_positions.get(&file.file_name).copied(),
                effective_position: effective_position[&index],
                status: if agreed { "agree".to_string() } else { "mismatch".to_string() },
            }
        })
        .collect::<Vec<_>>();

    let status = if problems.iter().any(|problem| problem.severity == "error") {
        "error"
    } else if problems.is_empty() {
        "ok"
    } else {
        "warning"
    }
    .to_string();

    TrackOrderReport {
        status,
        file_count: files.len(),
        playlist_name,
        files: rows,
        problems,
    }
}

/// Maximum bytes read from a single playlist sidecar.
pub const MAX_PLAYLIST_BYTES: u64 = 128 * 1024;

fn grouped_problem(
    code: &str,
    severity: &str,
    title: &str,
    message: String,
    affected: Vec<String>,
) -> TrackOrderProblem {
    let affected_file_count = affected.len();
    let affected_files = affected.into_iter().take(MAX_AFFECTED_FILES).collect();
    TrackOrderProblem {
        code: code.to_string(),
        severity: severity.to_string(),
        title: title.to_string(),
        message,
        affected_files,
        affected_file_count,
    }
}

/// Inspect one audiobook/podcast/music folder on disk and assess its play
/// order: audio siblings, the first playlist sidecar, and audio files the
/// scanner does not catalog. Returns the report (None for folders with
/// fewer than two audio files and nothing else of interest) plus non-fatal
/// warnings for the inspection-warnings channel.
pub fn inspect_folder_track_order(
    root: &Path,
    folder_relative_path: &str,
    category: LibraryCategory,
) -> (Option<TrackOrderReport>, Vec<String>) {
    let mut warnings = Vec::new();
    let directory = match open_directory_beneath(root, folder_relative_path) {
        Ok(directory) => directory,
        Err(_) => {
            return (
                None,
                vec![
                    "The folder could not be opened for track-order inspection.".to_string(),
                ],
            );
        }
    };
    let directory_path = format!("/proc/self/fd/{}", directory.as_raw_fd());
    let entries = match std::fs::read_dir(&directory_path) {
        Ok(entries) => entries,
        Err(_) => {
            return (
                None,
                vec![
                    "The folder could not be listed for track-order inspection.".to_string(),
                ],
            );
        }
    };
    let mut names = Vec::new();
    let mut truncated = false;
    for (index, entry) in entries.enumerate() {
        if index >= MAX_TRACK_ORDER_FILES {
            truncated = true;
            break;
        }
        let Ok(entry) = entry else { continue };
        let Ok(file_type) = entry.file_type() else { continue };
        if !file_type.is_file() || file_type.is_symlink() {
            continue;
        }
        let name = entry.file_name().to_string_lossy().into_owned();
        if name.is_empty() || name.contains('\0') || name == "." || name == ".." {
            continue;
        }
        names.push(name);
    }
    if truncated {
        warnings.push(format!(
            "Track-order inspection looked at the first {MAX_TRACK_ORDER_FILES} folder entries."
        ));
    }
    let primary = category.primary_kind();
    let mut audio = Vec::new();
    let mut playlists = Vec::new();
    let mut unrecognised = Vec::new();
    for name in names {
        let extension = name
            .rsplit_once('.')
            .map(|(_, extension)| extension.to_ascii_lowercase())
            .unwrap_or_default();
        if PLAYLIST_EXTENSIONS.contains(&extension.as_str()) {
            playlists.push(name);
            continue;
        }
        match classify(category, &extension) {
            Some(kind) if kind == primary => audio.push(name),
            // Companion kinds (artwork, subtitles) travel with their item.
            Some(_) => {}
            None if UNRECOGNISED_AUDIO_EXTENSIONS.contains(&extension.as_str()) => {
                unrecognised.push(name)
            }
            None => {}
        }
    }
    audio.sort();
    unrecognised.sort();
    playlists.sort();
    if audio.len() < 2 && playlists.is_empty() && unrecognised.is_empty() {
        return (None, warnings);
    }

    let mut playlist_name = None;
    let mut playlist_entries = Vec::new();
    if let Some(name) = playlists.first().cloned() {
        if playlists.len() > 1 {
            warnings.push(format!(
                "The folder holds {} playlists; track order was assessed against {}.",
                playlists.len(),
                name,
            ));
        }
        let relative = format!("{folder_relative_path}/{name}");
        match open_regular_file_beneath(root, &relative) {
            Ok(file) => {
                let mut bytes = Vec::new();
                if file
                    .take(MAX_PLAYLIST_BYTES + 1)
                    .read_to_end(&mut bytes)
                    .is_ok()
                    && bytes.len() as u64 <= MAX_PLAYLIST_BYTES
                {
                    match String::from_utf8(bytes) {
                        Ok(text) => {
                            playlist_name = Some(name);
                            playlist_entries = parse_m3u_playlist(&text);
                        }
                        Err(_) => warnings.push(format!(
                            "{name} is not UTF-8 text and was skipped as an ordering reference."
                        )),
                    }
                } else {
                    warnings.push(format!(
                        "{name} exceeds the {MAX_PLAYLIST_BYTES} byte playlist inspection limit."
                    ));
                }
            }
            Err(_) => warnings.push(format!(
                "{name} could not be opened as an ordering reference."
            )),
        }
    }

    let mut track_files = Vec::new();
    for name in &audio {
        let relative = format!("{folder_relative_path}/{name}");
        let (disc, track) = crate::metadata::audio_track_numbers(root, &relative);
        track_files.push(TrackOrderFile {
            file_name: name.clone(),
            tag_disc: disc,
            tag_track: track,
        });
    }
    let report = assess_track_order(track_files, playlist_name, playlist_entries, unrecognised);
    (Some(report), warnings)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn file(name: &str, tag_track: Option<u64>) -> TrackOrderFile {
        TrackOrderFile {
            file_name: name.to_string(),
            tag_disc: Some(1),
            tag_track,
        }
    }

    #[test]
    fn filename_numbers_parse_common_audiobook_forms() {
        assert_eq!(filename_sequence_number("01_lawson.mp3"), Some((1, 1)));
        assert_eq!(filename_sequence_number("00_lawson.mp3"), Some((1, 0)));
        assert_eq!(
            filename_sequence_number("10 - Chapter Ten.mp3"),
            Some((1, 10))
        );
        assert_eq!(filename_sequence_number("CD2-03.mp3"), Some((2, 3)));
        assert_eq!(filename_sequence_number("Disc 1 - 04.mp3"), Some((1, 4)));
        assert_eq!(filename_sequence_number("Part 2.mp3"), Some((1, 2)));
        assert_eq!(filename_sequence_number("track 07.mp3"), Some((1, 7)));
        assert_eq!(filename_sequence_number("07/31.mp3"), Some((1, 7)));
        assert_eq!(filename_sequence_number("Prologue.mp3"), None);
        assert_eq!(filename_sequence_number("Andy's Gone With Cattle.mp3"), None);
    }

    #[test]
    fn playlists_skip_directives_and_keep_basenames() {
        let entries =
            parse_m3u_playlist("#EXTM3U\n#EXTINF:123,artist - title\nsub/dir/01.mp3\r\n\n02.mp3\n");
        assert_eq!(entries, vec!["01.mp3".to_string(), "02.mp3".to_string()]);
    }

    #[test]
    fn lawson_regression_zero_based_files_vs_one_based_tags_mismatch() {
        // Mirrors Lawson before the rename: files 00..02 with tags 1..3,
        // plus an uppercase playlist that cannot resolve on Linux.
        let files = vec![
            file("00_lawson.mp3", Some(1)),
            file("01_lawson.mp3", Some(2)),
            file("02_lawson.mp3", Some(3)),
        ];
        let playlist = vec![
            "00_Lawson.mp3".to_string(),
            "01_Lawson.mp3".to_string(),
            "02_Lawson.mp3".to_string(),
        ];
        let report = assess_track_order(
            files,
            Some("lawson playlist.m3u".to_string()),
            playlist,
            Vec::new(),
        );
        assert_eq!(report.status, "error");
        let codes: Vec<&str> = report
            .problems
            .iter()
            .map(|problem| problem.code.as_str())
            .collect();
        assert!(codes.contains(&"track-order-mismatch"), "{codes:?}");
        assert!(
            codes.contains(&"track-sequence-gap-or-duplicate"),
            "{codes:?}"
        );
        assert!(codes.contains(&"unresolved-playlist-entries"), "{codes:?}");
        // One grouped problem per code, never one per file.
        assert_eq!(report.problems.len(), codes.len());
        let unresolved = report
            .problems
            .iter()
            .find(|problem| problem.code == "unresolved-playlist-entries")
            .unwrap();
        assert!(
            unresolved.message.contains("00_lawson.mp3"),
            "{}",
            unresolved.message
        );
    }

    #[test]
    fn consistent_one_based_folder_is_clean() {
        let files = vec![file("01_lawson.mp3", Some(1)), file("02_lawson.mp3", Some(2))];
        let playlist = vec!["01_lawson.mp3".to_string(), "02_lawson.mp3".to_string()];
        let report = assess_track_order(
            files,
            Some("lawson playlist.m3u".to_string()),
            playlist,
            Vec::new(),
        );
        assert!(report.problems.is_empty(), "{:?}", report.problems);
        assert_eq!(report.status, "ok");
    }

    #[test]
    fn unrecognised_audio_is_a_single_grouped_info() {
        let files = vec![file("01.mp3", Some(1))];
        let report = assess_track_order(files, None, Vec::new(), vec!["bonus.wav".to_string()]);
        assert_eq!(report.problems.len(), 1);
        assert_eq!(report.problems[0].code, "unrecognised-audio-files");
        assert_eq!(report.problems[0].severity, "info");
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn folder_inspection_reads_playlists_and_unrecognised_audio_from_disk() {
        use crate::media::LibraryCategory;
        let temp = tempfile::tempdir().expect("tempdir");
        let folder = temp.path().join("Lawson");
        std::fs::create_dir(&folder).expect("mkdir");
        // Tagless stand-ins: tag reads fail open, filename/playlist logic
        // and the case-sensitive playlist check still apply.
        for name in ["01_lawson.mp3", "02_lawson.mp3", "bonus.wav", "cover.jpg"] {
            std::fs::write(folder.join(name), b"not really audio").expect("write");
        }
        std::fs::write(
            folder.join("lawson playlist.m3u"),
            "01_Lawson.mp3\n02_lawson.mp3\n",
        )
        .expect("m3u");
        let (report, warnings) = inspect_folder_track_order(
            temp.path(),
            "Lawson",
            LibraryCategory::Audiobooks,
        );
        assert!(warnings.is_empty(), "{warnings:?}");
        let report = report.expect("report");
        assert_eq!(report.file_count, 2);
        assert_eq!(report.playlist_name.as_deref(), Some("lawson playlist.m3u"));
        let codes: Vec<&str> = report
            .problems
            .iter()
            .map(|problem| problem.code.as_str())
            .collect();
        assert!(codes.contains(&"unresolved-playlist-entries"), "{codes:?}");
        assert!(codes.contains(&"unrecognised-audio-files"), "{codes:?}");
        // cover.jpg is a companion file, not an unrecognised-audio problem.
        let unrecognised = report
            .problems
            .iter()
            .find(|problem| problem.code == "unrecognised-audio-files")
            .unwrap();
        assert_eq!(unrecognised.affected_files, vec!["bonus.wav".to_string()]);
        let unresolved = report
            .problems
            .iter()
            .find(|problem| problem.code == "unresolved-playlist-entries")
            .unwrap();
        assert!(unresolved.message.contains("01_lawson.mp3"), "{}", unresolved.message);
    }
}
