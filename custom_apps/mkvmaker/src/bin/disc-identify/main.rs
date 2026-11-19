//! Identify which TV episodes a DVD image holds.
//!
//! `disc` runs before encoding, on the ISO: an exact TheDiscDB match from the
//! ripper's sidecar, else the episode titles printed on the DVD menus (read by
//! the local Bonsai model) cross-checked against TVmaze's episode list.
//! `content` runs after encoding, on the MKVs: a local Parakeet transcript of
//! each episode compared with TVmaze summaries (ranked by Bonsai) and with the
//! uploader's OpenSubtitles subtitle text for the best candidates.
//!
//! Either stage prints one JSON object. `status` is `identified` only when the
//! evidence names every title, in a single season, as consecutive episodes,
//! and (when the uploader has a TMDB account) those episodes are still consecutive in
//! TMDB's numbering, which Jellyfin uses; identified episodes are then
//! renumbered to TMDB. Anything less is `uncertain` with a best guess for a
//! person to confirm. `episodes` prints a series' layout as Jellyfin numbers it.

mod bonsai;
mod content;
mod menu;
mod replay;
mod text;
mod tmdb;
mod tvmaze;

use anyhow::{bail, Context, Result};
use bonsai::{Bonsai, MenuReading};
use clap::{Args, Parser, Subcommand};
use serde::Serialize;
use serde_json::Value;
use std::{
    collections::BTreeMap,
    fs,
    path::{Path, PathBuf},
    time::Duration,
};
use tvmaze::{Episode, Show, TvMaze};

#[derive(Parser)]
#[command(version, about = "Identify the TV episodes on a DVD image")]
struct Cli {
    #[command(subcommand)]
    command: Command,
}

#[derive(Subcommand)]
enum Command {
    /// Identify from the disc image (sidecar, menus) before encoding.
    Disc(DiscArgs),
    /// Identify encoded titles from what they say.
    Content(ContentArgs),
    /// Print a series' episode layout as Jellyfin numbers it (TMDB, with the
    /// --owner's saved TMDB account), or TVmaze's without one. Always exits 0.
    Episodes(EpisodesArgs),
}

#[derive(Args)]
struct Common {
    #[arg(long, default_value = "https://api.tvmaze.com")]
    tvmaze_base: String,
    /// Directory for cached provider responses.
    #[arg(long)]
    cache_dir: Option<PathBuf>,
    /// OpenAI-compatible Bonsai endpoint, e.g. http://127.0.0.1:8094/v1.
    #[arg(long)]
    bonsai_url: Option<String>,
    #[arg(long, default_value = "bonsai-ternary-27b")]
    bonsai_model: String,
    #[arg(long, default_value_t = 20)]
    http_timeout_seconds: u64,
    /// Provider broker system socket (TMDB numbering, subtitles).
    #[arg(long, overrides_with = "provider_socket")]
    provider_socket: Option<PathBuf>,
    /// Username of the person who uploaded the disc; the broker uses their
    /// saved TMDB and OpenSubtitles accounts.
    #[arg(long)]
    owner: Option<String>,
    #[arg(long, default_value_t = 1200)]
    bonsai_timeout_seconds: u64,
    /// Scratch directory (created and removed by this run).
    #[arg(long)]
    work_dir: Option<PathBuf>,
}

#[derive(Args)]
struct DiscArgs {
    #[command(flatten)]
    common: Common,
    #[arg(long)]
    iso: PathBuf,
    /// Selected DVD title as INDEX:SECONDS, in episode order. Repeatable.
    #[arg(long = "title", required = true)]
    titles: Vec<String>,
    /// Readable name from the file name or volume label.
    #[arg(long, default_value = "")]
    name_hint: String,
    #[arg(long)]
    season_hint: Option<u32>,
    /// Display aspect ratio of the main titles (1.33 for 4:3, 1.78 for 16:9).
    #[arg(long)]
    display_aspect: Option<f64>,
    /// The ripper's `<name>.jellyfin.json` sidecar, if it was uploaded.
    #[arg(long)]
    sidecar: Option<PathBuf>,
    #[arg(long, default_value = "7zz")]
    sevenzip: PathBuf,
    #[arg(long, default_value = "ffmpeg")]
    ffmpeg: PathBuf,
    #[arg(long, default_value_t = 20)]
    max_menu_frames: usize,
}

#[derive(Args)]
struct ContentArgs {
    #[command(flatten)]
    common: Common,
    /// Encoded title, in disc order. Repeatable; pairs with --title.
    #[arg(long = "video", required = true)]
    videos: Vec<PathBuf>,
    /// DVD title index of each --video, in the same order.
    #[arg(long = "title", required = true)]
    titles: Vec<u32>,
    /// JSON written by the `disc` stage for this image.
    #[arg(long)]
    context: PathBuf,
    /// Provider broker system socket.
    #[arg(long)]
    subtitle_socket: Option<PathBuf>,
    #[arg(long, default_value_t = 6)]
    max_subtitle_downloads: u32,
    #[arg(long, default_value = "ffmpeg")]
    ffmpeg: PathBuf,
    #[arg(long)]
    parakeet: Option<PathBuf>,
    #[arg(long)]
    parakeet_model: Option<PathBuf>,
    #[arg(long, default_value_t = 4)]
    threads: u32,
    #[arg(long, default_value_t = 120)]
    excerpt_start: u32,
    #[arg(long, default_value_t = 360)]
    excerpt_seconds: u32,
    /// Subtitle phrase containment that names an episode (with --subtitle-margin).
    #[arg(long, default_value_t = 0.06)]
    subtitle_min_containment: f64,
    /// How many times the runner-up's containment the best one must reach.
    #[arg(long, default_value_t = 3.0)]
    subtitle_margin: f64,
    /// Containment that names an episode when it is the only one compared.
    #[arg(long, default_value_t = 0.10)]
    subtitle_single_min: f64,
    /// Bonsai confidence needed when it agrees with the keyword ranking.
    #[arg(long, default_value_t = 0.5)]
    bonsai_min_confidence: f64,
    /// Evaluation only: record transcripts, rankings and subtitle text here.
    #[arg(long)]
    replay_cache: Option<PathBuf>,
    /// Evaluation only: answer from --replay-cache without contacting sources.
    #[arg(long)]
    replay_only: bool,
}

#[derive(Args)]
struct EpisodesArgs {
    #[command(flatten)]
    common: Common,
    /// `tmdbid-N`, `tvdbid-N` or `imdbid-ttN`; empty to look up --name/--year.
    #[arg(long, default_value = "")]
    series: String,
    #[arg(long, default_value = "")]
    name: String,
    #[arg(long)]
    year: Option<i32>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Assignment {
    title: u32,
    season: u32,
    episode: u32,
    name: String,
    evidence: String,
}

/// Outcome schema. 2 added `discDiagnostics`, `contentDiagnostics` and
/// `seasonEpisodeCounts`; every schema-1 field keeps its meaning. The import
/// worker stores this object in each disc's `.identify.json` evidence, which
/// the evaluation harness reads, so fields are only ever added.
const OUTCOME_SCHEMA_VERSION: u32 = 2;

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Outcome {
    schema_version: u32,
    stage: &'static str,
    status: &'static str,
    series: Option<Show>,
    season: Option<u32>,
    /// Confirmed assignments when identified; otherwise the best guess, which
    /// may be partial or empty.
    assignments: Vec<Assignment>,
    candidates: Vec<Show>,
    summary: String,
    reasons: Vec<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    menu: Option<MenuReading>,
    /// Provider episode count per season of the chosen series (disc stage),
    /// keyed by season number; lets the worker continue a library season.
    #[serde(skip_serializing_if = "BTreeMap::is_empty")]
    season_episode_counts: BTreeMap<u32, u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    disc_diagnostics: Option<DiscDiagnostics>,
    #[serde(skip_serializing_if = "Option::is_none")]
    content_diagnostics: Option<ContentDiagnostics>,
    /// Held because the episodes could not be renumbered as TMDB (Jellyfin)
    /// numbers them. The assignments, if any, are in the identifier's own
    /// numbering and must not be offered for publishing.
    #[serde(skip_serializing_if = "std::ops::Not::not")]
    tmdb_numbering_held: bool,
}

impl Outcome {
    fn new(stage: &'static str) -> Self {
        Self {
            schema_version: OUTCOME_SCHEMA_VERSION,
            stage,
            status: "uncertain",
            series: None,
            season: None,
            assignments: Vec::new(),
            candidates: Vec::new(),
            summary: String::new(),
            reasons: Vec::new(),
            menu: None,
            season_episode_counts: BTreeMap::new(),
            disc_diagnostics: None,
            content_diagnostics: None,
            tmdb_numbering_held: false,
        }
    }
}

/// What the disc stage compared (schema 2).
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct DiscDiagnostics {
    /// The sidecar's TheDiscDB lookup status ("matched", "no_match", ...),
    /// "unreadable", or null when no sidecar was uploaded.
    sidecar: Option<String>,
    /// TVmaze searches made, in order.
    queries: Vec<String>,
    /// Candidate series, best name match first.
    series: Vec<SeriesDiagnostics>,
    /// "sidecar", "menu" or "name" (strong name match); null when no series
    /// was chosen.
    chosen_by: Option<&'static str>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SeriesDiagnostics {
    tvmaze_id: u64,
    name: String,
    year: Option<i32>,
    name_similarity: f64,
    era_plausible: bool,
    /// Provider episodes known for the series (0 when the lookup failed).
    episodes_known: usize,
    /// One row per menu entry Bonsai read.
    menu_matches: Vec<MenuMatch>,
}

/// How one menu entry compared with a series' episodes.
#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct MenuMatch {
    entry: String,
    printed_season: Option<u32>,
    printed_episode: Option<u32>,
    /// The most similar episode title, with its similarity (0..=1).
    best_title: Option<ScoredEpisode>,
    /// The episode this entry was taken to name, if any.
    matched: Option<EpisodeRef>,
    /// "title" (similarity >= 0.85) or "printed number" (number agrees and
    /// the title is at least half similar); null when unmatched.
    rule: Option<&'static str>,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EpisodeRef {
    season: u32,
    episode: u32,
    name: String,
}

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct ScoredEpisode {
    #[serde(flatten)]
    episode: EpisodeRef,
    score: f64,
}

/// What the content stage compared (schema 2).
#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct ContentDiagnostics {
    /// Where the proposal came from: "disc menu", "library order",
    /// "disc number"; null without a proposal.
    proposal_source: Option<String>,
    /// Candidate episodes compared against.
    pool_size: usize,
    subtitle_downloads: SubtitleBudget,
    titles: Vec<TitleDiagnostics>,
    decision: Decision,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct SubtitleBudget {
    limit: u32,
    /// Downloads that spent OpenSubtitles quota.
    used: u32,
    /// Subtitles the broker served from its cache (free).
    cache_hits: u32,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct TitleDiagnostics {
    title: u32,
    /// Words in the transcript excerpt; 0 when transcription failed.
    transcript_words: usize,
    transcript_error: Option<String>,
    /// Best three keyword scores against the TVmaze summaries.
    keyword_top: Vec<ScoredEpisode>,
    /// The keyword ranking preferred one episode outright.
    keyword_decisive: bool,
    bonsai_pick: Option<EpisodeRef>,
    bonsai_confidence: Option<f64>,
    bonsai_error: Option<String>,
    /// Every subtitle candidate considered, in the order checked.
    subtitles: Vec<SubtitleCheck>,
    /// The episode the proposal assigns to this title.
    proposed: Option<EpisodeRef>,
    pick: Option<EpisodeRef>,
    /// "subtitles" or "summary agreement"; null when nothing was picked.
    pick_rule: Option<&'static str>,
    /// Against the proposal: "confirmed", "contradicted" or "unconfirmed".
    verdict: Option<&'static str>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct SubtitleCheck {
    #[serde(flatten)]
    episode: EpisodeRef,
    /// Share of transcript phrases found in the subtitles; null if skipped.
    containment: Option<f64>,
    /// Served from the broker's cache (no quota spent).
    cached: bool,
    /// Why it was not compared: "budget", "no imdb id", "not found",
    /// "not cached", "no account", "quota", "unavailable".
    skipped: Option<&'static str>,
}

#[derive(Debug, Default, Serialize)]
#[serde(rename_all = "camelCase")]
struct Decision {
    /// "proposal confirmed", "all titles matched", "subtitle anchor",
    /// "summary contradiction held", "not identified" or "not compared".
    rule: &'static str,
    confirmed: usize,
    contradicted: usize,
    /// The title whose subtitle match anchored disc order ("subtitle anchor").
    anchor_title: Option<u32>,
    /// Titles whose pick contradicted the proposal on summary agreement
    /// alone, with no subtitle match behind it; such a disc is held.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    summary_only_contradictions: Vec<u32>,
}

struct Scratch(PathBuf);
impl Scratch {
    fn new(requested: Option<&Path>) -> Result<Self> {
        let path = match requested {
            Some(path) => path.to_path_buf(),
            None => std::env::temp_dir().join(format!(
                "disc-identify-{}-{}",
                std::process::id(),
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .map(|d| d.as_nanos())
                    .unwrap_or(0)
            )),
        };
        fs::create_dir_all(&path).with_context(|| format!("create {}", path.display()))?;
        Ok(Self(path))
    }
}
impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn show_label(show: &Show) -> String {
    match show.year {
        Some(year) => format!("{} ({year})", show.name),
        None => show.name.clone(),
    }
}

fn episode_label(season: u32, first: u32, last: u32) -> String {
    if first == last {
        format!("S{season:02}E{first:02}")
    } else {
        format!("S{season:02}E{first:02}-E{last:02}")
    }
}

/// Episodes form one season and consecutive numbers, in order.
fn consecutive(episodes: &[(u32, u32)]) -> bool {
    episodes
        .windows(2)
        .all(|pair| pair[0].0 == pair[1].0 && pair[1].1 == pair[0].1 + 1)
}

fn bonsai(common: &Common) -> Result<Option<Bonsai>> {
    common
        .bonsai_url
        .as_deref()
        .map(|url| {
            Bonsai::new(
                url,
                &common.bonsai_model,
                Duration::from_secs(common.bonsai_timeout_seconds),
            )
        })
        .transpose()
}

fn tvmaze(common: &Common) -> Result<TvMaze> {
    TvMaze::new(
        &common.tvmaze_base,
        common.cache_dir.clone(),
        Duration::from_secs(common.http_timeout_seconds),
    )
}

fn parse_titles(raw: &[String]) -> Result<Vec<(u32, u32)>> {
    raw.iter()
        .map(|item| {
            let (index, seconds) = item
                .split_once(':')
                .with_context(|| format!("--title {item} is not INDEX:SECONDS"))?;
            Ok((index.trim().parse()?, seconds.trim().parse()?))
        })
        .collect()
}

/// An exact TheDiscDB match recorded by the desktop ripper.
fn from_sidecar(
    path: &Path,
    titles: &[(u32, u32)],
    tv: &TvMaze,
    outcome: &mut Outcome,
) -> Result<bool> {
    let sidecar: Value = serde_json::from_slice(&fs::read(path)?)?;
    let resolution = &sidecar["resolution"];
    if let Some(diagnostics) = outcome.disc_diagnostics.as_mut() {
        diagnostics.sidecar = Some(
            resolution["lookup_status"]
                .as_str()
                .unwrap_or("not looked up")
                .to_string(),
        );
    }
    if resolution["lookup_status"] != "matched" {
        outcome.reasons.push(format!(
            "TheDiscDB has no record of this exact disc ({}).",
            resolution["lookup_status"]
                .as_str()
                .unwrap_or("not looked up")
        ));
        return Ok(false);
    }
    // (season, episode, title, DVD title index when TheDiscDB gives one)
    let mut episodes: Vec<(u32, u32, String, Option<u32>)> = resolution["episodes"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| {
            Some((
                u32::try_from(item["season"].as_u64()?).ok()?,
                u32::try_from(item["episode"].as_u64()?).ok()?,
                item["title"].as_str().unwrap_or_default().to_string(),
                item["title_index"]
                    .as_u64()
                    .and_then(|index| u32::try_from(index).ok()),
            ))
        })
        .collect();
    episodes.sort_by_key(|(s, e, _, _)| (*s, *e));
    episodes.dedup_by_key(|(s, e, _, _)| (*s, *e));
    let pairs: Vec<(u32, u32)> = episodes.iter().map(|(s, e, _, _)| (*s, *e)).collect();
    // TheDiscDB can say which DVD title holds which episode. When its title
    // numbers are the selected titles, they must also be in episode order,
    // since titles are assigned in disc order. Numbers from another scheme
    // (a different set) say nothing about the order and are ignored.
    let indexed: Option<Vec<u32>> = episodes.iter().map(|(_, _, _, index)| *index).collect();
    let selected: Vec<u32> = titles.iter().map(|(index, _)| *index).collect();
    let same_titles = |indexed: &Vec<u32>| {
        let mut left = indexed.clone();
        let mut right = selected.clone();
        left.sort_unstable();
        right.sort_unstable();
        left == right
    };
    if let Some(indexed) = &indexed
        && same_titles(indexed)
        && indexed != &selected
    {
        outcome.reasons.push(format!(
            "TheDiscDB places these episodes in DVD titles {indexed:?}, which differ from the selected titles."
        ));
        return Ok(false);
    }
    if episodes.len() != titles.len() || !consecutive(&pairs) {
        outcome.reasons.push(format!(
            "TheDiscDB maps {} episode(s) to this disc but {} titles were selected, or they are not consecutive.",
            episodes.len(),
            titles.len()
        ));
        return Ok(false);
    }
    let name = resolution["media_title"]
        .as_str()
        .unwrap_or_default()
        .to_string();
    let year = resolution["year"]
        .as_i64()
        .and_then(|y| i32::try_from(y).ok());
    let mut series = tv.search(&name)?.into_iter().find(|show| {
        text::similarity(&show.name, &name) > 0.9 && (year.is_none() || show.year == year)
    });
    if series.is_none() {
        series = Some(Show {
            tvmaze_id: 0,
            name: name.clone(),
            year,
            provider: resolution["tvdb_id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .map(|id| format!("tvdbid-{id}")),
            imdb_id: resolution["imdb_id"]
                .as_str()
                .filter(|id| !id.is_empty())
                .map(str::to_string),
            tmdb_id: None,
            provider_ids: Vec::new(),
        });
    }
    outcome.assignments = titles
        .iter()
        .zip(&episodes)
        .map(|((title, _), (season, episode, name, _))| Assignment {
            title: *title,
            season: *season,
            episode: *episode,
            name: name.clone(),
            evidence: "TheDiscDB exact disc match".into(),
        })
        .collect();
    outcome.season = Some(episodes[0].0);
    outcome.series = series;
    outcome.status = "identified";
    if let Some(diagnostics) = outcome.disc_diagnostics.as_mut() {
        diagnostics.chosen_by = Some("sidecar");
    }
    Ok(true)
}

struct SeriesFit {
    show: Show,
    name_similarity: f64,
    era_plausible: bool,
    episodes: Vec<Episode>,
    /// Provider episodes the menu names, as (season, episode).
    menu_matches: Vec<(u32, u32)>,
    menu_details: Vec<MenuMatch>,
}

fn episode_ref(episode: &Episode) -> EpisodeRef {
    EpisodeRef {
        season: episode.season,
        episode: episode.number,
        name: episode.name.clone(),
    }
}

/// How each menu entry compares with the series' episodes.
fn menu_match_details(reading: &MenuReading, episodes: &[Episode]) -> Vec<MenuMatch> {
    reading
        .entries
        .iter()
        .map(|entry| {
            let by_title = episodes
                .iter()
                .map(|episode| (episode, text::similarity(&entry.title, &episode.name)))
                .max_by(|a, b| a.1.total_cmp(&b.1));
            let numbered = match (entry.season, entry.episode) {
                (Some(season), Some(number)) => episodes
                    .iter()
                    .find(|episode| episode.season == season && episode.number == number),
                _ => None,
            };
            let chosen = match (by_title, numbered) {
                (Some((episode, score)), _) if score >= 0.85 => Some((episode, "title")),
                // The printed number agrees with a title that is only slightly off.
                (_, Some(episode)) if text::similarity(&entry.title, &episode.name) >= 0.5 => {
                    Some((episode, "printed number"))
                }
                _ => None,
            };
            MenuMatch {
                entry: entry.title.clone(),
                printed_season: entry.season,
                printed_episode: entry.episode,
                best_title: by_title.map(|(episode, score)| ScoredEpisode {
                    episode: episode_ref(episode),
                    score,
                }),
                matched: chosen.map(|(episode, _)| episode_ref(episode)),
                rule: chosen.map(|(_, rule)| rule),
            }
        })
        .collect()
}

#[cfg(test)]
fn menu_matches(reading: &MenuReading, episodes: &[Episode]) -> Vec<(u32, u32)> {
    matched_episodes(&menu_match_details(reading, episodes))
}

/// The distinct provider episodes the menu names, as (season, episode).
fn matched_episodes(details: &[MenuMatch]) -> Vec<(u32, u32)> {
    let mut found: Vec<(u32, u32)> = Vec::new();
    for matched in details.iter().filter_map(|detail| detail.matched.as_ref()) {
        let key = (matched.season, matched.episode);
        if !found.contains(&key) {
            found.push(key);
        }
    }
    found.sort();
    found
}

fn run_disc(args: &DiscArgs) -> Result<Outcome> {
    let titles = parse_titles(&args.titles)?;
    if titles.is_empty() {
        bail!("no titles");
    }
    let count = titles.len();
    let tv = tvmaze(&args.common)?;
    let mut outcome = Outcome::new("disc");
    outcome.disc_diagnostics = Some(DiscDiagnostics::default());

    if let Some(sidecar) = args.sidecar.as_deref().filter(|p| p.is_file()) {
        match from_sidecar(sidecar, &titles, &tv, &mut outcome) {
            Ok(true) => {
                outcome.summary = "Identified by an exact TheDiscDB disc match.".into();
                return Ok(outcome);
            }
            Ok(false) => {}
            Err(error) => {
                if let Some(diagnostics) = outcome.disc_diagnostics.as_mut() {
                    diagnostics.sidecar = Some("unreadable".into());
                }
                outcome
                    .reasons
                    .push(format!("The ripper's sidecar could not be read: {error:#}"))
            }
        }
    }

    // Menus.
    let mut reading: Option<MenuReading> = None;
    match bonsai(&args.common)? {
        None => outcome
            .reasons
            .push("Menu reading is unavailable (Bonsai is not configured).".into()),
        Some(model) => {
            let scratch = Scratch::new(args.common.work_dir.as_deref())?;
            let tools = menu::Tools {
                sevenzip: &args.sevenzip,
                ffmpeg: &args.ffmpeg,
            };
            match menu::menu_frames(&tools, &args.iso, &scratch.0, args.max_menu_frames) {
                Ok(frames) if frames.is_empty() => outcome
                    .reasons
                    .push("The disc has no readable menu frames.".into()),
                Ok(frames) => match model.read_menu(&frames) {
                    Ok(menu) => {
                        if menu.entries.is_empty() {
                            outcome
                                .reasons
                                .push("The disc menus do not list episode titles.".into());
                        }
                        reading = Some(menu);
                    }
                    Err(error) => outcome
                        .reasons
                        .push(format!("Bonsai could not read the menus: {error:#}")),
                },
                Err(error) => outcome
                    .reasons
                    .push(format!("The menus could not be extracted: {error:#}")),
            }
        }
    }

    // Candidate series.
    let mut queries: Vec<String> = Vec::new();
    for query in [
        reading.as_ref().and_then(|r| r.series_title.clone()),
        Some(args.name_hint.clone()),
    ]
    .into_iter()
    .flatten()
    {
        if !query.trim().is_empty()
            && !queries
                .iter()
                .any(|q| text::normalize(q) == text::normalize(&query))
        {
            queries.push(query);
        }
    }
    // Volume labels often run the words together; TVmaze cannot search those.
    if let Some(model) = bonsai(&args.common)? {
        let squashed: Vec<String> = queries
            .iter()
            .filter(|q| q.split_whitespace().any(|word| word.chars().count() >= 12))
            .cloned()
            .collect();
        for label in squashed {
            match model.split_label(&label) {
                Ok(Some(title)) => {
                    if !queries
                        .iter()
                        .any(|q| text::normalize(q) == text::normalize(&title))
                    {
                        queries.push(title);
                    }
                }
                Ok(None) => {}
                Err(error) => outcome
                    .reasons
                    .push(format!("Bonsai could not split the label: {error:#}")),
            }
        }
    }
    let mut shows: BTreeMap<u64, Show> = BTreeMap::new();
    for query in &queries {
        match tv.search(query) {
            Ok(found) => {
                for show in found.into_iter().take(6) {
                    shows.entry(show.tvmaze_id).or_insert(show);
                }
            }
            Err(error) => outcome
                .reasons
                .push(format!("TVmaze search failed: {error:#}")),
        }
    }
    if let Some(diagnostics) = outcome.disc_diagnostics.as_mut() {
        diagnostics.queries = queries.clone();
    }
    let mut fits: Vec<SeriesFit> = shows
        .into_values()
        .map(|show| {
            let name_similarity = queries
                .iter()
                .map(|q| text::similarity(q, &show.name))
                .fold(0.0, f64::max);
            let era_plausible = match (args.display_aspect, show.year) {
                // Full-frame DVDs of shows that began after 2010 are rare, as
                // are widescreen DVDs of shows that began before 1995.
                (Some(aspect), Some(year)) if aspect < 1.5 => year < 2010,
                (Some(aspect), Some(year)) if aspect > 1.6 => year >= 1995,
                _ => true,
            };
            SeriesFit {
                show,
                name_similarity,
                era_plausible,
                episodes: Vec::new(),
                menu_matches: Vec::new(),
                menu_details: Vec::new(),
            }
        })
        .filter(|fit| fit.name_similarity >= 0.55)
        .collect();
    fits.sort_by(|a, b| b.name_similarity.total_cmp(&a.name_similarity));
    fits.truncate(5);
    for fit in &mut fits {
        match tv.episodes(fit.show.tvmaze_id) {
            Ok(episodes) => fit.episodes = episodes,
            Err(error) => outcome.reasons.push(format!(
                "TVmaze episodes for {} failed: {error:#}",
                fit.show.name
            )),
        }
        if let Some(menu) = &reading {
            fit.menu_details = menu_match_details(menu, &fit.episodes);
            fit.menu_matches = matched_episodes(&fit.menu_details);
        }
    }
    outcome.candidates = fits.iter().map(|fit| fit.show.clone()).collect();
    outcome.menu = reading.clone();
    if let Some(diagnostics) = outcome.disc_diagnostics.as_mut() {
        diagnostics.series = fits
            .iter_mut()
            .map(|fit| SeriesDiagnostics {
                tvmaze_id: fit.show.tvmaze_id,
                name: fit.show.name.clone(),
                year: fit.show.year,
                name_similarity: fit.name_similarity,
                era_plausible: fit.era_plausible,
                episodes_known: fit.episodes.len(),
                menu_matches: std::mem::take(&mut fit.menu_details),
            })
            .collect();
    }

    let best_menu = fits
        .iter()
        .map(|fit| fit.menu_matches.len())
        .max()
        .unwrap_or(0);
    let chosen: Option<&SeriesFit> = if best_menu > 0 {
        let leaders: Vec<&SeriesFit> = fits
            .iter()
            .filter(|fit| fit.menu_matches.len() == best_menu)
            .collect();
        let plausible: Vec<&SeriesFit> = leaders
            .iter()
            .copied()
            .filter(|fit| fit.era_plausible)
            .collect();
        match (leaders.len(), plausible.len()) {
            (1, _) => Some(leaders[0]),
            (_, 1) => Some(plausible[0]),
            _ => {
                outcome.reasons.push(format!(
                    "The menu titles match {} different series equally well.",
                    leaders.len()
                ));
                None
            }
        }
    } else {
        let strong: Vec<&SeriesFit> = fits
            .iter()
            .filter(|fit| fit.name_similarity >= 0.9 && fit.era_plausible)
            .collect();
        match strong.len() {
            0 => {
                outcome.reasons.push(if fits.is_empty() {
                    "No TV series on TVmaze matches the disc's name.".into()
                } else {
                    "No TV series on TVmaze clearly matches the disc's name.".into()
                });
                None
            }
            1 => Some(strong[0]),
            _ => {
                outcome.reasons.push(format!(
                    "{} TV series share this name: {}.",
                    strong.len(),
                    strong
                        .iter()
                        .map(|fit| show_label(&fit.show))
                        .collect::<Vec<_>>()
                        .join(", ")
                ));
                None
            }
        }
    };

    let Some(fit) = chosen else {
        outcome.summary = "The series could not be determined from the disc.".into();
        return Ok(outcome);
    };
    outcome.series = Some(fit.show.clone());
    // Keep only the chosen series for the content stage when the menu chose it.
    if best_menu > 0 {
        outcome.candidates = vec![fit.show.clone()];
    }
    if let Some(diagnostics) = outcome.disc_diagnostics.as_mut() {
        diagnostics.chosen_by = Some(if best_menu > 0 { "menu" } else { "name" });
    }
    for episode in &fit.episodes {
        *outcome
            .season_episode_counts
            .entry(episode.season)
            .or_default() += 1;
    }
    let name_of = |season: u32, number: u32| {
        fit.episodes
            .iter()
            .find(|e| e.season == season && e.number == number)
            .map(|e| e.name.clone())
            .unwrap_or_default()
    };
    let matched = &fit.menu_matches;
    if matched.is_empty() {
        outcome.season = args.season_hint;
        outcome.reasons.push(format!(
            "The disc menus do not name any {} episode.",
            show_label(&fit.show)
        ));
        outcome.summary = format!(
            "Probably {}, but the episodes are unknown.",
            show_label(&fit.show)
        );
        return Ok(outcome);
    }
    let season = matched[0].0;
    outcome.season = Some(season);
    if matched.len() == count && consecutive(matched) {
        outcome.assignments = titles
            .iter()
            .zip(matched)
            .map(|((title, _), (s, e))| Assignment {
                title: *title,
                season: *s,
                episode: *e,
                name: name_of(*s, *e),
                evidence: "disc menu".into(),
            })
            .collect();
        outcome.status = "identified";
        outcome.summary = format!(
            "Identified from the disc menu as {} {}.",
            show_label(&fit.show),
            episode_label(season, matched[0].1, matched[count - 1].1)
        );
        return Ok(outcome);
    }
    if matched.len() < count && consecutive(matched) {
        // The menu named the first episode(s); extend in title order if the
        // season has enough episodes, and let the content stage confirm.
        let first = matched[0].1;
        let proposal: Vec<(u32, u32)> = (0..count as u32).map(|i| (season, first + i)).collect();
        if proposal.iter().all(|(s, e)| {
            fit.episodes
                .iter()
                .any(|x| x.season == *s && x.number == *e)
        }) {
            outcome.assignments = titles
                .iter()
                .zip(&proposal)
                .map(|((title, _), (s, e))| Assignment {
                    title: *title,
                    season: *s,
                    episode: *e,
                    name: name_of(*s, *e),
                    evidence: if matched.contains(&(*s, *e)) {
                        "disc menu"
                    } else {
                        "disc order"
                    }
                    .into(),
                })
                .collect();
        }
        outcome.reasons.push(format!(
            "The disc menu names {} of the {count} episodes; the rest follow disc order and need confirming.",
            matched.len()
        ));
    } else if matched.len() > count {
        outcome.reasons.push(format!(
            "The disc menu lists {} episodes but {count} titles were selected.",
            matched.len()
        ));
    } else {
        outcome
            .reasons
            .push("The episodes named on the menu are not consecutive.".into());
    }
    outcome.summary = format!("{} — episodes need confirming.", show_label(&fit.show));
    Ok(outcome)
}

/// What the content stage starts from: the disc stage's outcome, possibly
/// with a proposal the import worker added (`proposalSource`).
struct DiscContext {
    series: Option<Show>,
    season: Option<u32>,
    proposal: Vec<Assignment>,
    candidates: Vec<Show>,
    /// "disc menu", "library order" or "disc number"; None without a proposal.
    proposal_source: Option<String>,
}

/// Proposals that only follow the library or the disc number say nothing
/// about which episodes are on this disc, so they are compared against the
/// whole series: a disc from elsewhere in it then contradicts the guess.
fn weak_proposal(source: Option<&str>) -> bool {
    matches!(source, Some("library order" | "disc number"))
}

fn read_context(path: &Path) -> Result<DiscContext> {
    let value: Value = serde_json::from_slice(&fs::read(path)?)?;
    let series: Option<Show> = serde_json::from_value(value["series"].clone()).ok();
    let season = value["season"].as_u64().and_then(|s| u32::try_from(s).ok());
    let proposal: Vec<Assignment> = value["assignments"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| {
            Some(Assignment {
                title: u32::try_from(item["title"].as_u64()?).ok()?,
                season: u32::try_from(item["season"].as_u64()?).ok()?,
                episode: u32::try_from(item["episode"].as_u64()?).ok()?,
                name: item["name"].as_str().unwrap_or_default().to_string(),
                evidence: item["evidence"].as_str().unwrap_or_default().to_string(),
            })
        })
        .collect();
    let candidates = value["candidates"]
        .as_array()
        .into_iter()
        .flatten()
        .filter_map(|item| serde_json::from_value::<Show>(item.clone()).ok())
        .collect();
    let proposal_source = value["proposalSource"]
        .as_str()
        .map(str::to_string)
        .or_else(|| (!proposal.is_empty()).then(|| "disc menu".to_string()));
    Ok(DiscContext {
        series,
        season,
        proposal,
        candidates,
        proposal_source,
    })
}

struct PoolEpisode {
    show: usize,
    season: u32,
    number: u32,
    name: String,
    summary: String,
}

impl PoolEpisode {
    fn reference(&self) -> EpisodeRef {
        EpisodeRef {
            season: self.season,
            episode: self.number,
            name: self.name.clone(),
        }
    }
}

#[derive(Clone)]
struct Pick {
    pool: usize,
    evidence: String,
    /// Containment score when the subtitles decided the pick.
    subtitle_score: Option<f64>,
}

/// Without a proposal, one confident subtitle match fixes disc order: title
/// `i` is the anchor's episode shifted by its distance from the anchor. The
/// result is accepted when at least half the titles agree with that order
/// (the anchor included) and none disagrees. Returns (anchor index, pool
/// index for every title).
fn anchored_order(
    picks: &[Option<Pick>],
    pool: &[PoolEpisode],
) -> Option<(usize, Vec<usize>, usize)> {
    let (anchor, anchor_pick) = picks
        .iter()
        .enumerate()
        .filter_map(|(index, pick)| {
            pick.as_ref()
                .and_then(|p| p.subtitle_score.map(|score| (index, p, score)))
        })
        .max_by(|a, b| a.2.total_cmp(&b.2))
        .map(|(index, pick, _)| (index, pick))?;
    let base = &pool[anchor_pick.pool];
    let order: Option<Vec<usize>> = (0..picks.len())
        .map(|index| {
            let number = i64::from(base.number) + index as i64 - anchor as i64;
            let number = u32::try_from(number).ok().filter(|n| *n >= 1)?;
            pool.iter()
                .position(|e| e.show == base.show && e.season == base.season && e.number == number)
        })
        .collect();
    let order = order?;
    let mut confirmed = 0;
    for (pick, expected) in picks.iter().zip(&order) {
        match pick {
            Some(pick) if pick.pool == *expected => confirmed += 1,
            Some(_) => return None,
            None => {}
        }
    }
    (confirmed * 2 >= picks.len()).then_some((anchor, order, confirmed))
}

/// Titles (indices) whose pick contradicts the proposal on episode summaries
/// alone. Summary agreement may confirm a proposal but never overrule it:
/// Bonsai's confidence does not track correctness (All Creatures S05E01 was
/// once published as S05E02 that way). A summary pick is backed by the
/// subtitles only when it falls in the disc order of another title's subtitle
/// match that itself departs from the proposal. `planned` is each title's
/// proposed (season, episode).
fn unsupported_summary_contradictions(
    picks: &[Option<Pick>],
    planned: &[Option<(u32, u32)>],
    pool: &[PoolEpisode],
) -> Vec<usize> {
    let contradicts = |index: usize| match (&picks[index], planned.get(index).copied().flatten()) {
        (Some(pick), Some(planned)) => {
            let e = &pool[pick.pool];
            (e.season, e.number) != planned
        }
        _ => false,
    };
    let anchors: Vec<(usize, &PoolEpisode)> = picks
        .iter()
        .enumerate()
        .filter_map(|(index, pick)| {
            let pick = pick.as_ref().filter(|p| p.subtitle_score.is_some())?;
            let departs = planned.get(index).copied().flatten().is_none() || contradicts(index);
            departs.then(|| (index, &pool[pick.pool]))
        })
        .collect();
    (0..picks.len())
        .filter(|&index| {
            let Some(pick) = picks[index].as_ref().filter(|p| p.subtitle_score.is_none()) else {
                return false;
            };
            let e = &pool[pick.pool];
            let backed = anchors.iter().any(|(anchor, base)| {
                base.show == e.show
                    && base.season == e.season
                    && i64::from(e.number) - i64::from(base.number) == index as i64 - *anchor as i64
            });
            contradicts(index) && !backed
        })
        .collect()
}

fn run_content(args: &ContentArgs) -> Result<Outcome> {
    if args.videos.len() != args.titles.len() {
        bail!("--video and --title must be given the same number of times");
    }
    let mut outcome = Outcome::new("content");
    let DiscContext {
        series,
        season,
        proposal,
        mut candidates,
        proposal_source,
    } = read_context(&args.context)?;
    let weak = weak_proposal(proposal_source.as_deref());
    let mut diagnostics = ContentDiagnostics {
        proposal_source: proposal_source.clone(),
        subtitle_downloads: SubtitleBudget {
            limit: args.max_subtitle_downloads,
            ..SubtitleBudget::default()
        },
        decision: Decision {
            rule: "not compared",
            ..Decision::default()
        },
        ..ContentDiagnostics::default()
    };
    if let Some(show) = &series
        && !candidates.iter().any(|c| c.tvmaze_id == show.tvmaze_id)
    {
        candidates.insert(0, show.clone());
    }
    candidates.retain(|show| show.tvmaze_id != 0);
    candidates.truncate(3);
    outcome.candidates = candidates.clone();
    outcome.series = series.clone();
    outcome.season = season;
    if candidates.is_empty() {
        outcome.assignments = proposal;
        outcome
            .reasons
            .push("There is no TV series to compare the episodes against.".into());
        outcome.summary = "The series could not be determined.".into();
        outcome.content_diagnostics = Some(diagnostics);
        return Ok(outcome);
    }
    let (Some(parakeet), Some(model)) = (&args.parakeet, &args.parakeet_model) else {
        outcome.assignments = proposal;
        outcome.reasons.push(
            "Speech transcription is unavailable, so the episodes could not be compared.".into(),
        );
        outcome.summary = "Episodes need confirming.".into();
        outcome.content_diagnostics = Some(diagnostics);
        return Ok(outcome);
    };
    let tv = tvmaze(&args.common)?;
    let model_client = bonsai(&args.common)?;

    // Candidate episodes: around the proposal when the menu gave one, the
    // whole series for a library-order or disc-number guess, otherwise the
    // known season, otherwise every episode.
    let mut pool: Vec<PoolEpisode> = Vec::new();
    for (index, show) in candidates.iter().enumerate() {
        let episodes = match tv.episodes(show.tvmaze_id) {
            Ok(episodes) => episodes,
            Err(error) => {
                outcome.reasons.push(format!(
                    "TVmaze episodes for {} failed: {error:#}",
                    show.name
                ));
                continue;
            }
        };
        for episode in episodes {
            let keep = if let (Some(first), Some(last), Some(series)) =
                (proposal.first(), proposal.last(), &series)
            {
                show.tvmaze_id == series.tvmaze_id
                    && (weak
                        || (episode.season == first.season
                            && episode.number + 2 >= first.episode
                            && episode.number <= last.episode + 2))
            } else if let Some(season) = season {
                episode.season == season
            } else {
                true
            };
            if keep {
                pool.push(PoolEpisode {
                    show: index,
                    season: episode.season,
                    number: episode.number,
                    name: episode.name,
                    summary: episode.summary,
                });
            }
        }
    }
    diagnostics.pool_size = pool.len();
    if pool.is_empty() {
        outcome.assignments = proposal;
        outcome
            .reasons
            .push("TVmaze lists no candidate episodes.".into());
        outcome.summary = "Episodes need confirming.".into();
        outcome.content_diagnostics = Some(diagnostics);
        return Ok(outcome);
    }
    let documents: Vec<String> = pool
        .iter()
        .map(|e| format!("{} {}", e.name, e.summary))
        .collect();

    let scratch = Scratch::new(args.common.work_dir.as_deref())?;
    let replay = replay::Replay::new(args.replay_cache.as_deref(), args.replay_only)?;
    let asr = content::Asr {
        ffmpeg: &args.ffmpeg,
        parakeet,
        model,
        threads: args.threads,
    };
    let mut downloads_left = args.max_subtitle_downloads;
    // The broker's cache stays usable after the download budget or the
    // daily quota is spent; an account or broker failure stops both.
    let mut subtitles_usable = args.subtitle_socket.is_some() && args.common.owner.is_some();
    let mut downloads_allowed = subtitles_usable;
    if !subtitles_usable {
        outcome
            .reasons
            .push("OpenSubtitles comparison is not configured.".into());
    }
    let mut subtitle_cache: BTreeMap<usize, Option<String>> = BTreeMap::new();
    let mut picks: Vec<Option<Pick>> = Vec::new();

    for (video, title) in args.videos.iter().zip(&args.titles) {
        let mut detail = TitleDiagnostics {
            title: *title,
            ..TitleDiagnostics::default()
        };
        let transcript = match replay.transcript(
            video,
            model,
            args.excerpt_start,
            args.excerpt_seconds,
            || {
                content::transcribe_excerpt(
                    &asr,
                    video,
                    &scratch.0,
                    args.excerpt_start,
                    args.excerpt_seconds,
                )
            },
        ) {
            Ok(text) => text,
            Err(error) => {
                outcome
                    .reasons
                    .push(format!("Title {title}: transcription failed: {error:#}"));
                detail.transcript_error = Some(format!("{error:#}"));
                diagnostics.titles.push(detail);
                picks.push(None);
                continue;
            }
        };
        detail.transcript_words = transcript.split_whitespace().count();
        let scores = text::keyword_scores(&transcript, &documents);
        let mut order: Vec<usize> = (0..pool.len()).collect();
        order.sort_by(|a, b| scores[*b].total_cmp(&scores[*a]));
        detail.keyword_top = order
            .iter()
            .take(3)
            .map(|&i| ScoredEpisode {
                episode: pool[i].reference(),
                score: scores[i],
            })
            .collect();
        // The keyword signal only counts when it actually prefers one
        // episode; with nothing heard in common every score is zero.
        let keyword_top = order
            .first()
            .copied()
            .filter(|&top| scores[top] > 0.0)
            .filter(|&top| {
                order
                    .get(1)
                    .is_none_or(|&second| scores[top] > scores[second])
            });
        detail.keyword_decisive = keyword_top.is_some();
        // Bonsai sees the shortlist in broadcast order, not keyword order, so
        // a model that favours the first option cannot simply echo the
        // keyword ranking and pass as a second, independent signal.
        let mut shortlist: Vec<usize> = order.iter().copied().take(25).collect();
        shortlist.sort_unstable();

        let mut model_pick: Option<(usize, f64)> = None;
        if let Some(client) = &model_client {
            let listing: Vec<(String, String)> = shortlist
                .iter()
                .map(|&i| {
                    let e = &pool[i];
                    (
                        format!(
                            "{} {} \"{}\"",
                            candidates[e.show].name,
                            episode_label(e.season, e.number, e.number),
                            e.name
                        ),
                        text::clip(&e.summary, 320),
                    )
                })
                .collect();
            let excerpt = text::clip(&transcript, 6000);
            match replay.ranking(&args.common.bonsai_model, &excerpt, &listing, || {
                client.rank_synopses(&excerpt, &listing)
            }) {
                Ok(Some((index, confidence))) => model_pick = Some((shortlist[index], confidence)),
                Ok(None) => {}
                Err(error) => {
                    outcome
                        .reasons
                        .push(format!("Title {title}: Bonsai ranking failed: {error:#}"));
                    detail.bonsai_error = Some(format!("{error:#}"));
                }
            }
        }
        if let Some((chosen, confidence)) = model_pick {
            detail.bonsai_pick = Some(pool[chosen].reference());
            detail.bonsai_confidence = Some(confidence);
        }

        // Compare dialogue with the published subtitles of the best guesses.
        let proposed = proposal.iter().find(|a| a.title == *title).and_then(|a| {
            pool.iter().position(|e| {
                series
                    .as_ref()
                    .is_some_and(|s| candidates[e.show].tvmaze_id == s.tvmaze_id)
                    && e.season == a.season
                    && e.number == a.episode
            })
        });
        detail.proposed = proposed.map(|index| pool[index].reference());
        let mut to_check: Vec<usize> = Vec::new();
        for candidate in [
            model_pick.map(|p| p.0),
            keyword_top,
            proposed,
            order.get(1).copied(),
        ]
        .into_iter()
        .flatten()
        {
            if !to_check.contains(&candidate) && to_check.len() < 3 {
                to_check.push(candidate);
            }
        }
        let mut containment: Vec<(usize, f64)> = Vec::new();
        for candidate in to_check {
            let mut check = SubtitleCheck {
                episode: pool[candidate].reference(),
                containment: None,
                cached: false,
                skipped: None,
            };
            if !subtitle_cache.contains_key(&candidate) {
                let episode = &pool[candidate];
                let imdb = candidates[episode.show].imdb_id.clone();
                let skipped = if !subtitles_usable {
                    Some("unavailable")
                } else if imdb.is_none() {
                    subtitle_cache.insert(candidate, None);
                    Some("no imdb id")
                } else {
                    None
                };
                if let Some(reason) = skipped {
                    check.skipped = Some(reason);
                    detail.subtitles.push(check);
                    continue;
                }
                // Evaluation replay: a recorded text counts as a cache hit and
                // never spends a download; --replay-only never asks the broker.
                let recorded = replay.subtitle(
                    imdb.as_deref().unwrap_or(""),
                    episode.season,
                    episode.number,
                );
                if let Some(recorded) = recorded {
                    if recorded.is_some() {
                        diagnostics.subtitle_downloads.cache_hits += 1;
                        check.cached = true;
                    }
                    subtitle_cache.insert(candidate, recorded);
                } else if replay.only() {
                    check.skipped = Some("not cached");
                    detail.subtitles.push(check);
                    continue;
                } else {
                    // Past the budget (or the daily quota) only cached text is
                    // asked for; a cache hit never spends a download.
                    let cache_only = !downloads_allowed || downloads_left == 0;
                    let result = content::episode_subtitle_text(
                        args.subtitle_socket.as_deref().unwrap_or(Path::new("")),
                        args.common.owner.as_deref().unwrap_or(""),
                        imdb.as_deref().unwrap_or(""),
                        episode.season,
                        episode.number,
                        cache_only,
                    );
                    // A fresh text or an empty result may have spent a download;
                    // a cache hit, a refusal or an unreachable broker did not
                    // (and the last two stop further downloads anyway).
                    let spent = !cache_only
                        && matches!(
                            result,
                            content::SubtitleText::Text { cached: false, .. }
                                | content::SubtitleText::NotFound
                        );
                    if spent {
                        downloads_left -= 1;
                        diagnostics.subtitle_downloads.used += 1;
                    }
                    let text = match result {
                        content::SubtitleText::Text { text, cached } => {
                            if cached {
                                diagnostics.subtitle_downloads.cache_hits += 1;
                            }
                            check.cached = cached;
                            replay.record_subtitle(
                                imdb.as_deref().unwrap_or(""),
                                episode.season,
                                episode.number,
                                Some(&text),
                            );
                            Some(text)
                        }
                        content::SubtitleText::NotFound => {
                            check.skipped = Some("not found");
                            replay.record_subtitle(
                                imdb.as_deref().unwrap_or(""),
                                episode.season,
                                episode.number,
                                None,
                            );
                            None
                        }
                        content::SubtitleText::NotCached => {
                            check.skipped =
                                Some(if downloads_allowed { "budget" } else { "quota" });
                            // Not remembered: nothing was learnt about the episode.
                            detail.subtitles.push(check);
                            continue;
                        }
                        content::SubtitleText::NoAccount => {
                            outcome.reasons.push("The uploader has no OpenSubtitles account; subtitle comparison was skipped.".into());
                            subtitles_usable = false;
                            check.skipped = Some("no account");
                            detail.subtitles.push(check);
                            continue;
                        }
                        content::SubtitleText::Quota => {
                            outcome
                                .reasons
                                .push("The OpenSubtitles daily download limit was reached.".into());
                            downloads_allowed = false;
                            check.skipped = Some("quota");
                            detail.subtitles.push(check);
                            continue;
                        }
                        content::SubtitleText::Unavailable(error) => {
                            outcome.reasons.push(format!(
                                "OpenSubtitles comparison is unavailable: {error:#}"
                            ));
                            subtitles_usable = false;
                            check.skipped = Some("unavailable");
                            detail.subtitles.push(check);
                            continue;
                        }
                    };
                    subtitle_cache.insert(candidate, text);
                }
            }
            if let Some(Some(reference)) = subtitle_cache.get(&candidate) {
                let score = text::trigram_containment(&transcript, reference);
                containment.push((candidate, score));
                check.containment = Some(score);
            } else if check.skipped.is_none() {
                check.skipped = Some("not found");
            }
            detail.subtitles.push(check);
        }
        containment.sort_by(|a, b| b.1.total_cmp(&a.1));

        let subtitle_pick = match containment.as_slice() {
            [(best, score), (_, second), ..]
                if *score >= args.subtitle_min_containment
                    && *score >= args.subtitle_margin * second.max(0.005) =>
            {
                Some(*best)
            }
            [(best, score)] if *score >= args.subtitle_single_min => Some(*best),
            _ => None,
        };
        let pick = if let Some(best) = subtitle_pick {
            detail.pick_rule = Some("subtitles");
            Some(Pick {
                pool: best,
                evidence: format!(
                    "dialogue matches the episode's subtitles ({:.0}% of phrases)",
                    containment[0].1 * 100.0
                ),
                subtitle_score: Some(containment[0].1),
            })
        } else {
            match (model_pick, keyword_top) {
                (Some((chosen, confidence)), Some(top))
                    if chosen == top && confidence >= args.bonsai_min_confidence =>
                {
                    detail.pick_rule = Some("summary agreement");
                    Some(Pick {
                        pool: chosen,
                        evidence: "dialogue matches the episode summary".into(),
                        subtitle_score: None,
                    })
                }
                _ => None,
            }
        };
        detail.pick = pick.as_ref().map(|p| pool[p.pool].reference());
        if proposed.is_some() || !proposal.is_empty() {
            detail.verdict = Some(match (&pick, proposed) {
                (Some(p), Some(planned)) if p.pool == planned => "confirmed",
                (Some(_), _) => "contradicted",
                (None, _) => "unconfirmed",
            });
        }
        if pick.is_none() {
            outcome.reasons.push(format!(
                "Title {title}: the dialogue did not clearly match one episode."
            ));
        }
        // A contradicted subtitle comparison is worth reporting even without a
        // pick. Only a menu (or TheDiscDB) proposal is evidence; a weak
        // guess's contradiction is worded so the worker never treats it as one.
        if let (Some(proposed), Some((best, score))) = (proposed, containment.first())
            && *best != proposed
            && *score >= args.subtitle_min_containment
        {
            let matched = episode_label(pool[*best].season, pool[*best].number, pool[*best].number);
            let source = proposal_source.as_deref().unwrap_or("disc-order");
            outcome.reasons.push(if weak {
                format!("Title {title}: dialogue matches {matched}, not the {source} guess.")
            } else {
                format!("Title {title}: dialogue matches {matched} rather than the {source} guess.")
            });
        }
        diagnostics.titles.push(detail);
        picks.push(pick);
    }

    let assignment = |title: u32, index: usize, evidence: String| {
        let e = &pool[index];
        Assignment {
            title,
            season: e.season,
            episode: e.number,
            name: e.name.clone(),
            evidence,
        }
    };

    // With a proposal: confirmed when at least one title's dialogue
    // confirms it and none contradicts it.
    if !proposal.is_empty() && proposal.len() == args.titles.len() {
        let mut confirmed = 0;
        let mut contradicted = 0;
        for (pick, planned) in picks.iter().zip(&proposal) {
            if let Some(pick) = pick {
                let e = &pool[pick.pool];
                if e.season == planned.season && e.number == planned.episode {
                    confirmed += 1;
                } else {
                    contradicted += 1;
                }
            }
        }
        diagnostics.decision.confirmed = confirmed;
        diagnostics.decision.contradicted = contradicted;
        if confirmed > 0 && contradicted == 0 {
            outcome.assignments = proposal
                .iter()
                .zip(&picks)
                .map(|(planned, pick)| Assignment {
                    evidence: pick
                        .as_ref()
                        .map(|p| p.evidence.clone())
                        .unwrap_or_else(|| {
                            format!("{}; neighbouring episodes confirmed", planned.evidence)
                        }),
                    ..planned.clone()
                })
                .collect();
            outcome.status = "identified";
            let first = &outcome.assignments[0];
            let last = &outcome.assignments[outcome.assignments.len() - 1];
            outcome.summary = format!(
                "Identified as {} {}{}.",
                series.as_ref().map(show_label).unwrap_or_default(),
                episode_label(first.season, first.episode, last.episode),
                if weak {
                    format!(
                        " ({} confirmed by the dialogue)",
                        proposal_source.as_deref().unwrap_or_default()
                    )
                } else {
                    String::new()
                }
            );
            diagnostics.decision.rule = "proposal confirmed";
            outcome.content_diagnostics = Some(diagnostics);
            return Ok(outcome);
        }
    }

    // Summary agreement alone never overrules a proposal (of any source):
    // without subtitle evidence for the change, the disc is held with the
    // proposal as its best guess.
    if !proposal.is_empty() {
        let planned: Vec<Option<(u32, u32)>> = args
            .titles
            .iter()
            .map(|title| {
                proposal
                    .iter()
                    .find(|a| a.title == *title)
                    .map(|a| (a.season, a.episode))
            })
            .collect();
        let refused = unsupported_summary_contradictions(&picks, &planned, &pool);
        if !refused.is_empty() {
            let source = proposal_source.as_deref().unwrap_or("disc-order");
            for &index in &refused {
                let (Some(pick), Some((season, episode))) = (&picks[index], planned[index]) else {
                    continue;
                };
                let e = &pool[pick.pool];
                outcome.reasons.push(format!(
                    "Title {}: the episode summaries point to {}, but summaries alone cannot overrule the {source} proposal ({}); no subtitle match supports the change.",
                    args.titles[index],
                    episode_label(e.season, e.number, e.number),
                    episode_label(season, episode, episode),
                ));
            }
            diagnostics.decision.rule = "summary contradiction held";
            diagnostics.decision.summary_only_contradictions =
                refused.iter().map(|&index| args.titles[index]).collect();
            // A weak guess that a subtitle match already contradicts is no
            // suggestion for a person either (as in the "not identified" path).
            let subtitle_contradicts = picks.iter().zip(&planned).any(|(pick, planned)| {
                matches!((pick, planned), (Some(pick), Some((season, episode)))
                    if pick.subtitle_score.is_some()
                        && (pool[pick.pool].season, pool[pick.pool].number) != (*season, *episode))
            });
            outcome.assignments = if weak && subtitle_contradicts {
                Vec::new()
            } else {
                proposal
            };
            outcome.summary = match &series {
                Some(show) => format!("{} — episodes need confirming.", show_label(show)),
                None => "The episodes could not be confirmed.".into(),
            };
            outcome.content_diagnostics = Some(diagnostics);
            return Ok(outcome);
        }
    }

    let chosen: Vec<(u32, &Pick)> = args
        .titles
        .iter()
        .zip(&picks)
        .filter_map(|(title, pick)| pick.as_ref().map(|p| (*title, p)))
        .collect();
    let all_picked = chosen.len() == args.titles.len();
    let same_show = chosen
        .windows(2)
        .all(|w| pool[w[0].1.pool].show == pool[w[1].1.pool].show);
    let pairs: Vec<(u32, u32)> = chosen
        .iter()
        .map(|(_, p)| (pool[p.pool].season, pool[p.pool].number))
        .collect();
    if all_picked && same_show && consecutive(&pairs) {
        let show = candidates[pool[chosen[0].1.pool].show].clone();
        outcome.assignments = chosen
            .iter()
            .map(|(title, pick)| assignment(*title, pick.pool, pick.evidence.clone()))
            .collect();
        outcome.series = Some(show.clone());
        outcome.season = Some(pairs[0].0);
        outcome.status = "identified";
        outcome.summary = format!(
            "Identified from the dialogue as {} {}.",
            show_label(&show),
            episode_label(pairs[0].0, pairs[0].1, pairs[pairs.len() - 1].1)
        );
        diagnostics.decision.rule = "all titles matched";
        diagnostics.decision.confirmed = chosen.len();
        outcome.content_diagnostics = Some(diagnostics);
        return Ok(outcome);
    }
    // A weak guess that was not confirmed says nothing about the disc, so
    // the dialogue alone decides, as without a proposal.
    if (proposal.is_empty() || weak)
        && let Some((anchor, order, confirmed)) = anchored_order(&picks, &pool)
    {
        let anchor_title = args.titles[anchor];
        outcome.assignments = args
            .titles
            .iter()
            .zip(&order)
            .zip(&picks)
            .map(|((title, index), pick)| {
                let evidence = pick
                    .as_ref()
                    .map(|p| p.evidence.clone())
                    .unwrap_or_else(|| {
                        format!("disc order from title {anchor_title}'s subtitle match")
                    });
                assignment(*title, *index, evidence)
            })
            .collect();
        let base = &pool[order[0]];
        let show = candidates[base.show].clone();
        let last = &pool[order[order.len() - 1]];
        outcome.series = Some(show.clone());
        outcome.season = Some(base.season);
        outcome.status = "identified";
        outcome.summary = format!(
            "Identified from the dialogue as {} {} (disc order from title {anchor_title}).",
            show_label(&show),
            episode_label(base.season, base.number, last.number)
        );
        diagnostics.decision = Decision {
            rule: "subtitle anchor",
            confirmed,
            contradicted: 0,
            anchor_title: Some(anchor_title),
            summary_only_contradictions: Vec::new(),
        };
        outcome.content_diagnostics = Some(diagnostics);
        return Ok(outcome);
    }
    if all_picked && !consecutive(&pairs) {
        outcome
            .reasons
            .push("The matched episodes are not consecutive in disc order.".into());
    }
    diagnostics.decision.rule = "not identified";
    if proposal.is_empty() {
        diagnostics.decision.confirmed = chosen.len();
    }
    // Best guess for a person to confirm: the proposal, else whatever
    // matched; a weak guess the dialogue contradicted is no longer one.
    let guess_contradicted = weak && diagnostics.decision.contradicted > 0;
    outcome.assignments = if !proposal.is_empty() && !guess_contradicted {
        proposal
    } else {
        chosen
            .iter()
            .map(|(title, pick)| assignment(*title, pick.pool, pick.evidence.clone()))
            .collect()
    };
    outcome.summary = match &series {
        Some(show) => format!("{} — episodes need confirming.", show_label(show)),
        None => "The episodes could not be confirmed.".into(),
    };
    outcome.content_diagnostics = Some(diagnostics);
    Ok(outcome)
}

/// Why numbering stayed unchecked when the uploader has no TMDB account. The
/// import worker matches "no TMDB account saved" in it.
fn tmdb_no_account(owner: &str) -> String {
    format!(
        "Episode numbering was not checked against TMDB ({owner} has no TMDB account saved in Media Manager's Online services)."
    )
}

/// Every TMDB lookup worth trying for a series, strongest first.
fn series_refs(show: &Show) -> Vec<tmdb::SeriesRef> {
    let mut refs: Vec<tmdb::SeriesRef> = show
        .provider_ids
        .iter()
        .chain(show.provider.as_ref())
        .filter_map(|tag| tmdb::SeriesRef::parse_provider(tag))
        .chain(show.tmdb_id.map(tmdb::SeriesRef::Tmdb))
        .chain(show.imdb_id.clone().map(tmdb::SeriesRef::Imdb))
        .collect();
    refs.sort_by_key(|series| match series {
        tmdb::SeriesRef::Tmdb(_) => 0,
        tmdb::SeriesRef::Tvdb(_) => 1,
        tmdb::SeriesRef::Imdb(_) => 2,
        tmdb::SeriesRef::Name(..) => 3,
    });
    refs.dedup();
    if !show.name.trim().is_empty() {
        refs.push(tmdb::SeriesRef::Name(show.name.clone(), show.year));
    }
    refs
}

/// Hold an identification whose numbering Jellyfin may not share.
///
/// The assignments are in TVmaze (or TheDiscDB) numbering, which would name
/// the wrong episodes in a TMDB-numbered folder if a person accepted them.
/// The disc stage keeps them as the content stage's proposal (it compares
/// the same numbering); the content stage's outcome is final, so it drops
/// them. Either way the outcome is flagged so no suggestion is offered.
fn hold_for_numbering(outcome: &mut Outcome, show: &Show, reason: String) {
    outcome.status = "uncertain";
    outcome.tmdb_numbering_held = true;
    if outcome.stage == "content" {
        outcome.assignments.clear();
    }
    outcome.reasons.push(reason);
    outcome.summary = format!(
        "{} — the episode numbers Jellyfin (TMDB) uses need confirming.",
        show_label(show)
    );
}

/// Renumber an identified disc as TMDB (Jellyfin) numbers it, or hold it.
///
/// The stages identify episodes in TVmaze (or TheDiscDB) numbering, which
/// can differ from TMDB's season layout. A disc is published only when every
/// title maps to one TMDB episode by title (and air date) and the mapped
/// episodes are still consecutive in one TMDB season. Held discs keep their
/// original numbering, which the content stage compares against.
fn check_tmdb_numbering(outcome: &mut Outcome, common: &Common, socket: Option<&Path>) {
    if outcome.status != "identified" {
        return;
    }
    let Some(show) = outcome.series.clone() else {
        return;
    };
    let Some(socket) = socket else {
        outcome.reasons.push(
            "Episode numbering was not checked against TMDB (the provider broker socket is not configured)."
                .into(),
        );
        return;
    };
    let Some(owner) = common.owner.as_deref() else {
        outcome.reasons.push(
            "Episode numbering was not checked against TMDB (the disc's uploader is unknown, so no TMDB account could be used)."
                .into(),
        );
        return;
    };
    let series = match tmdb::resolve(socket, owner, &series_refs(&show)) {
        tmdb::Lookup::Found(series) => series,
        tmdb::Lookup::NoAccount => {
            outcome.reasons.push(tmdb_no_account(owner));
            return;
        }
        tmdb::Lookup::Unavailable(error) => {
            return hold_for_numbering(outcome, &show, format!("TMDB is unavailable: {error}"));
        }
        tmdb::Lookup::NotFound => {
            let reason = format!("TMDB has no series matching {}.", show_label(&show));
            return hold_for_numbering(outcome, &show, reason);
        }
        tmdb::Lookup::Ambiguous(count) => {
            let reason = format!("{count} TMDB series match {}.", show_label(&show));
            return hold_for_numbering(outcome, &show, reason);
        }
    };
    // Air dates and runtimes come from TVmaze when it lists the same episode.
    let listed: Vec<Episode> = match show.tvmaze_id {
        0 => Vec::new(),
        id => tvmaze(common)
            .and_then(|tv| tv.episodes(id))
            .unwrap_or_default(),
    };
    let source: Vec<tmdb::SourceEpisode> = outcome
        .assignments
        .iter()
        .map(|assignment| {
            let known = listed.iter().find(|episode| {
                episode.season == assignment.season
                    && episode.number == assignment.episode
                    && (assignment.name.is_empty()
                        || text::similarity(&episode.name, &assignment.name) >= 0.85)
            });
            tmdb::SourceEpisode {
                season: assignment.season,
                episode: assignment.episode,
                name: match known {
                    Some(episode) if assignment.name.is_empty() => episode.name.clone(),
                    _ => assignment.name.clone(),
                },
                airdate: known.and_then(|episode| episode.airdate.clone()),
                runtime: known.and_then(|episode| episode.runtime),
            }
        })
        .collect();
    let mapped = match tmdb::map_episodes(&source, &series.episodes) {
        Ok(mapped) => mapped,
        Err(reason) => return hold_for_numbering(outcome, &show, reason),
    };
    for (assignment, mapping) in outcome.assignments.iter_mut().zip(&mapped) {
        let target = &series.episodes[mapping.index];
        assignment.evidence = format!(
            "{}; TMDB {} \"{}\" (tmdbid-{}) matched by {} to identified {}",
            assignment.evidence,
            tmdb::code(target),
            target.name,
            series.tmdb_id,
            mapping.basis,
            episode_label(assignment.season, assignment.episode, assignment.episode),
        );
        assignment.season = target.season;
        assignment.episode = target.episode;
        if !target.name.is_empty() {
            assignment.name = target.name.clone();
        }
    }
    let provider = format!("tmdbid-{}", series.tmdb_id);
    let mut provider_ids = vec![provider.clone()];
    for tag in show
        .provider
        .iter()
        .cloned()
        .chain(series.tvdb_id.map(|id| format!("tvdbid-{id}")))
        .chain(
            series
                .imdb_id
                .clone()
                .or(show.imdb_id.clone())
                .map(|id| format!("imdbid-{id}")),
        )
    {
        if !provider_ids.contains(&tag) {
            provider_ids.push(tag);
        }
    }
    let renamed = Show {
        tvmaze_id: show.tvmaze_id,
        name: series.name.clone(),
        year: series.year.or(show.year),
        provider: Some(provider),
        imdb_id: show.imdb_id.clone().or(series.imdb_id.clone()),
        tmdb_id: Some(series.tmdb_id),
        provider_ids,
    };
    let first = &outcome.assignments[0];
    let last = &outcome.assignments[outcome.assignments.len() - 1];
    outcome.season = Some(first.season);
    outcome.summary = format!(
        "{} Jellyfin (TMDB) numbering: {} {}.",
        outcome.summary,
        show_label(&renamed),
        episode_label(first.season, first.episode, last.episode)
    );
    outcome.series = Some(renamed);
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EpisodesOutput {
    schema_version: u32,
    layout: &'static str,
    series: Option<EpisodesSeries>,
    episodes: Vec<EpisodeRow>,
    reasons: Vec<String>,
}

#[derive(Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct EpisodesSeries {
    name: String,
    year: Option<i32>,
    provider: Option<String>,
    tmdb_id: Option<u64>,
    tvmaze_id: Option<u64>,
}

#[derive(Debug, Serialize)]
struct EpisodeRow {
    season: u32,
    episode: u32,
    name: String,
    airdate: Option<String>,
    runtime: Option<u32>,
}

fn run_episodes(args: &EpisodesArgs) -> EpisodesOutput {
    let mut out = EpisodesOutput {
        schema_version: 1,
        layout: "none",
        series: None,
        episodes: Vec::new(),
        reasons: Vec::new(),
    };
    let reference = args.series.trim();
    let given = match reference {
        "" => None,
        tag => {
            let parsed = tmdb::SeriesRef::parse_provider(tag);
            if parsed.is_none() {
                out.reasons.push(format!(
                    "The series reference {tag:?} is not tmdbid-N, tvdbid-N or imdbid-ttN."
                ));
            }
            parsed
        }
    };
    let name = args.name.trim();
    let refs: Vec<tmdb::SeriesRef> = given
        .clone()
        .into_iter()
        .chain((!name.is_empty()).then(|| tmdb::SeriesRef::Name(name.to_string(), args.year)))
        .collect();
    let Some(wanted) = refs.first().map(tmdb::SeriesRef::label) else {
        out.reasons
            .push("No series reference or name was given.".into());
        return out;
    };
    let lookup = match (
        args.common.provider_socket.as_deref(),
        args.common.owner.as_deref(),
    ) {
        (Some(socket), Some(owner)) => {
            let lookup = tmdb::resolve(socket, owner, &refs);
            if matches!(lookup, tmdb::Lookup::NoAccount) {
                out.reasons.push(format!(
                    "{owner} has no TMDB account saved in Media Manager's Online services."
                ));
            }
            lookup
        }
        (None, _) => {
            out.reasons
                .push("The provider broker socket is not configured.".into());
            tmdb::Lookup::NoAccount
        }
        (Some(_), None) => {
            out.reasons
                .push("No uploader was given, so no TMDB account could be used.".into());
            tmdb::Lookup::NoAccount
        }
    };
    match lookup {
        tmdb::Lookup::Found(series) => {
            out.layout = "tmdb";
            out.series = Some(EpisodesSeries {
                name: series.name,
                year: series.year,
                provider: Some(format!("tmdbid-{}", series.tmdb_id)),
                tmdb_id: Some(series.tmdb_id),
                tvmaze_id: None,
            });
            out.episodes = series
                .episodes
                .into_iter()
                .map(|episode| EpisodeRow {
                    season: episode.season,
                    episode: episode.episode,
                    name: episode.name,
                    airdate: episode.airdate,
                    runtime: episode.runtime,
                })
                .collect();
        }
        tmdb::Lookup::NoAccount => {
            out.reasons.push(
                "TMDB was not used, so episodes use TVmaze numbering, which has no specials."
                    .into(),
            );
            episodes_from_tvmaze(args, &refs, given.as_ref(), &mut out);
        }
        tmdb::Lookup::Unavailable(error) => {
            out.reasons.push(format!("TMDB is unavailable: {error}"));
        }
        tmdb::Lookup::NotFound => {
            out.reasons
                .push(format!("TMDB has no series matching {wanted}."));
        }
        tmdb::Lookup::Ambiguous(count) => out.reasons.push(format!(
            "{count} TMDB series match {wanted}; give a provider id or year."
        )),
    }
    out
}

fn episodes_from_tvmaze(
    args: &EpisodesArgs,
    refs: &[tmdb::SeriesRef],
    given: Option<&tmdb::SeriesRef>,
    out: &mut EpisodesOutput,
) {
    let tv = match tvmaze(&args.common) {
        Ok(tv) => tv,
        Err(error) => {
            out.reasons
                .push(format!("TVmaze is unavailable: {error:#}"));
            return;
        }
    };
    let mut show: Option<Show> = None;
    for series in refs {
        let found = match series {
            tmdb::SeriesRef::Tvdb(id) => tv.lookup("thetvdb", &id.to_string()),
            tmdb::SeriesRef::Imdb(id) => tv.lookup("imdb", id),
            // TVmaze cannot look up TMDB ids; the name (if given) is next.
            tmdb::SeriesRef::Tmdb(_) => continue,
            tmdb::SeriesRef::Name(name, year) => tv.search(name).map(|shows| {
                let exact: Vec<Show> = shows
                    .into_iter()
                    .filter(|show| text::normalize(&show.name) == text::normalize(name))
                    .filter(|show| year.is_none() || show.year == *year)
                    .collect();
                if exact.len() > 1 {
                    out.reasons.push(format!(
                        "{} TVmaze series match {}.",
                        exact.len(),
                        series.label()
                    ));
                }
                (exact.len() == 1).then(|| exact[0].clone())
            }),
        };
        match found {
            Ok(Some(found)) => {
                show = Some(found);
                break;
            }
            Ok(None) => {}
            Err(error) => {
                out.reasons
                    .push(format!("TVmaze is unavailable: {error:#}"));
                return;
            }
        }
    }
    let Some(show) = show else {
        out.reasons.push(format!(
            "TVmaze has no series matching {}.",
            refs.iter()
                .map(tmdb::SeriesRef::label)
                .collect::<Vec<_>>()
                .join(" or ")
        ));
        return;
    };
    let episodes = match tv.episodes(show.tvmaze_id) {
        Ok(episodes) => episodes,
        Err(error) => {
            out.reasons
                .push(format!("TVmaze is unavailable: {error:#}"));
            return;
        }
    };
    out.layout = "tvmaze";
    out.episodes = episodes
        .into_iter()
        .filter(|episode| episode.season > 0)
        .map(|episode| EpisodeRow {
            season: episode.season,
            episode: episode.number,
            name: episode.name,
            airdate: episode.airdate,
            runtime: episode.runtime,
        })
        .collect();
    out.series = Some(EpisodesSeries {
        name: show.name,
        year: show.year,
        // The caller's own tag names its library folder.
        provider: given.map(tmdb::SeriesRef::label).or(show.provider),
        tmdb_id: match given {
            Some(tmdb::SeriesRef::Tmdb(id)) => Some(*id),
            _ => None,
        },
        tvmaze_id: Some(show.tvmaze_id),
    });
}

fn main() {
    let cli = Cli::parse();
    let result = match &cli.command {
        Command::Disc(args) => run_disc(args).map(|mut outcome| {
            check_tmdb_numbering(
                &mut outcome,
                &args.common,
                args.common.provider_socket.as_deref(),
            );
            serde_json::to_string(&outcome)
        }),
        Command::Content(args) => run_content(args).map(|mut outcome| {
            // Evaluation replay contacts no source, the broker included.
            if args.replay_only {
                outcome
                    .reasons
                    .push("Episode numbering was not checked against TMDB (replay only).".into());
                return serde_json::to_string(&outcome);
            }
            let socket = args
                .common
                .provider_socket
                .as_deref()
                .or(args.subtitle_socket.as_deref());
            check_tmdb_numbering(&mut outcome, &args.common, socket);
            serde_json::to_string(&outcome)
        }),
        Command::Episodes(args) => Ok(serde_json::to_string(&run_episodes(args))),
    };
    match result {
        Ok(printed) => {
            println!("{}", printed.expect("outcome serializes"));
        }
        Err(error) => {
            eprintln!("disc-identify: {error:#}");
            std::process::exit(2);
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn episode(season: u32, number: u32, name: &str) -> Episode {
        Episode {
            season,
            number,
            name: name.into(),
            summary: String::new(),
            airdate: None,
            runtime: None,
        }
    }

    #[test]
    fn consecutive_requires_one_season_in_order() {
        assert!(consecutive(&[(1, 5), (1, 6)]));
        assert!(!consecutive(&[(1, 5), (1, 7)]));
        assert!(!consecutive(&[(1, 13), (2, 1)]));
        assert!(consecutive(&[(2, 3)]));
    }

    #[test]
    fn menu_titles_and_printed_numbers_map_to_provider_episodes() {
        let episodes = vec![
            episode(1, 5, "Out of Practice"),
            episode(1, 6, "Nothing Like Experience"),
            episode(1, 7, "Golden Lads and Girls"),
        ];
        let reading = MenuReading {
            series_title: None,
            disc_number: None,
            entries: vec![
                bonsai::MenuEntry {
                    season: Some(1),
                    episode: Some(5),
                    title: "Out Of Practice".into(),
                },
                // Misread title, but the printed number agrees.
                bonsai::MenuEntry {
                    season: Some(1),
                    episode: Some(6),
                    title: "Nothing Like Experiance".into(),
                },
                // Chapter names never match an episode.
                bonsai::MenuEntry {
                    season: None,
                    episode: None,
                    title: "End Credits".into(),
                },
            ],
            frames_read: 2,
        };
        assert_eq!(menu_matches(&reading, &episodes), vec![(1, 5), (1, 6)]);
    }

    fn pool_of(season: u32, numbers: std::ops::RangeInclusive<u32>) -> Vec<PoolEpisode> {
        numbers
            .map(|number| PoolEpisode {
                show: 0,
                season,
                number,
                name: format!("E{number}"),
                summary: String::new(),
            })
            .collect()
    }

    fn subtitle(pool: &[PoolEpisode], number: u32, score: f64) -> Option<Pick> {
        Some(Pick {
            pool: pool.iter().position(|e| e.number == number).unwrap(),
            evidence: "subtitles".into(),
            subtitle_score: Some(score),
        })
    }

    fn summary(pool: &[PoolEpisode], number: u32) -> Option<Pick> {
        Some(Pick {
            pool: pool.iter().position(|e| e.number == number).unwrap(),
            evidence: "summary".into(),
            subtitle_score: None,
        })
    }

    #[test]
    fn one_subtitle_match_anchors_a_two_title_disc() {
        // All Creatures S01E05-E06: title 3 unclear, title 4 matched E06.
        let pool = pool_of(1, 1..=13);
        let picks = vec![None, subtitle(&pool, 6, 0.21)];
        let (anchor, order, confirmed) = anchored_order(&picks, &pool).unwrap();
        assert_eq!((anchor, confirmed), (1, 1));
        let numbers: Vec<u32> = order.iter().map(|&i| pool[i].number).collect();
        assert_eq!(numbers, vec![5, 6]);
    }

    #[test]
    fn an_anchor_needs_half_the_titles_and_no_contradiction() {
        let pool = pool_of(1, 1..=13);
        // One of three titles is too few.
        assert!(anchored_order(&[None, subtitle(&pool, 6, 0.3), None], &pool).is_none());
        // A summary pick that agrees with the order counts towards half.
        let agreeing = [summary(&pool, 5), subtitle(&pool, 6, 0.3), None];
        assert_eq!(anchored_order(&agreeing, &pool).unwrap().2, 2);
        // Out-of-order dialogue contradicts the anchor and holds the disc.
        let contradicting = [summary(&pool, 9), subtitle(&pool, 6, 0.3), None];
        assert!(anchored_order(&contradicting, &pool).is_none());
        // Summary picks alone never anchor.
        assert!(anchored_order(&[summary(&pool, 5), summary(&pool, 6)], &pool).is_none());
        // The order must stay inside the season.
        assert!(anchored_order(&[None, subtitle(&pool, 13, 0.3)], &pool).is_some());
        assert!(anchored_order(&[subtitle(&pool, 13, 0.3), None], &pool).is_none());
        assert!(anchored_order(&[None, subtitle(&pool, 1, 0.3)], &pool).is_none());
    }

    #[test]
    fn a_numbering_hold_offers_no_tvmaze_numbered_guess() {
        let show = Show {
            tvmaze_id: 1,
            name: "Sherlock Holmes".into(),
            year: Some(1984),
            provider: Some("tvdbid-79588".into()),
            imdb_id: None,
            tmdb_id: None,
            provider_ids: Vec::new(),
        };
        let guess = Assignment {
            title: 1,
            season: 4,
            episode: 1,
            name: "The Sign of Four".into(),
            evidence: "dialogue".into(),
        };
        for (stage, kept) in [("disc", 1), ("content", 0)] {
            let mut outcome = Outcome::new(stage);
            outcome.status = "identified";
            outcome.assignments = vec![guess.clone()];
            hold_for_numbering(&mut outcome, &show, "TMDB is unavailable: x".into());
            assert_eq!(outcome.status, "uncertain");
            // The disc stage's numbering is the content stage's proposal.
            assert_eq!(outcome.assignments.len(), kept, "{stage}");
            let printed = serde_json::to_value(&outcome).unwrap();
            assert_eq!(printed["tmdbNumberingHeld"], true);
        }
        let printed = serde_json::to_value(Outcome::new("disc")).unwrap();
        assert!(printed.get("tmdbNumberingHeld").is_none());
    }

    #[test]
    fn summary_agreement_never_overrules_a_proposal() {
        // All Creatures S05E01: a correct menu proposal, but Bonsai and the
        // keyword ranking agreed on S05E02. That was once published.
        let pool = pool_of(5, 1..=10);
        let planned = [Some((5, 1))];
        assert_eq!(
            unsupported_summary_contradictions(&[summary(&pool, 2)], &planned, &pool),
            vec![0]
        );
        // Summaries may still confirm the proposal.
        assert!(
            unsupported_summary_contradictions(&[summary(&pool, 1)], &planned, &pool).is_empty()
        );
        // A subtitle match keeps its power to overrule.
        assert!(
            unsupported_summary_contradictions(&[subtitle(&pool, 2, 0.4)], &planned, &pool)
                .is_empty()
        );
        let planned = [Some((5, 1)), Some((5, 2))];
        // A summary pick in the disc order of a contradicting subtitle match
        // is backed by it.
        let shifted = [subtitle(&pool, 3, 0.4), summary(&pool, 4)];
        assert!(unsupported_summary_contradictions(&shifted, &planned, &pool).is_empty());
        // One that only disagrees with a confirming subtitle match is not.
        let against = [subtitle(&pool, 1, 0.4), summary(&pool, 5)];
        assert_eq!(
            unsupported_summary_contradictions(&against, &planned, &pool),
            vec![1]
        );
        // Without a proposal summaries decide as before.
        assert!(
            unsupported_summary_contradictions(&[summary(&pool, 2)], &[None], &pool).is_empty()
        );
    }

    #[test]
    fn library_and_disc_number_proposals_are_weak() {
        assert!(weak_proposal(Some("library order")));
        assert!(weak_proposal(Some("disc number")));
        assert!(!weak_proposal(Some("disc menu")));
        assert!(!weak_proposal(None));
    }

    #[test]
    fn menu_details_record_how_each_entry_matched() {
        let episodes = vec![
            episode(1, 5, "Out of Practice"),
            episode(1, 6, "Nothing Like Experience"),
        ];
        let reading = MenuReading {
            entries: vec![
                bonsai::MenuEntry {
                    season: Some(1),
                    episode: Some(6),
                    title: "Nothing Like Experiance".into(),
                },
                bonsai::MenuEntry {
                    season: None,
                    episode: None,
                    title: "Scene Selection".into(),
                },
            ],
            ..MenuReading::default()
        };
        let details = menu_match_details(&reading, &episodes);
        assert_eq!(details[0].rule, Some("title"));
        assert_eq!(details[0].matched.as_ref().map(|m| m.episode), Some(6));
        assert!(details[1].matched.is_none() && details[1].best_title.is_some());
        let json = serde_json::to_value(&details[0]).unwrap();
        assert_eq!(json["bestTitle"]["episode"], 6);
        assert!(json["bestTitle"]["score"].as_f64().unwrap() > 0.85);
    }

    #[test]
    fn a_wrong_printed_number_alone_does_not_match() {
        let episodes = vec![episode(1, 1, "Horse Sense"), episode(1, 2, "Dog Days")];
        let reading = MenuReading {
            entries: vec![bonsai::MenuEntry {
                season: Some(1),
                episode: Some(2),
                title: "Golden Lads and Girls".into(),
            }],
            ..MenuReading::default()
        };
        assert!(menu_matches(&reading, &episodes).is_empty());
    }
}
