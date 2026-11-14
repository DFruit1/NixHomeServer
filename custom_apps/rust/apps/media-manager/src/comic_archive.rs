//! CBR comics → CBZ.
//!
//! A `.cbr` comic is normally a RAR archive. RAR is proprietary: free software
//! can read it but not write it, so a CBR cannot carry edited metadata. CBZ is
//! the same pages in an ordinary ZIP archive, which Kavita and Media Manager
//! can rewrite. Many `.cbr` files are already ZIP archives with the wrong
//! extension; those only need a rename.
//!
//! Reading RAR uses libarchive's `bsdtar` rather than Rust: no maintained
//! pure-Rust RAR decoder exists, and libarchive reads RAR4, RAR5 (including
//! solid archives) and 7z under a free licence. `bsdtar` streams the source
//! entries straight into a stored ZIP without unpacking them to disk. The
//! result is accepted only when a SHA-256 manifest of every entry matches the
//! source exactly.

use crate::broker::open_regular_file_beneath;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::path::Path;
use std::process::Stdio;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use zip::ZipArchive;

const RUN_TIMEOUT: Duration = Duration::from_secs(20 * 60);
const MAX_MANIFEST_BYTES: u64 = 64 * 1024 * 1024;
const MAX_STDERR_BYTES: u64 = 16 * 1024;
pub const MAX_CONVERTIBLE_BYTES: u64 = 4 * 1024 * 1024 * 1024;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ArchiveFormat {
    Zip,
    Rar,
    SevenZip,
    Unknown,
}

impl ArchiveFormat {
    pub const fn as_str(self) -> &'static str {
        match self {
            ArchiveFormat::Zip => "zip",
            ArchiveFormat::Rar => "rar",
            ArchiveFormat::SevenZip => "7z",
            ArchiveFormat::Unknown => "unknown",
        }
    }
}

/// Identify the archive by its signature, leaving the file at offset 0.
pub fn sniff(file: &mut File) -> std::io::Result<ArchiveFormat> {
    let mut header = [0u8; 8];
    file.seek(SeekFrom::Start(0))?;
    let read = file.by_ref().take(8).read(&mut header)?;
    file.seek(SeekFrom::Start(0))?;
    let header = &header[..read];
    Ok(
        if header.starts_with(b"PK\x03\x04") || header.starts_with(b"PK\x05\x06") {
            ArchiveFormat::Zip
        } else if header.starts_with(b"Rar!\x1a\x07") {
            ArchiveFormat::Rar
        } else if header.starts_with(b"7z\xbc\xaf\x27\x1c") {
            ArchiveFormat::SevenZip
        } else {
            ArchiveFormat::Unknown
        },
    )
}

/// Sniff a catalog file without following symlinks out of its root.
pub fn sniff_beneath(root: &Path, relative_path: &str) -> Result<ArchiveFormat, String> {
    let mut file = open_regular_file_beneath(root, relative_path)
        .map_err(|error| format!("open comic: {error}"))?;
    sniff(&mut file).map_err(|error| format!("read comic: {error}"))
}

/// Whether a catalog path names a live CBR comic. Copies kept in a
/// `superseded` folder are archived originals and are never offered again.
pub fn is_cbr(relative_path: &str) -> bool {
    relative_path
        .rsplit_once('.')
        .is_some_and(|(_, extension)| extension.eq_ignore_ascii_case("cbr"))
        && !relative_path
            .split('/')
            .rev()
            .skip(1)
            .any(|folder| folder == "superseded")
}

/// The same-folder, same-name `.cbz` path for a `.cbr` path.
pub fn cbz_destination(relative_path: &str) -> Option<String> {
    is_cbr(relative_path).then(|| {
        let (stem, _) = relative_path
            .rsplit_once('.')
            .expect("CBR has an extension");
        format!("{stem}.cbz")
    })
}

/// Repack `source` (RAR or 7z) as a stored ZIP in `output`, then prove every
/// entry is byte-identical. Returns the number of files in the comic.
pub async fn repack_as_cbz(bsdtar: &Path, source: &File, output: &File) -> Result<usize, String> {
    run(
        bsdtar,
        &[
            "-cf",
            "-",
            "--format",
            "zip",
            "--options",
            "zip:compression=store",
            "@-",
        ],
        source,
        Some(output),
    )
    .await
    .map_err(|error| format!("could not read the comic archive: {error}"))?;
    output
        .sync_all()
        .map_err(|error| format!("sync CBZ: {error}"))?;
    let expected = manifest(bsdtar, source).await?;
    let actual = manifest(bsdtar, output)
        .await
        .map_err(|error| format!("the new CBZ could not be read back: {error}"))?;
    if expected != actual {
        return Err("the new CBZ does not match the original pages; nothing was changed".into());
    }
    let files = expected
        .lines()
        .filter(|line| line.contains(" type=file "))
        .count();
    if files == 0 {
        return Err("the comic archive contains no files".into());
    }
    let mut zip = output
        .try_clone()
        .map_err(|error| format!("reopen CBZ: {error}"))?;
    zip.seek(SeekFrom::Start(0))
        .map_err(|error| format!("rewind CBZ: {error}"))?;
    let mut archive = ZipArchive::new(zip).map_err(|error| format!("open CBZ: {error}"))?;
    crate::metadata::validate_archive_entry_names(&archive)?;
    if archive
        .has_overlapping_files()
        .map_err(|error| format!("inspect CBZ layout: {error}"))?
    {
        return Err("the new CBZ has overlapping entries".into());
    }
    Ok(files)
}

/// Type, size and SHA-256 of every entry, in archive order (bsdtar mtree).
async fn manifest(bsdtar: &Path, archive: &File) -> Result<String, String> {
    let bytes = run(
        bsdtar,
        &[
            "-cf",
            "-",
            "--format=mtree",
            "--options",
            "!all,type,size,sha256",
            "@-",
        ],
        archive,
        None,
    )
    .await?;
    let text = String::from_utf8(bytes).map_err(|_| "archive manifest is not UTF-8".to_string())?;
    // Archive order differs between RAR and ZIP; compare as sorted sets.
    let mut lines = text
        .lines()
        .filter(|line| !line.starts_with('#') && !line.trim().is_empty())
        .map(str::to_string)
        .collect::<Vec<_>>();
    lines.sort();
    Ok(lines.join("\n"))
}

/// Run bsdtar with `input` on stdin, writing stdout to `output` or capturing
/// it (bounded). A non-zero exit is an error carrying bsdtar's message.
async fn run(
    bsdtar: &Path,
    args: &[&str],
    input: &File,
    output: Option<&File>,
) -> Result<Vec<u8>, String> {
    let mut stdin = input
        .try_clone()
        .map_err(|error| format!("reopen input: {error}"))?;
    // The clone shares the file offset; bsdtar must start at the beginning.
    stdin
        .seek(SeekFrom::Start(0))
        .map_err(|error| format!("rewind input: {error}"))?;
    let stdout = match output {
        Some(file) => {
            let mut file = file
                .try_clone()
                .map_err(|error| format!("reopen output: {error}"))?;
            file.seek(SeekFrom::Start(0))
                .map_err(|error| format!("rewind output: {error}"))?;
            file.set_len(0)
                .map_err(|error| format!("truncate output: {error}"))?;
            Stdio::from(file)
        }
        None => Stdio::piped(),
    };
    let mut child = tokio::process::Command::new(bsdtar)
        .args(args)
        .env_clear()
        // Without a UTF-8 locale bsdtar cannot translate non-ASCII page names.
        .env("LC_ALL", "C.UTF-8")
        .stdin(Stdio::from(stdin))
        .stdout(stdout)
        .stderr(Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|error| format!("run bsdtar: {error}"))?;
    let stdout = child.stdout.take();
    let stderr = child.stderr.take();
    let work = async {
        let captured = async {
            let mut bytes = Vec::new();
            if let Some(stdout) = stdout {
                stdout
                    .take(MAX_MANIFEST_BYTES + 1)
                    .read_to_end(&mut bytes)
                    .await
                    .map_err(|error| format!("read bsdtar output: {error}"))?;
            }
            Ok::<_, String>(bytes)
        };
        let messages = async {
            let mut bytes = Vec::new();
            if let Some(stderr) = stderr {
                let _ = stderr.take(MAX_STDERR_BYTES).read_to_end(&mut bytes).await;
            }
            bytes
        };
        let (captured, messages) = tokio::join!(captured, messages);
        let status = child
            .wait()
            .await
            .map_err(|error| format!("wait for bsdtar: {error}"))?;
        Ok::<_, String>((captured?, messages, status))
    };
    let (captured, messages, status) = tokio::time::timeout(RUN_TIMEOUT, work)
        .await
        .map_err(|_| "bsdtar timed out".to_string())??;
    if captured.len() as u64 > MAX_MANIFEST_BYTES {
        return Err("archive listing is too large".into());
    }
    if !status.success() {
        let message = String::from_utf8_lossy(&messages);
        let message = message
            .lines()
            .map(|line| line.trim_start_matches("bsdtar: ").trim())
            .find(|line| !line.is_empty() && !line.starts_with("Error exit delayed"))
            .unwrap_or("bsdtar failed");
        return Err(message.to_string());
    }
    Ok(captured)
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;

    fn temp_file(bytes: &[u8]) -> File {
        let mut file = tempfile::tempfile().expect("temporary file");
        file.write_all(bytes).expect("write");
        file
    }

    #[test]
    fn sniffs_archive_signatures_and_rewinds() {
        for (bytes, format) in [
            (&b"PK\x03\x04rest"[..], ArchiveFormat::Zip),
            (b"Rar!\x1a\x07\x01\x00", ArchiveFormat::Rar),
            (b"Rar!\x1a\x07\x00", ArchiveFormat::Rar),
            (b"7z\xbc\xaf\x27\x1c\x00\x04", ArchiveFormat::SevenZip),
            (b"%PDF-1.7", ArchiveFormat::Unknown),
            (b"", ArchiveFormat::Unknown),
        ] {
            let mut file = temp_file(bytes);
            assert_eq!(sniff(&mut file).unwrap(), format);
            assert_eq!(file.stream_position().unwrap(), 0);
        }
    }

    #[test]
    fn destination_keeps_folder_and_name() {
        assert_eq!(
            cbz_destination("Comics/Saga/Saga 001.CBR").as_deref(),
            Some("Comics/Saga/Saga 001.cbz")
        );
        assert_eq!(cbz_destination("Saga.cbz"), None);
        assert_eq!(cbz_destination("Saga/superseded/Saga 001-r1.cbr"), None);
        assert_eq!(cbz_destination("cbr"), None);
    }

    /// Runs only where a bsdtar is provided (`MEDIA_MANAGER_TEST_BSDTAR`):
    /// a repack must reproduce every page, and a mismatch must be refused.
    #[tokio::test]
    async fn repack_round_trips_pages_with_bsdtar() {
        let Some(bsdtar) = std::env::var_os("MEDIA_MANAGER_TEST_BSDTAR") else {
            eprintln!("skipped: MEDIA_MANAGER_TEST_BSDTAR is not set");
            return;
        };
        let bsdtar = Path::new(&bsdtar);
        // A 7z-free fixture: libarchive also reads ZIP, which exercises the
        // same repack and manifest path without a proprietary RAR writer.
        let mut source = Vec::new();
        {
            let mut writer = zip::ZipWriter::new(std::io::Cursor::new(&mut source));
            let options = zip::write::SimpleFileOptions::default()
                .compression_method(zip::CompressionMethod::Deflated);
            for (name, body) in [
                ("001.png", &b"page one"[..]),
                ("sub/002 é.png", b"page two"),
                ("ComicInfo.xml", b"<ComicInfo/>"),
            ] {
                writer.start_file(name, options).unwrap();
                writer.write_all(body).unwrap();
            }
            writer.finish().unwrap();
        }
        let source = temp_file(&source);
        let output = tempfile::tempfile().unwrap();
        let files = repack_as_cbz(bsdtar, &source, &output).await.unwrap();
        assert_eq!(files, 3);
        let mut archive = ZipArchive::new(output.try_clone().unwrap()).unwrap();
        let mut page = String::new();
        archive
            .by_name("sub/002 é.png")
            .unwrap()
            .read_to_string(&mut page)
            .unwrap();
        assert_eq!(page, "page two");

        let other = temp_file(b"not an archive at all");
        let error = repack_as_cbz(bsdtar, &other, &tempfile::tempfile().unwrap())
            .await
            .unwrap_err();
        assert!(error.contains("could not read"), "{error}");
    }
}
