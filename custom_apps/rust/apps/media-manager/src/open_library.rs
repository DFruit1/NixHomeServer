use serde::{Deserialize, Serialize};
use std::{
    sync::Arc,
    time::{Duration, Instant},
};
use tokio::{sync::Mutex, time::sleep};

pub(crate) const SEARCH_FIELDS: &str = "key,title,author_name,first_publish_year,edition_count,cover_i,publisher,isbn,language,subject,editions,editions.key,editions.title,editions.publish_date,editions.publisher,editions.isbn,editions.language,editions.number_of_pages,editions.cover_i";

#[derive(Clone)]
pub(crate) struct RequestGate {
    last_request: Arc<Mutex<Instant>>,
}

impl Default for RequestGate {
    fn default() -> Self {
        Self {
            last_request: Arc::new(Mutex::new(Instant::now() - Duration::from_secs(1))),
        }
    }
}

impl RequestGate {
    pub(crate) async fn wait(&self) {
        let mut last_request = self.last_request.lock().await;
        let gap = Duration::from_secs(1);
        let elapsed = last_request.elapsed();
        if elapsed < gap {
            sleep(gap - elapsed).await;
        }
        *last_request = Instant::now();
    }
}

#[derive(Debug, Deserialize)]
pub(crate) struct SearchResponse {
    #[serde(default)]
    docs: Vec<SearchDocument>,
}

#[derive(Debug, Deserialize)]
pub(crate) struct EditionsResponse {
    #[serde(default)]
    size: u64,
    #[serde(default)]
    entries: Vec<EditionRecord>,
}

#[derive(Debug, Deserialize)]
struct EditionRecord {
    key: Option<String>,
    title: Option<String>,
    #[serde(default)]
    publish_date: OneOrMany,
    #[serde(default)]
    publishers: Vec<String>,
    #[serde(default)]
    isbn_10: Vec<String>,
    #[serde(default)]
    isbn_13: Vec<String>,
    #[serde(default)]
    languages: Vec<KeyReference>,
    number_of_pages: Option<u64>,
    #[serde(default)]
    covers: Vec<i64>,
}

#[derive(Debug, Deserialize)]
struct KeyReference {
    key: String,
}

#[derive(Debug, Deserialize)]
struct SearchDocument {
    key: Option<String>,
    title: Option<String>,
    #[serde(default)]
    author_name: Vec<String>,
    first_publish_year: Option<u64>,
    edition_count: Option<u64>,
    cover_i: Option<u64>,
    #[serde(default)]
    publisher: Vec<String>,
    #[serde(default)]
    isbn: Vec<String>,
    #[serde(default)]
    language: Vec<String>,
    #[serde(default)]
    subject: Vec<String>,
    #[serde(default)]
    editions: EditionSearch,
}

#[derive(Debug, Default, Deserialize)]
struct EditionSearch {
    #[serde(default)]
    docs: Vec<EditionDocument>,
}

#[derive(Debug, Deserialize)]
struct EditionDocument {
    key: Option<String>,
    title: Option<String>,
    #[serde(default)]
    publish_date: OneOrMany,
    #[serde(default)]
    publisher: Vec<String>,
    #[serde(default)]
    isbn: Vec<String>,
    #[serde(default)]
    language: Vec<String>,
    number_of_pages: Option<u64>,
    cover_i: Option<u64>,
}

#[derive(Debug, Default, Deserialize)]
#[serde(untagged)]
enum OneOrMany {
    One(String),
    Many(Vec<String>),
    #[default]
    Missing,
}

impl OneOrMany {
    fn first(&self) -> Option<&str> {
        match self {
            Self::One(value) => Some(value),
            Self::Many(values) => values.first().map(String::as_str),
            Self::Missing => None,
        }
    }
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct SearchResult {
    work_id: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    edition_id: Option<String>,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    edition_title: Option<String>,
    authors: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    first_publish_year: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    edition_count: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    publish_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    publish_year: Option<u16>,
    publishers: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    isbn_10: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    isbn_13: Option<String>,
    languages: Vec<String>,
    subjects: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    number_of_pages: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cover_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cover_url: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct EditionResult {
    edition_id: String,
    title: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    publish_date: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    publish_year: Option<u16>,
    publishers: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    isbn_10: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    isbn_13: Option<String>,
    languages: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    number_of_pages: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cover_id: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    cover_url: Option<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
pub(crate) struct NormalizedEditions {
    offset: u32,
    limit: u8,
    total: u32,
    has_more: bool,
    results: Vec<EditionResult>,
}

pub(crate) fn normalized_query(query: &str) -> String {
    normalized_isbn(query)
        .map(|isbn| format!("isbn:{isbn}"))
        .unwrap_or_else(|| query.to_string())
}

pub(crate) fn normalize_response(response: SearchResponse) -> Vec<SearchResult> {
    response
        .docs
        .into_iter()
        .take(12)
        .filter_map(normalize_document)
        .collect()
}

pub(crate) fn normalized_work_id(value: &str) -> Option<String> {
    normalized_olid(value, 'W')
}

pub(crate) fn normalize_editions(
    response: EditionsResponse,
    offset: u32,
    limit: u8,
) -> NormalizedEditions {
    let returned = response.entries.len();
    let total = u32::try_from(response.size).unwrap_or(u32::MAX);
    let results = response
        .entries
        .into_iter()
        .take(usize::from(limit))
        .filter_map(normalize_edition)
        .collect();
    NormalizedEditions {
        offset,
        limit,
        total,
        has_more: u64::from(offset).saturating_add(returned as u64) < response.size,
        results,
    }
}

fn normalize_edition(edition: EditionRecord) -> Option<EditionResult> {
    let edition_id = normalized_olid(edition.key.as_deref()?, 'M')?;
    let title = safe_text(edition.title.as_deref()?, 500)?;
    let publish_date = edition
        .publish_date
        .first()
        .and_then(|value| safe_text(value, 100));
    let mut isbns = edition.isbn_13;
    isbns.extend(edition.isbn_10);
    let isbn_10 = isbns
        .iter()
        .filter_map(|value| normalized_isbn(value))
        .find(|value| value.len() == 10);
    let isbn_13 = isbns
        .iter()
        .filter_map(|value| normalized_isbn(value))
        .find(|value| value.len() == 13);
    let cover_id = edition
        .covers
        .into_iter()
        .find_map(|cover| u64::try_from(cover).ok().filter(|cover| *cover > 0));
    Some(EditionResult {
        edition_id,
        title,
        publish_year: publish_date.as_deref().and_then(year_in_date),
        publish_date,
        publishers: safe_texts(edition.publishers, 8, 250),
        isbn_10,
        isbn_13,
        languages: safe_languages(
            edition
                .languages
                .into_iter()
                .filter_map(|language| language.key.rsplit('/').next().map(str::to_string))
                .collect(),
        ),
        number_of_pages: edition
            .number_of_pages
            .and_then(|pages| u32::try_from(pages).ok())
            .filter(|pages| (1..=100_000).contains(pages)),
        cover_id,
        cover_url: cover_id.map(|id| format!("https://covers.openlibrary.org/b/id/{id}-M.jpg")),
    })
}

fn normalize_document(document: SearchDocument) -> Option<SearchResult> {
    let work_id = normalized_olid(document.key.as_deref()?, 'W')?;
    let title = safe_text(document.title.as_deref()?, 500)?;
    let edition = document.editions.docs.into_iter().next();
    let edition_id = edition
        .as_ref()
        .and_then(|value| value.key.as_deref())
        .and_then(|value| normalized_olid(value, 'M'));
    let edition_title = edition
        .as_ref()
        .and_then(|value| value.title.as_deref())
        .and_then(|value| safe_text(value, 500))
        .filter(|value| value != &title);
    let authors = safe_texts(document.author_name, 12, 250);
    let publishers = edition
        .as_ref()
        .map(|value| safe_texts(value.publisher.clone(), 8, 250))
        .filter(|values| !values.is_empty())
        .unwrap_or_else(|| safe_texts(document.publisher, 8, 250));
    let languages = edition
        .as_ref()
        .map(|value| safe_languages(value.language.clone()))
        .filter(|values| !values.is_empty())
        .unwrap_or_else(|| safe_languages(document.language));
    let mut isbns = edition
        .as_ref()
        .map(|value| value.isbn.clone())
        .unwrap_or_default();
    isbns.extend(document.isbn);
    let isbn_10 = isbns
        .iter()
        .filter_map(|value| normalized_isbn(value))
        .find(|value| value.len() == 10);
    let isbn_13 = isbns
        .iter()
        .filter_map(|value| normalized_isbn(value))
        .find(|value| value.len() == 13);
    let cover_id = edition
        .as_ref()
        .and_then(|value| value.cover_i)
        .or(document.cover_i)
        .filter(|value| *value > 0);
    let publish_date = edition
        .as_ref()
        .and_then(|value| value.publish_date.first())
        .and_then(|value| safe_text(value, 100));
    let first_publish_year = document
        .first_publish_year
        .and_then(|year| u16::try_from(year).ok())
        .filter(|year| (1000..=2100).contains(year));
    let publish_year = publish_date
        .as_deref()
        .and_then(year_in_date)
        .or(first_publish_year);

    Some(SearchResult {
        work_id,
        edition_id,
        title,
        edition_title,
        authors,
        first_publish_year,
        edition_count: document
            .edition_count
            .and_then(|count| u32::try_from(count).ok())
            .filter(|count| *count > 0),
        publish_date,
        publish_year,
        publishers,
        isbn_10,
        isbn_13,
        languages,
        subjects: safe_texts(document.subject, 16, 250),
        number_of_pages: edition
            .as_ref()
            .and_then(|value| value.number_of_pages)
            .and_then(|pages| u32::try_from(pages).ok())
            .filter(|pages| (1..=100_000).contains(pages)),
        cover_id,
        cover_url: cover_id.map(|id| format!("https://covers.openlibrary.org/b/id/{id}-M.jpg")),
    })
}

fn year_in_date(value: &str) -> Option<u16> {
    value
        .split(|character: char| !character.is_ascii_digit())
        .filter(|part| part.len() == 4)
        .filter_map(|part| part.parse::<u16>().ok())
        .find(|year| (1000..=2100).contains(year))
}

fn normalized_olid(value: &str, suffix: char) -> Option<String> {
    let value = value.rsplit('/').next()?;
    let digits = value.strip_prefix("OL")?.strip_suffix(suffix)?;
    if digits.is_empty() || digits.len() > 16 || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    Some(value.to_string())
}

pub(crate) fn normalized_isbn(value: &str) -> Option<String> {
    let compact = value
        .chars()
        .filter(|character| !matches!(character, '-' | ' '))
        .map(|character| character.to_ascii_uppercase())
        .collect::<String>();
    match compact.len() {
        10 if valid_isbn_10(&compact) => Some(compact),
        13 if valid_isbn_13(&compact) => Some(compact),
        _ => None,
    }
}

fn valid_isbn_10(value: &str) -> bool {
    value
        .chars()
        .enumerate()
        .all(|(index, character)| character.is_ascii_digit() || (index == 9 && character == 'X'))
        && value
            .chars()
            .enumerate()
            .map(|(index, character)| {
                let digit = if character == 'X' {
                    10
                } else {
                    character.to_digit(10).unwrap_or_default()
                };
                (10 - index as u32) * digit
            })
            .sum::<u32>()
            % 11
            == 0
}

fn valid_isbn_13(value: &str) -> bool {
    value.bytes().all(|byte| byte.is_ascii_digit())
        && value
            .bytes()
            .enumerate()
            .map(|(index, byte)| {
                let weight = if index % 2 == 0 { 1 } else { 3 };
                u32::from(byte - b'0') * weight
            })
            .sum::<u32>()
            % 10
            == 0
}

fn safe_text(value: &str, maximum_chars: usize) -> Option<String> {
    let normalized = value.split_whitespace().collect::<Vec<_>>().join(" ");
    if normalized.is_empty() || normalized.chars().count() > maximum_chars {
        None
    } else {
        Some(normalized)
    }
}

fn safe_texts(values: Vec<String>, maximum_values: usize, maximum_chars: usize) -> Vec<String> {
    let mut normalized = Vec::new();
    for value in values {
        let Some(value) = safe_text(&value, maximum_chars) else {
            continue;
        };
        if !normalized.contains(&value) {
            normalized.push(value);
        }
        if normalized.len() == maximum_values {
            break;
        }
    }
    normalized
}

fn safe_languages(values: Vec<String>) -> Vec<String> {
    safe_texts(values, 12, 16)
        .into_iter()
        .filter(|value| {
            value
                .bytes()
                .all(|byte| byte.is_ascii_alphabetic() || byte == b'-')
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn isbn_queries_are_exact_only_when_the_checksum_is_valid() {
        assert_eq!(normalized_query("978-0-441-17271-9"), "isbn:9780441172719");
        assert_eq!(normalized_query("0441172717"), "isbn:0441172717");
        assert_eq!(normalized_query("978-0-441-17271-8"), "978-0-441-17271-8");
        assert_eq!(normalized_query("Dune Frank Herbert"), "Dune Frank Herbert");
    }

    #[test]
    fn malformed_documents_are_skipped_and_contributor_order_is_preserved() {
        let payload = serde_json::from_value::<SearchResponse>(serde_json::json!({
            "docs": [
                { "title": "Missing a work key" },
                {
                    "key": "/works/OL1W",
                    "title": "Example",
                    "author_name": ["Second Author", "First Author", "Second Author"],
                    "subject": ["Beta", "Alpha", "Beta"]
                }
            ]
        }))
        .expect("search response");

        let results = normalize_response(payload);
        assert_eq!(results.len(), 1);
        assert_eq!(
            results[0].authors,
            vec!["Second Author".to_string(), "First Author".to_string()]
        );
        assert_eq!(
            results[0].subjects,
            vec!["Beta".to_string(), "Alpha".to_string()]
        );
    }

    #[test]
    fn editions_are_bounded_normalized_and_keep_their_cover_identifier() {
        let payload = serde_json::from_value::<EditionsResponse>(serde_json::json!({
            "size": 2,
            "entries": [
                {
                    "key": "/books/OL75313M",
                    "title": "Dune",
                    "publish_date": "September 1990",
                    "publishers": ["Ace Books"],
                    "isbn_10": ["0441172717"],
                    "isbn_13": ["9780441172719"],
                    "languages": [{"key": "/languages/eng"}],
                    "number_of_pages": 535,
                    "covers": [8231856]
                },
                {
                    "key": "/books/not-an-olid",
                    "title": "Malformed"
                }
            ]
        }))
        .expect("editions response");

        let normalized = normalize_editions(payload, 0, 20);
        assert_eq!(normalized.total, 2);
        assert_eq!(normalized.results.len(), 1);
        assert_eq!(normalized.results[0].edition_id, "OL75313M");
        assert_eq!(normalized.results[0].publish_year, Some(1990));
        assert_eq!(normalized.results[0].languages, vec!["eng"]);
        assert_eq!(normalized.results[0].cover_id, Some(8231856));
        assert!(!normalized.has_more);
    }
}
