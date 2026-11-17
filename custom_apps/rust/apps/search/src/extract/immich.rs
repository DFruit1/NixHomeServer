//! Photos and videos from Immich. Nothing is recognised or tagged here:
//! Immich has already worked out where and when each picture was taken, who
//! is in it, which albums hold it and what text it shows, and Search reads
//! those through a read-only database role limited to the columns below.
//!
//! A library of tens of thousands of pictures would swamp every search for a
//! town or a month, so three things keep it in its place: pictures taken on
//! one day in one place share a single result slot, photos rank below written
//! material that matches as well (see `PHOTO_SCORE_FACTOR` in `solr.rs`), and
//! text caught in a picture is only incidental text. Searching by what a
//! picture looks like is left to Immich's own image model (`visual_search`),
//! and only when the search is restricted to photos: that model returns its
//! nearest pictures for any words at all, relevant or not.
use serde_json::{json, Value};
use tokio_postgres::NoTls;

use super::ExtractedDocument;
use crate::config::SourceConfig;
use crate::federate::FederatedHit;
use crate::text::truncate_text;

/// Recognised text shorter than this is a street sign or a logo.
const OCR_MINIMUM_BYTES: usize = 40;
const OCR_LIMIT_BYTES: usize = 20_000;
const VISUAL_RESULTS: i64 = 40;

const VISIBLE: &str = r#"a."deletedAt" IS NULL AND a.status = 'active'
    AND a.visibility IN ('timeline', 'archive')"#;

pub struct ImmichExtractor;

struct Asset {
    id: String,
    video: bool,
    file_name: String,
    created: Option<i64>,
    /// "Thursday 14 March 2024", in the picture's own time zone.
    taken: Option<String>,
    day: String,
    owner: String,
    city: Option<String>,
    state: Option<String>,
    country: Option<String>,
    description: Option<String>,
}

impl Asset {
    fn place(&self) -> Option<String> {
        let parts: Vec<&str> = [&self.city, &self.state, &self.country]
            .into_iter()
            .filter_map(|part| part.as_deref())
            .map(str::trim)
            .filter(|part| !part.is_empty())
            .collect();
        (!parts.is_empty()).then(|| parts.join(", "))
    }

    /// A caption when the picture has one, otherwise where and when.
    fn title(&self) -> String {
        if let Some(description) = self.description.as_deref().map(str::trim)
            && !description.is_empty()
        {
            return truncate_text(description, 160);
        }
        let what = if self.video { "Video" } else { "Photo" };
        let date = self
            .taken
            .as_deref()
            // "Thursday 14 March 2024" without the weekday.
            .and_then(|taken| taken.split_once(' ').map(|(_, date)| date));
        match (self.city.as_deref().filter(|city| !city.is_empty()), date) {
            (Some(city), Some(date)) => format!("{what} · {city} · {date}"),
            (Some(city), None) => format!("{what} · {city}"),
            (None, Some(date)) => format!("{what} · {date}"),
            (None, None) => self.file_name.clone(),
        }
    }

    fn content_type(&self) -> String {
        let extension = self
            .file_name
            .rsplit('.')
            .next()
            .unwrap_or_default()
            .to_ascii_lowercase();
        match (self.video, extension.as_str()) {
            (false, "jpg" | "jpeg") => "image/jpeg".to_string(),
            (false, "png" | "heic" | "webp" | "gif" | "tiff") => format!("image/{extension}"),
            (false, _) => "image".to_string(),
            (true, "mp4" | "webm") => format!("video/{extension}"),
            (true, "mov") => "video/quicktime".to_string(),
            (true, _) => "video".to_string(),
        }
    }
}

/// The library's owner as Search names people. Immich files the server
/// administrator under the fixed label `admin`.
fn owner_name(source: &SourceConfig, label: Option<String>, name: Option<String>) -> String {
    let label = label
        .or(name)
        .map(|value| value.trim().to_string())
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| crate::indexer::SHARED_OWNER.to_string());
    match source.setting_str("adminOwner") {
        Some(admin) if label == "admin" => admin.to_string(),
        _ => label,
    }
}

async fn connect(source: &SourceConfig) -> Result<tokio_postgres::Client, String> {
    let url = source.require_setting("databaseUrl")?;
    let (client, connection) = tokio_postgres::connect(&url, NoTls)
        .await
        .map_err(|err| format!("failed to connect to the photo library database: {err}"))?;
    tokio::spawn(async move {
        if let Err(err) = connection.await {
            eprintln!("search: photo library database connection error: {err}");
        }
    });
    Ok(client)
}

fn names(row: &tokio_postgres::Row, column: &str) -> Vec<String> {
    row.get::<_, Option<Vec<String>>>(column)
        .unwrap_or_default()
        .into_iter()
        .map(|name| name.trim().to_string())
        .filter(|name| !name.is_empty())
        .take(64)
        .collect()
}

impl super::Extractor for ImmichExtractor {
    fn extract(
        &self,
        source: &SourceConfig,
        emit: &mut dyn FnMut(ExtractedDocument),
    ) -> Result<(), String> {
        let app_base = source.app_base.trim_end_matches('/').to_string();
        // Extraction runs on a blocking thread of the indexer's runtime.
        let rows = tokio::runtime::Handle::current().block_on(async {
            let client = connect(source).await?;
            client
                .query(
                    &format!(
                        r#"SELECT a.id::text AS id, a.type, a."originalFileName" AS file_name,
        extract(epoch from a."fileCreatedAt")::bigint AS created,
        to_char(a."localDateTime", 'FMDay FMDD FMMonth YYYY') AS taken,
        coalesce(to_char(a."localDateTime", 'YYYY-MM-DD'), '') AS day,
        u."storageLabel" AS label, u.name AS owner_name,
        e.city, e.state, e.country, e.make, e.model, e.description, a."isFavorite" AS favorite,
        (SELECT array_agg(DISTINCT al."albumName"::text) FROM album_asset aa
            JOIN album al ON al.id = aa."albumId"
            WHERE aa."assetId" = a.id AND al."deletedAt" IS NULL) AS albums,
        (SELECT array_agg(DISTINCT p.name::text) FROM asset_face f
            JOIN person p ON p."personGroupId" = f."personGroupId"
            WHERE f."assetId" = a.id AND f."deletedAt" IS NULL AND f."isVisible"
              AND NOT p."isHidden" AND p.name <> '') AS people,
        (SELECT array_agg(DISTINCT t.value::text) FROM tag_asset ta
            JOIN tag t ON t.id = ta."tagId" WHERE ta."assetId" = a.id) AS tags,
        o.text AS ocr
    FROM asset a
    JOIN "user" u ON u.id = a."ownerId"
    LEFT JOIN asset_exif e ON e."assetId" = a.id
    LEFT JOIN ocr_search o ON o."assetId" = a.id
    WHERE {VISIBLE}
    ORDER BY a.id"#
                    ),
                    &[],
                )
                .await
                .map_err(|err| format!("failed to read the photo library: {err}"))
        })?;

        for row in rows {
            let asset = Asset {
                id: row.get("id"),
                video: row.get::<_, String>("type") == "VIDEO",
                file_name: row.get("file_name"),
                created: row.get("created"),
                taken: row.get("taken"),
                day: row.get("day"),
                owner: owner_name(source, row.get("label"), row.get("owner_name")),
                city: row.get("city"),
                state: row.get("state"),
                country: row.get("country"),
                description: row.get("description"),
            };
            let albums = names(&row, "albums");
            let people = names(&row, "people");
            let tags = names(&row, "tags");
            let camera = [
                row.get::<_, Option<String>>("make"),
                row.get::<_, Option<String>>("model"),
            ]
            .into_iter()
            .flatten()
            .map(|part| part.trim().to_string())
            .filter(|part| !part.is_empty())
            .collect::<Vec<_>>()
            .join(" ");

            let mut body = Vec::new();
            if let Some(taken) = &asset.taken {
                body.push(format!(
                    "{} taken {taken}",
                    if asset.video { "Video" } else { "Photo" }
                ));
            }
            body.extend(asset.place().map(|place| format!("Place: {place}")));
            for (label, values) in [("Albums", &albums), ("People", &people), ("Tags", &tags)] {
                if !values.is_empty() {
                    body.push(format!("{label}: {}", values.join(", ")));
                }
            }
            if !camera.is_empty() {
                body.push(format!("Camera: {camera}"));
            }
            body.extend(asset.description.clone());

            let recognised = row
                .get::<_, Option<String>>("ocr")
                .map(|text| truncate_text(text.trim(), OCR_LIMIT_BYTES))
                .filter(|text| text.len() >= OCR_MINIMUM_BYTES && super::ocr::readable(text, 4))
                .unwrap_or_default();

            // Long, readable OCR is a document photographed by a camera just
            // as much as a screenshot. Keep it out of the day/place collapse.
            let text_photo = !asset.video
                && recognised.chars().count() >= 600
                && super::ocr::readable(&recognised, 40);
            if text_photo {
                body.push(recognised.clone());
            }
            let mut metadata = serde_json::Map::new();
            metadata.insert("text_photo".to_string(), json!(text_photo));
            metadata.insert(
                "favorite".to_string(),
                json!(row.get::<_, bool>("favorite")),
            );
            metadata.insert("owner".to_string(), json!(asset.owner));
            // One slot per day and place: a trip's two hundred pictures are
            // one result, shown by the best match among them.
            if !text_photo {
                metadata.insert(
                    super::SECTION_OF.to_string(),
                    json!(format!(
                        "{}|{}|{}",
                        asset.owner,
                        asset.day,
                        asset.city.as_deref().unwrap_or_default()
                    )),
                );
            }
            if let Some(place) = asset.place() {
                metadata.insert("place".to_string(), json!(place));
            }
            for (key, values) in [("albums", albums), ("people", people), ("tags", tags)] {
                if !values.is_empty() {
                    metadata.insert(key.to_string(), json!(values));
                }
            }
            if !camera.is_empty() {
                metadata.insert("camera".to_string(), json!(camera));
            }
            if !recognised.is_empty() {
                metadata.insert(
                    super::INCIDENTAL_LABEL.to_string(),
                    json!("Text in the picture"),
                );
            }
            emit(ExtractedDocument {
                incidental_text: if text_photo {
                    String::new()
                } else {
                    recognised
                },
                external_id: asset.id.clone(),
                kind: if asset.video { "video" } else { "photo" }.to_string(),
                title: asset.title(),
                body_text: body.join("\n"),
                content_type: asset.content_type(),
                origin_url: String::new(),
                app_url: format!("{app_base}/photos/{}", asset.id),
                file_path: asset.file_name.clone(),
                size_bytes: 0,
                content_created_at: asset.created,
                content_modified_at: None,
                metadata: Value::Object(metadata),
            });
        }
        Ok(())
    }
}

/// Turns words into the image model's vector, as text Postgres can cast.
async fn embed(
    http: &reqwest::Client,
    source: &SourceConfig,
    query: &str,
) -> Result<String, String> {
    let url = format!(
        "{}/predict",
        source.require_setting("embedUrl")?.trim_end_matches('/')
    );
    let model = source.require_setting("clipModel")?;
    let entries = json!({ "clip": { "textual": { "modelName": model } } }).to_string();
    // The service takes a two-field form; the fields are plain text.
    let boundary = format!("search-{}", crate::timeutil::sha256_hex(&[query]));
    let mut form = String::new();
    for (name, value) in [("entries", entries.as_str()), ("text", query)] {
        form.push_str(&format!(
            "--{boundary}\r\nContent-Disposition: form-data; name=\"{name}\"\r\n\r\n{value}\r\n"
        ));
    }
    form.push_str(&format!("--{boundary}--\r\n"));
    let response: Value = http
        .post(url)
        .header(
            reqwest::header::CONTENT_TYPE,
            format!("multipart/form-data; boundary={boundary}"),
        )
        .timeout(std::time::Duration::from_secs(15))
        .body(form)
        .send()
        .await
        .map_err(|_| "The photo library's image search is unavailable.".to_string())?
        .error_for_status()
        .map_err(|_| "The photo library's image search is unavailable.".to_string())?
        .json()
        .await
        .map_err(|_| "The photo library's image search returned an invalid answer.".to_string())?;
    let vector = match response.get("clip") {
        Some(Value::String(vector)) => vector.clone(),
        Some(Value::Array(values)) => Value::Array(values.clone()).to_string(),
        _ => return Err("The photo library's image search returned no vector.".to_string()),
    };
    // Only a list of numbers may reach the database as a vector.
    if !vector.chars().all(|c| {
        c.is_ascii_digit() || matches!(c, '[' | ']' | ',' | '.' | '-' | '+' | 'e' | 'E' | ' ')
    }) {
        return Err("The photo library's image search returned an invalid vector.".to_string());
    }
    Ok(vector)
}

/// The pictures that look most like the words, by Immich's own image model.
pub(crate) async fn visual_search(
    http: &reqwest::Client,
    source: &SourceConfig,
    query: &str,
) -> Result<Vec<FederatedHit>, String> {
    let vector = embed(http, source, query).await?;
    let client = connect(source).await?;
    // The index needs its probe count set for the session.
    client
        .batch_execute("SET vchordrq.probes = 1")
        .await
        .map_err(|err| format!("failed to prepare the image search: {err}"))?;
    let rows = client
        .query(
            &format!(
                r#"SELECT a.id::text AS id, a.type, a."originalFileName" AS file_name,
        extract(epoch from a."fileCreatedAt")::bigint AS created,
        to_char(a."localDateTime", 'FMDay FMDD FMMonth YYYY') AS taken,
        coalesce(to_char(a."localDateTime", 'YYYY-MM-DD'), '') AS day,
        u."storageLabel" AS label, u.name AS owner_name,
        e.city, e.state, e.country, e.description,
        (s.embedding <=> $1::text::vector)::float8 AS distance
    FROM smart_search s
    JOIN asset a ON a.id = s."assetId"
    JOIN "user" u ON u.id = a."ownerId"
    LEFT JOIN asset_exif e ON e."assetId" = a.id
    WHERE {VISIBLE}
    ORDER BY s.embedding <=> $1::text::vector
    LIMIT $2"#
            ),
            &[&vector, &VISUAL_RESULTS],
        )
        .await
        .map_err(|err| format!("the image search failed: {err}"))?;
    let app_base = source.app_base.trim_end_matches('/');
    Ok(rows
        .into_iter()
        .map(|row| {
            let asset = Asset {
                id: row.get("id"),
                video: row.get::<_, String>("type") == "VIDEO",
                file_name: row.get("file_name"),
                created: row.get("created"),
                taken: row.get("taken"),
                day: row.get("day"),
                owner: owner_name(source, row.get("label"), row.get("owner_name")),
                city: row.get("city"),
                state: row.get("state"),
                country: row.get("country"),
                description: row.get("description"),
            };
            let mut metadata = serde_json::Map::new();
            if let Some(place) = asset.place() {
                metadata.insert("place".to_string(), json!(place));
            }
            metadata.insert("matched".to_string(), json!("what the picture shows"));
            FederatedHit {
                source: source.id.clone(),
                kind: if asset.video { "video" } else { "photo" }.to_string(),
                remote_id: asset.id.clone(),
                title: asset.title(),
                snippet: asset.taken.clone().map(|taken| {
                    crate::text::escape_html(&match asset.place() {
                        Some(place) => format!("Taken {taken} · {place}"),
                        None => format!("Taken {taken}"),
                    })
                }),
                origin_url: String::new(),
                app_url: format!("{app_base}/photos/{}", asset.id),
                content_type: asset.content_type(),
                owner: asset.owner.clone(),
                // Nearer pictures first; the scale is the model's own.
                score: 1.0 - row.get::<_, f64>("distance"),
                created: asset.created,
                metadata: Value::Object(metadata),
            }
        })
        .collect())
}
