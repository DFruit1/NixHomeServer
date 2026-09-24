use std::collections::HashMap;
use std::io::Read;
use std::path::{Path, PathBuf};

use rusqlite::{Connection, OpenFlags};
use zip::ZipArchive;

use super::paperless::extract_pdf_text;
use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::text::html_to_text;
use crate::timeutil::parse_date;

/// Upper bound on the body text copied out of a single book. Technical books
/// can run to several megabytes of extracted text; the index only needs the
/// searchable prose, and bounded bodies keep the Postgres row and indexing
/// pass predictable.
const BODY_LIMIT: usize = 2_000_000;

/// Extracts one document per Calibre book from a Calibre `metadata.db`.
///
/// The body combines the catalog metadata, the book's description/comment, and
/// the text of the best available format (EPUB over PDF over plain text), so a
/// query like "beam deflection" can match body prose as well as title, author,
/// series, or tag. Other formats are recorded in metadata but not extracted.
pub struct CalibreExtractor {
    pub pdftotext: Option<PathBuf>,
}

struct BookRow {
    id: i64,
    title: String,
    path: String,
    timestamp: Option<String>,
    last_modified: Option<String>,
    series_index: Option<f64>,
}

#[derive(Clone)]
struct FormatFile {
    format: String,
    name: String,
}

fn open_read_only(path: &Path) -> Result<Connection, String> {
    let connection = Connection::open_with_flags(path, OpenFlags::SQLITE_OPEN_READ_ONLY)
        .map_err(|err| format!("failed to open Calibre database {}: {err}", path.display()))?;
    // metadata.db is written by Calibre-Web while the indexer reads it.
    connection
        .busy_timeout(std::time::Duration::from_secs(15))
        .map_err(|err| format!("failed to configure Calibre database timeout: {err}"))?;
    Ok(connection)
}

fn load_books(connection: &Connection) -> Result<Vec<BookRow>, String> {
    let mut statement = connection
        .prepare("SELECT id, title, path, timestamp, last_modified, series_index FROM books")
        .map_err(|err| format!("failed to query Calibre books: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok(BookRow {
                id: row.get(0)?,
                title: row.get(1)?,
                path: row.get(2)?,
                timestamp: row.get(3)?,
                last_modified: row.get(4)?,
                series_index: row.get(5)?,
            })
        })
        .map_err(|err| format!("failed to query Calibre books: {err}"))?;
    let mut books = Vec::new();
    for row in rows {
        books.push(row.map_err(|err| format!("failed to read Calibre books: {err}"))?);
    }
    Ok(books)
}

/// Loads a `(book, value)` association table into a map, dropping empty values.
fn load_book_values(
    connection: &Connection,
    sql: &str,
) -> Result<HashMap<i64, Vec<String>>, String> {
    let mut statement = connection
        .prepare(sql)
        .map_err(|err| format!("failed to query Calibre metadata: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .map_err(|err| format!("failed to query Calibre metadata: {err}"))?;
    let mut map: HashMap<i64, Vec<String>> = HashMap::new();
    for row in rows {
        let (book, value) = row.map_err(|err| format!("failed to read Calibre metadata: {err}"))?;
        if let Some(value) = value.filter(|value| !value.trim().is_empty()) {
            map.entry(book).or_default().push(value);
        }
    }
    Ok(map)
}

fn load_comments(connection: &Connection) -> Result<HashMap<i64, String>, String> {
    let mut statement = connection
        .prepare("SELECT book, text FROM comments")
        .map_err(|err| format!("failed to query Calibre comments: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((row.get::<_, i64>(0)?, row.get::<_, Option<String>>(1)?))
        })
        .map_err(|err| format!("failed to query Calibre comments: {err}"))?;
    let mut map = HashMap::new();
    for row in rows {
        let (book, text) = row.map_err(|err| format!("failed to read Calibre comments: {err}"))?;
        if let Some(text) = text.filter(|text| !text.trim().is_empty()) {
            map.insert(book, text);
        }
    }
    Ok(map)
}

fn load_formats(connection: &Connection) -> Result<HashMap<i64, Vec<FormatFile>>, String> {
    let mut statement = connection
        .prepare("SELECT book, format, name FROM data")
        .map_err(|err| format!("failed to query Calibre formats: {err}"))?;
    let rows = statement
        .query_map([], |row| {
            Ok((
                row.get::<_, i64>(0)?,
                row.get::<_, Option<String>>(1)?,
                row.get::<_, Option<String>>(2)?,
            ))
        })
        .map_err(|err| format!("failed to query Calibre formats: {err}"))?;
    let mut map: HashMap<i64, Vec<FormatFile>> = HashMap::new();
    for row in rows {
        let (book, format, name) =
            row.map_err(|err| format!("failed to read Calibre formats: {err}"))?;
        if let (Some(format), Some(name)) = (format, name) {
            if !format.trim().is_empty() && !name.trim().is_empty() {
                map.entry(book)
                    .or_default()
                    .push(FormatFile { format, name });
            }
        }
    }
    Ok(map)
}

fn format_priority(format: &str) -> u8 {
    match format.to_ascii_lowercase().as_str() {
        "epub" => 0,
        "pdf" => 1,
        "txt" => 2,
        "html" | "htm" => 3,
        _ => 4,
    }
}

fn content_type_for_format(format: &str) -> String {
    match format.to_ascii_lowercase().as_str() {
        "epub" => "application/epub+zip".to_string(),
        "pdf" => "application/pdf".to_string(),
        "txt" => "text/plain".to_string(),
        "html" | "htm" => "text/html".to_string(),
        "mobi" => "application/x-mobipocket-ebook".to_string(),
        "azw3" => "application/vnd.amazon.ebook".to_string(),
        _ => "application/octet-stream".to_string(),
    }
}

fn format_path(library_root: &Path, book: &BookRow, format: &FormatFile) -> PathBuf {
    library_root.join(&book.path).join(format!(
        "{}.{}",
        format.name,
        format.format.to_ascii_lowercase()
    ))
}

fn format_file_size(path: &Path) -> i64 {
    std::fs::metadata(path)
        .map(|meta| meta.len() as i64)
        .unwrap_or(0)
}

/// Fingerprints the Calibre library (every file under the library root, path,
/// size and mtime) plus the source settings. `metadata.db` changes on any
/// Calibre import or edit, and book files change when a format is replaced, so
/// an unchanged inventory means the expensive EPUB/PDF body extraction can be
/// skipped. Returns `None` when the library is unreadable or empty, so the
/// indexer still runs extraction and its normal error path.
pub(crate) fn source_fingerprint(source: &SourceConfig) -> Option<String> {
    let library_root = source.setting_str("libraryRoot")?;
    let files = super::collect_files(Path::new(library_root), 6, &|_: &Path| true);
    if files.is_empty() {
        return None;
    }
    super::file_inventory_fingerprint(source, files)
}

fn extract_epub_text(path: &Path) -> Option<String> {
    let file = std::fs::File::open(path).ok()?;
    let mut archive = ZipArchive::new(std::io::BufReader::new(file)).ok()?;
    let mut names: Vec<String> = archive
        .file_names()
        .filter(|name| {
            let lower = name.to_ascii_lowercase();
            lower.ends_with(".xhtml") || lower.ends_with(".html") || lower.ends_with(".htm")
        })
        .map(str::to_string)
        .collect();
    names.sort();
    let mut body = String::new();
    for name in names {
        let Ok(mut entry) = archive.by_name(&name) else {
            continue;
        };
        let mut raw = String::new();
        if entry.read_to_string(&mut raw).is_err() {
            continue;
        }
        let text = html_to_text(&raw);
        if !text.trim().is_empty() {
            body.push_str(&text);
            body.push('\n');
        }
    }
    if body.trim().is_empty() {
        None
    } else {
        Some(body)
    }
}

fn extract_format_text(path: &Path, format: &str, pdftotext: Option<&Path>) -> Option<String> {
    match format.to_ascii_lowercase().as_str() {
        "epub" => extract_epub_text(path),
        "pdf" => extract_pdf_text(path, pdftotext)
            .ok()
            .filter(|text| !text.trim().is_empty()),
        "txt" => std::fs::read_to_string(path)
            .ok()
            .filter(|text| !text.trim().is_empty()),
        "html" | "htm" => std::fs::read_to_string(path)
            .ok()
            .map(|html| html_to_text(&html))
            .filter(|text| !text.trim().is_empty()),
        _ => None,
    }
}

fn truncate(value: &str, limit: usize) -> String {
    if value.len() <= limit {
        return value.to_string();
    }
    let mut truncated = value[..limit].to_string();
    while !truncated.is_char_boundary(truncated.len()) {
        truncated.pop();
    }
    truncated
}

impl super::Extractor for CalibreExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let library_root = source.require_setting("libraryRoot")?;
        let library_dir = PathBuf::from(&library_root);
        let metadata_db = library_dir.join("metadata.db");
        let app_base = source.app_base.trim_end_matches('/').to_string();

        let connection = open_read_only(&metadata_db)?;
        let books = load_books(&connection)?;
        let authors = load_book_values(
            &connection,
            "SELECT books_authors_link.book, authors.name \
             FROM books_authors_link JOIN authors ON authors.id = books_authors_link.author",
        )?;
        let series = load_book_values(
            &connection,
            "SELECT books_series_link.book, series.name \
             FROM books_series_link JOIN series ON series.id = books_series_link.series",
        )?;
        let tags = load_book_values(
            &connection,
            "SELECT books_tags_link.book, tags.name \
             FROM books_tags_link JOIN tags ON tags.id = books_tags_link.tag",
        )?;
        let publishers = load_book_values(
            &connection,
            "SELECT books_publishers_link.book, publishers.name \
             FROM books_publishers_link JOIN publishers ON publishers.id = books_publishers_link.publisher",
        )?;
        let languages = load_book_values(
            &connection,
            "SELECT books_languages_link.book, languages.lang_code \
             FROM books_languages_link JOIN languages ON languages.id = books_languages_link.lang_code",
        )?;
        let identifiers = load_book_values(
            &connection,
            "SELECT book, type || ':' || val FROM identifiers",
        )?;
        let comments = load_comments(&connection)?;
        let formats = load_formats(&connection)?;

        for book in books {
            let book_authors = authors.get(&book.id).cloned().unwrap_or_default();
            let book_series = series.get(&book.id).cloned().unwrap_or_default();
            let book_tags = tags.get(&book.id).cloned().unwrap_or_default();
            let book_publishers = publishers.get(&book.id).cloned().unwrap_or_default();
            let book_languages = languages.get(&book.id).cloned().unwrap_or_default();
            let book_identifiers = identifiers.get(&book.id).cloned().unwrap_or_default();
            let book_formats = formats.get(&book.id).cloned().unwrap_or_default();

            let mut total_size = 0i64;
            let mut primary_path = String::new();
            let mut content_type = "application/octet-stream".to_string();
            let mut book_text = String::new();

            let mut ordered: Vec<&FormatFile> = book_formats.iter().collect();
            ordered.sort_by_key(|format| format_priority(&format.format));
            for format in &ordered {
                let path = format_path(&library_dir, &book, format);
                total_size += format_file_size(&path);
                if book_text.is_empty() {
                    if let Some(text) =
                        extract_format_text(&path, &format.format, self.pdftotext.as_deref())
                    {
                        if !text.trim().is_empty() {
                            book_text = text;
                            primary_path = path.display().to_string();
                            content_type = content_type_for_format(&format.format);
                        }
                    }
                }
            }
            if primary_path.is_empty() {
                if let Some(first) = ordered.first() {
                    primary_path = format_path(&library_dir, &book, first)
                        .display()
                        .to_string();
                    content_type = content_type_for_format(&first.format);
                }
            }

            let mut body = String::new();
            body.push_str(&format!("Title: {}\n", book.title));
            if !book_authors.is_empty() {
                body.push_str(&format!("Authors: {}\n", book_authors.join(", ")));
            }
            if let Some(series_name) = book_series.first() {
                body.push_str(&format!("Series: {}", series_name));
                if let Some(index) = book.series_index {
                    body.push_str(&format!(" #{index}"));
                }
                body.push('\n');
            }
            if let Some(publisher) = book_publishers.first() {
                body.push_str(&format!("Publisher: {publisher}\n"));
            }
            if !book_tags.is_empty() {
                body.push_str(&format!("Tags: {}\n", book_tags.join(", ")));
            }
            if !book_languages.is_empty() {
                body.push_str(&format!("Language: {}\n", book_languages.join(", ")));
            }
            if let Some(description) = comments.get(&book.id) {
                body.push('\n');
                body.push_str(&html_to_text(description));
                body.push('\n');
            }
            if !book_text.trim().is_empty() {
                body.push('\n');
                body.push_str(&book_text);
            }

            let mut metadata = serde_json::Map::new();
            metadata.insert("owner".to_string(), serde_json::json!("shared"));
            if !book_authors.is_empty() {
                metadata.insert("authors".to_string(), serde_json::json!(book_authors));
            }
            if let Some(series_name) = book_series.first() {
                metadata.insert("series".to_string(), serde_json::json!(series_name));
            }
            if let Some(index) = book.series_index {
                metadata.insert("series_index".to_string(), serde_json::json!(index));
            }
            if !book_tags.is_empty() {
                metadata.insert("tags".to_string(), serde_json::json!(book_tags));
            }
            if let Some(publisher) = book_publishers.first() {
                metadata.insert("publisher".to_string(), serde_json::json!(publisher));
            }
            if !book_languages.is_empty() {
                metadata.insert("languages".to_string(), serde_json::json!(book_languages));
            }
            if !book_identifiers.is_empty() {
                metadata.insert(
                    "identifiers".to_string(),
                    serde_json::json!(book_identifiers),
                );
            }
            let format_names: Vec<String> = book_formats
                .iter()
                .map(|format| format.format.to_ascii_uppercase())
                .collect();
            if !format_names.is_empty() {
                metadata.insert("formats".to_string(), serde_json::json!(format_names));
            }

            emit(ExtractedDocument {
                external_id: book.id.to_string(),
                kind: "book".to_string(),
                title: if book.title.trim().is_empty() {
                    format!("Calibre book {}", book.id)
                } else {
                    book.title.clone()
                },
                body_text: truncate(&body, BODY_LIMIT),
                content_type,
                origin_url: String::new(),
                app_url: format!("{app_base}/book/{}", book.id),
                file_path: primary_path,
                size_bytes: total_size,
                content_created_at: book.timestamp.as_deref().and_then(parse_date),
                content_modified_at: book.last_modified.as_deref().and_then(parse_date),
                metadata: serde_json::Value::Object(metadata),
            });
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::super::Extractor;
    use super::*;

    fn create_library(dir: &Path) -> PathBuf {
        let library = dir.join("library");
        std::fs::create_dir_all(library.join("Some Author/Ref Book (1)")).expect("mkdir");
        let db = library.join("metadata.db");
        let connection = Connection::open(&db).expect("create db");
        connection
            .execute_batch(
                "
                CREATE TABLE books (
                    id INTEGER PRIMARY KEY,
                    title TEXT,
                    path TEXT,
                    timestamp TEXT,
                    last_modified TEXT,
                    series_index REAL
                );
                CREATE TABLE authors (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE books_authors_link (id INTEGER PRIMARY KEY, book INTEGER, author INTEGER);
                CREATE TABLE series (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE books_series_link (id INTEGER PRIMARY KEY, book INTEGER, series INTEGER);
                CREATE TABLE tags (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE books_tags_link (id INTEGER PRIMARY KEY, book INTEGER, tag INTEGER);
                CREATE TABLE publishers (id INTEGER PRIMARY KEY, name TEXT);
                CREATE TABLE books_publishers_link (id INTEGER PRIMARY KEY, book INTEGER, publisher INTEGER);
                CREATE TABLE languages (id INTEGER PRIMARY KEY, lang_code TEXT);
                CREATE TABLE books_languages_link (id INTEGER PRIMARY KEY, book INTEGER, lang_code INTEGER);
                CREATE TABLE comments (id INTEGER PRIMARY KEY, book INTEGER, text TEXT);
                CREATE TABLE identifiers (id INTEGER PRIMARY KEY, book INTEGER, type TEXT, val TEXT);
                CREATE TABLE data (id INTEGER PRIMARY KEY, book INTEGER, format TEXT, name TEXT);
                INSERT INTO books VALUES (1, 'Structural Mechanics', 'Some Author/Ref Book (1)',
                    '2024-02-01 10:00:00+00:00', '2024-02-02 11:30:00+00:00', 3.0);
                INSERT INTO authors VALUES (1, 'Jane Engineer');
                INSERT INTO books_authors_link VALUES (1, 1, 1);
                INSERT INTO series VALUES (1, 'Engineering Texts');
                INSERT INTO books_series_link VALUES (1, 1, 1);
                INSERT INTO tags VALUES (1, 'mechanics');
                INSERT INTO books_tags_link VALUES (1, 1, 1);
                INSERT INTO comments VALUES (1, 1, '<p>Beam deflection reference.</p>');
                INSERT INTO data VALUES (1, 1, 'TXT', 'Ref Book');
                ",
            )
            .expect("seed db");
        std::fs::write(
            library.join("Some Author/Ref Book (1)/Ref Book.txt"),
            "Chapter 1. Bending moment and shear force diagrams.",
        )
        .expect("write txt");
        db
    }

    #[test]
    fn extracts_catalog_fields_and_body() {
        let dir = tempfile::tempdir().expect("tempdir");
        let _db = create_library(dir.path());
        let library_root = dir.path().join("library");

        let source = crate::config::parse_sources(&format!(
            r#"[{{"id":"calibre","source_type":"calibre","app_base":"https://calibre.example.org","settings":{{"libraryRoot":"{}"}}}}]"#,
            library_root.display()
        ))
        .expect("sources")
        .remove(0);

        let extractor = CalibreExtractor { pdftotext: None };
        let mut docs = Vec::new();
        extractor
            .extract(&source, &mut |doc| docs.push(doc))
            .expect("extract");

        assert_eq!(docs.len(), 1, "expected exactly one book");
        let doc = &docs[0];
        assert_eq!(doc.external_id, "1");
        assert_eq!(doc.kind, "book");
        assert_eq!(doc.title, "Structural Mechanics");
        assert_eq!(doc.app_url, "https://calibre.example.org/book/1");
        assert_eq!(doc.content_type, "text/plain");
        assert_eq!(
            doc.content_created_at,
            parse_date("2024-02-01 10:00:00+00:00")
        );
        assert!(doc.body_text.contains("Jane Engineer"));
        assert!(doc.body_text.contains("Engineering Texts"));
        assert!(doc.body_text.contains("Beam deflection"));
        assert!(doc.body_text.contains("Bending moment"));
        assert_eq!(doc.metadata["owner"], serde_json::json!("shared"));
        assert_eq!(doc.metadata["formats"], serde_json::json!(["TXT"]));
    }
}
