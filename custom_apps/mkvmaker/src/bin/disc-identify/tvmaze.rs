//! TVmaze lookups (no account needed), cached on disk for a week.

use crate::text::strip_html;
use anyhow::{bail, Context, Result};
use serde::{Deserialize, Serialize};
use serde_json::Value;
use std::{
    collections::hash_map::DefaultHasher,
    fs,
    hash::{Hash, Hasher},
    path::PathBuf,
    time::{Duration, SystemTime},
};

const CACHE_TTL: Duration = Duration::from_secs(7 * 24 * 3600);

#[derive(Clone, Debug, Deserialize, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Show {
    pub tvmaze_id: u64,
    pub name: String,
    pub year: Option<i32>,
    pub provider: Option<String>,
    pub imdb_id: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct Episode {
    pub season: u32,
    pub number: u32,
    pub name: String,
    #[serde(skip)]
    pub summary: String,
}

pub struct TvMaze {
    client: reqwest::blocking::Client,
    base: String,
    cache_dir: Option<PathBuf>,
}

impl TvMaze {
    pub fn new(base: &str, cache_dir: Option<PathBuf>, timeout: Duration) -> Result<Self> {
        let client = reqwest::blocking::Client::builder()
            .timeout(timeout)
            .user_agent("nixhomeserver-disc-identify/1 (+local DVD naming)")
            .build()?;
        Ok(Self {
            client,
            base: base.trim_end_matches('/').to_string(),
            cache_dir,
        })
    }

    fn get(&self, path_and_query: &str) -> Result<Value> {
        let cache_file = self.cache_dir.as_ref().map(|dir| {
            let mut hasher = DefaultHasher::new();
            path_and_query.hash(&mut hasher);
            dir.join(format!("tvmaze-{:016x}.json", hasher.finish()))
        });
        if let Some(file) = &cache_file {
            let fresh = fs::metadata(file)
                .and_then(|m| m.modified())
                .ok()
                .and_then(|modified| SystemTime::now().duration_since(modified).ok())
                .is_some_and(|age| age < CACHE_TTL);
            if fresh
                && let Ok(value) = fs::read(file)
                    .map_err(anyhow::Error::from)
                    .and_then(|bytes| {
                        serde_json::from_slice::<Value>(&bytes).map_err(anyhow::Error::from)
                    })
            {
                return Ok(value);
            }
        }
        let url = format!("{}{}", self.base, path_and_query);
        let response = self
            .client
            .get(&url)
            .send()
            .with_context(|| format!("GET {url}"))?;
        let status = response.status();
        if status.as_u16() == 404 {
            return Ok(Value::Null);
        }
        if !status.is_success() {
            bail!("TVmaze returned HTTP {status} for {path_and_query}");
        }
        let value: Value = response.json().context("TVmaze returned invalid JSON")?;
        if let Some(file) = &cache_file {
            if let Some(parent) = file.parent() {
                let _ = fs::create_dir_all(parent);
            }
            let temporary = file.with_extension("tmp");
            if fs::write(&temporary, serde_json::to_vec(&value)?).is_ok() {
                let _ = fs::rename(&temporary, file);
            }
        }
        Ok(value)
    }

    pub fn search(&self, query: &str) -> Result<Vec<Show>> {
        let encoded: String = form_urlencoded::byte_serialize(query.as_bytes()).collect();
        let value = self.get(&format!("/search/shows?q={encoded}"))?;
        Ok(value
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| parse_show(&item["show"]))
                    .collect()
            })
            .unwrap_or_default())
    }

    pub fn episodes(&self, id: u64) -> Result<Vec<Episode>> {
        let value = self.get(&format!("/shows/{id}/episodes"))?;
        let mut episodes: Vec<Episode> = value
            .as_array()
            .map(|items| {
                items
                    .iter()
                    .filter_map(|item| {
                        Some(Episode {
                            season: u32::try_from(item["season"].as_u64()?).ok()?,
                            number: u32::try_from(item["number"].as_u64()?).ok()?,
                            name: item["name"].as_str().unwrap_or_default().trim().to_string(),
                            summary: strip_html(item["summary"].as_str().unwrap_or_default()),
                        })
                    })
                    .collect()
            })
            .unwrap_or_default();
        episodes.sort_by_key(|episode| (episode.season, episode.number));
        Ok(episodes)
    }
}

fn parse_show(value: &Value) -> Option<Show> {
    let id = value["id"].as_u64()?;
    let year = value["premiered"]
        .as_str()
        .and_then(|date| date.get(..4))
        .and_then(|year| year.parse().ok());
    let externals = &value["externals"];
    let provider = externals["thetvdb"]
        .as_u64()
        .map(|id| format!("tvdbid-{id}"))
        .or_else(|| {
            externals["imdb"]
                .as_str()
                .filter(|id| !id.is_empty())
                .map(|id| format!("imdbid-{id}"))
        });
    Some(Show {
        tvmaze_id: id,
        name: value["name"].as_str()?.trim().to_string(),
        year,
        provider,
        imdb_id: externals["imdb"]
            .as_str()
            .filter(|id| id.starts_with("tt"))
            .map(str::to_string),
    })
}
