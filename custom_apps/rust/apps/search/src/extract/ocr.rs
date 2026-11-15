//! Reads the words in scanned pages and pictures. Extraction otherwise sees
//! only a text layer, so a scanned letter attached to an email or a scanned
//! book contributed nothing to the index. Recognition is slow (seconds a
//! page), so it runs only where there is no text to read, is bounded per
//! document, and its output is kept only when it looks like language.
use std::collections::HashMap;
use std::io::{Read, Write};
use std::os::unix::fs::OpenOptionsExt;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::LazyLock;
use std::time::{Duration, Instant};

/// Pages recognised per document. A longer scan keeps its first pages.
const PAGE_LIMIT: usize = 400;
/// One page or picture; a stuck recognition is abandoned.
const PAGE_TIMEOUT: Duration = Duration::from_secs(90);
const WORKERS: usize = 4;
/// A page with fewer letters and digits than this has no text layer worth
/// keeping: a scan, or a page number over a picture.
const TEXT_LAYER_MINIMUM: usize = 16;

struct Tools {
    tesseract: PathBuf,
    pdftoppm: Option<PathBuf>,
    languages: String,
}

/// `SEARCH_TESSERACT` enables recognition; `SEARCH_PDFTOPPM` adds scanned PDF
/// pages. Without them extraction behaves as it did before.
static TOOLS: LazyLock<Option<Tools>> = LazyLock::new(|| {
    let binary = |name: &str| {
        std::env::var_os(name)
            .map(PathBuf::from)
            .filter(|path| path.exists())
    };
    Some(Tools {
        tesseract: binary("SEARCH_TESSERACT")?,
        pdftoppm: binary("SEARCH_PDFTOPPM"),
        languages: std::env::var("SEARCH_OCR_LANGUAGES")
            .ok()
            .filter(|value| !value.trim().is_empty())
            .unwrap_or_else(|| "eng".to_string()),
    })
});

fn letters(text: &str) -> usize {
    text.chars().filter(|c| c.is_alphanumeric()).count()
}

/// Whether recognised text reads as language rather than the noise produced
/// by photographs, logos and decorative pages: enough real words, and most of
/// what was recognised being words.
pub(crate) fn readable(text: &str, minimum_words: usize) -> bool {
    let mut words = 0;
    let mut tokens = 0;
    for token in text.split_whitespace() {
        tokens += 1;
        let alphabetic = token.chars().filter(|c| c.is_alphabetic()).count();
        if alphabetic >= 3 && alphabetic * 4 >= token.chars().count() * 3 {
            words += 1;
        }
    }
    words >= minimum_words && words * 2 >= tokens
}

fn wait(mut child: Child, deadline: Instant) -> Option<Vec<u8>> {
    let mut stdout = child.stdout.take()?;
    let reader = std::thread::spawn(move || {
        let mut out = Vec::new();
        // Recognised text for one page is small; bound it regardless.
        let _ = (&mut stdout).take(4_000_000).read_to_end(&mut out);
        out
    });
    loop {
        match child.try_wait() {
            Ok(Some(status)) => {
                let out = reader.join().ok()?;
                return status.success().then_some(out);
            }
            Ok(None) if Instant::now() < deadline => {
                std::thread::sleep(Duration::from_millis(25));
            }
            _ => {
                let _ = child.kill();
                let _ = child.wait();
                return None;
            }
        }
    }
}

fn recognise(tools: &Tools, image: Stdio) -> Option<Child> {
    Command::new(&tools.tesseract)
        .args(["stdin", "stdout", "-l", &tools.languages])
        // Several pages are recognised side by side; one thread each.
        .env("OMP_THREAD_LIMIT", "1")
        .stdin(image)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()
}

fn clean(bytes: Vec<u8>) -> Option<String> {
    let text = String::from_utf8_lossy(&bytes).trim().to_string();
    (!text.is_empty()).then_some(text)
}

/// The words in a picture (PNG, JPEG, TIFF, GIF, BMP or WebP), unfiltered.
pub(crate) fn image_text(bytes: &[u8]) -> Option<String> {
    let tools = TOOLS.as_ref()?;
    let mut child = recognise(tools, Stdio::piped())?;
    let mut stdin = child.stdin.take()?;
    let deadline = Instant::now() + PAGE_TIMEOUT;
    let out = std::thread::scope(|scope| {
        // Feed while draining, as with pdftotext: a large picture fills the
        // pipe before recognition has read it.
        scope.spawn(move || {
            let _ = stdin.write_all(bytes);
        });
        wait(child, deadline)
    })?;
    clean(out)
}

fn page_text(tools: &Tools, pdftoppm: &Path, pdf: &Path, page: usize) -> Option<String> {
    let page = page.to_string();
    let mut render = Command::new(pdftoppm)
        .args(["-r", "200", "-gray", "-png", "-f", &page, "-l", &page])
        .arg(pdf)
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn()
        .ok()?;
    let deadline = Instant::now() + PAGE_TIMEOUT;
    let image = render.stdout.take()?;
    let out = recognise(tools, Stdio::from(image)).and_then(|child| wait(child, deadline));
    let _ = render.kill();
    let _ = render.wait();
    clean(out?)
}

/// Splits pdftotext output into pages and lists those without a text layer.
fn scanned_pages(text: &str) -> (Vec<String>, Vec<usize>) {
    let mut pages: Vec<String> = text.split('\u{c}').map(str::to_string).collect();
    // pdftotext ends every page with a form feed, leaving an empty tail.
    if pages.last().is_some_and(|page| page.trim().is_empty()) {
        pages.pop();
    }
    let scanned = pages
        .iter()
        .enumerate()
        .filter(|(_, page)| letters(page) < TEXT_LAYER_MINIMUM)
        .map(|(index, _)| index)
        .take(PAGE_LIMIT)
        .collect();
    (pages, scanned)
}

/// Adds recognised text to the pages of `text` (pdftotext output, pages
/// separated by form feeds) that have no text layer.
pub(crate) fn fill_scanned_pages(pdf: &Path, text: String) -> String {
    let Some(tools) = TOOLS.as_ref() else {
        return text;
    };
    let Some(pdftoppm) = tools.pdftoppm.as_deref() else {
        return text;
    };
    let (mut pages, scanned) = scanned_pages(&text);
    if scanned.is_empty() {
        return text;
    }
    let next = std::sync::atomic::AtomicUsize::new(0);
    let found: HashMap<usize, String> = std::thread::scope(|scope| {
        let workers: Vec<_> = (0..WORKERS.min(scanned.len()))
            .map(|_| {
                scope.spawn(|| {
                    let mut found = Vec::new();
                    loop {
                        let slot = next.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
                        let Some(&index) = scanned.get(slot) else {
                            break;
                        };
                        if let Some(text) = page_text(tools, pdftoppm, pdf, index + 1)
                            && readable(&text, 4)
                        {
                            found.push((index, text));
                        }
                    }
                    found
                })
            })
            .collect();
        workers
            .into_iter()
            .flat_map(|worker| worker.join().unwrap_or_default())
            .collect()
    });
    if found.is_empty() {
        return text;
    }
    for (index, recognised) in found {
        pages[index] = recognised;
    }
    pages.join("\u{c}")
}

/// As `fill_scanned_pages` for a PDF held in memory, such as a mail
/// attachment. The bytes are written to a private temporary file only when
/// some page needs recognising.
pub(crate) fn fill_scanned_pages_of_bytes(bytes: &[u8], text: String) -> String {
    static COUNTER: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);
    if TOOLS.as_ref().is_none_or(|tools| tools.pdftoppm.is_none())
        || scanned_pages(&text).1.is_empty()
    {
        return text;
    }
    let path = std::env::temp_dir().join(format!(
        "search-ocr-{}-{}.pdf",
        std::process::id(),
        COUNTER.fetch_add(1, std::sync::atomic::Ordering::Relaxed)
    ));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&path)
        .and_then(|mut file| file.write_all(bytes));
    let text = match written {
        Ok(()) => fill_scanned_pages(&path, text),
        Err(_) => text,
    };
    let _ = std::fs::remove_file(&path);
    text
}
