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
//! evidence names every title, in a single season, as consecutive episodes;
//! anything less is `uncertain` with a best guess for a person to confirm.

mod bonsai;
mod content;
mod menu;
mod replay;
mod text;
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
    /// Username of the person who uploaded the disc (for their OpenSubtitles account).
    #[arg(long)]
    owner: Option<String>,
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

#[derive(Clone, Debug, Serialize)]
#[serde(rename_all = "camelCase")]
struct Assignment {
    title: u32,
    season: u32,
    episode: u32,
    name: String,
    evidence: String,
}

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
}

impl Outcome {
    fn new(stage: &'static str) -> Self {
        Self {
            schema_version: 1,
            stage,
            status: "uncertain",
            series: None,
            season: None,
            assignments: Vec::new(),
            candidates: Vec::new(),
            summary: String::new(),
            reasons: Vec::new(),
            menu: None,
        }
    }
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
    Ok(true)
}

struct SeriesFit {
    show: Show,
    name_similarity: f64,
    era_plausible: bool,
    episodes: Vec<Episode>,
    /// Provider episodes the menu names, as (season, episode).
    menu_matches: Vec<(u32, u32)>,
}

fn menu_matches(reading: &MenuReading, episodes: &[Episode]) -> Vec<(u32, u32)> {
    let mut found: Vec<(u32, u32)> = Vec::new();
    for entry in &reading.entries {
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
            (Some((episode, score)), _) if score >= 0.85 => Some(episode),
            // The printed number agrees with a title that is only slightly off.
            (_, Some(episode)) if text::similarity(&entry.title, &episode.name) >= 0.5 => {
                Some(episode)
            }
            _ => None,
        };
        if let Some(episode) = chosen {
            let key = (episode.season, episode.number);
            if !found.contains(&key) {
                found.push(key);
            }
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

    if let Some(sidecar) = args.sidecar.as_deref().filter(|p| p.is_file()) {
        match from_sidecar(sidecar, &titles, &tv, &mut outcome) {
            Ok(true) => {
                outcome.summary = "Identified by an exact TheDiscDB disc match.".into();
                return Ok(outcome);
            }
            Ok(false) => {}
            Err(error) => outcome
                .reasons
                .push(format!("The ripper's sidecar could not be read: {error:#}")),
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
            fit.menu_matches = menu_matches(menu, &fit.episodes);
        }
    }
    outcome.candidates = fits.iter().map(|fit| fit.show.clone()).collect();
    outcome.menu = reading.clone();

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

/// Series, season, proposed assignments and candidate series from the disc stage.
type DiscContext = (Option<Show>, Option<u32>, Vec<Assignment>, Vec<Show>);

fn read_context(path: &Path) -> Result<DiscContext> {
    let value: Value = serde_json::from_slice(&fs::read(path)?)?;
    let series: Option<Show> = serde_json::from_value(value["series"].clone()).ok();
    let season = value["season"].as_u64().and_then(|s| u32::try_from(s).ok());
    let assignments = value["assignments"]
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
    Ok((series, season, assignments, candidates))
}

struct PoolEpisode {
    show: usize,
    season: u32,
    number: u32,
    name: String,
    summary: String,
}

#[derive(Clone)]
struct Pick {
    pool: usize,
    evidence: String,
}

fn run_content(args: &ContentArgs) -> Result<Outcome> {
    if args.videos.len() != args.titles.len() {
        bail!("--video and --title must be given the same number of times");
    }
    let mut outcome = Outcome::new("content");
    let (series, season, proposal, mut candidates) = read_context(&args.context)?;
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
        return Ok(outcome);
    }
    let (Some(parakeet), Some(model)) = (&args.parakeet, &args.parakeet_model) else {
        outcome.assignments = proposal;
        outcome.reasons.push(
            "Speech transcription is unavailable, so the episodes could not be compared.".into(),
        );
        outcome.summary = "Episodes need confirming.".into();
        return Ok(outcome);
    };
    let tv = tvmaze(&args.common)?;
    let model_client = bonsai(&args.common)?;

    // Candidate episodes: around the proposal when the menu gave one,
    // otherwise the known season, otherwise every episode.
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
                    && episode.season == first.season
                    && episode.number + 2 >= first.episode
                    && episode.number <= last.episode + 2
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
    if pool.is_empty() {
        outcome.assignments = proposal;
        outcome
            .reasons
            .push("TVmaze lists no candidate episodes.".into());
        outcome.summary = "Episodes need confirming.".into();
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
    let mut subtitles_usable = args.subtitle_socket.is_some() && args.owner.is_some();
    if !subtitles_usable {
        outcome
            .reasons
            .push("OpenSubtitles comparison is not configured.".into());
    }
    let mut subtitle_cache: BTreeMap<usize, Option<String>> = BTreeMap::new();
    let mut picks: Vec<Option<Pick>> = Vec::new();

    for (video, title) in args.videos.iter().zip(&args.titles) {
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
                picks.push(None);
                continue;
            }
        };
        let scores = text::keyword_scores(&transcript, &documents);
        let mut order: Vec<usize> = (0..pool.len()).collect();
        order.sort_by(|a, b| scores[*b].total_cmp(&scores[*a]));
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
                Err(error) => outcome
                    .reasons
                    .push(format!("Title {title}: Bonsai ranking failed: {error:#}")),
            }
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
            let episode = &pool[candidate];
            if subtitles_usable
                && !subtitle_cache.contains_key(&candidate)
                && let Some(imdb) = &candidates[episode.show].imdb_id
                && let Some(text) = replay.subtitle(imdb, episode.season, episode.number)
            {
                subtitle_cache.insert(candidate, text);
            }
            if !subtitle_cache.contains_key(&candidate) {
                if !subtitles_usable || downloads_left == 0 || replay.only() {
                    continue;
                }
                let Some(imdb) = candidates[episode.show].imdb_id.clone() else {
                    subtitle_cache.insert(candidate, None);
                    continue;
                };
                downloads_left -= 1;
                let result = content::episode_subtitle_text(
                    args.subtitle_socket.as_deref().unwrap_or(Path::new("")),
                    args.owner.as_deref().unwrap_or(""),
                    &imdb,
                    episode.season,
                    episode.number,
                );
                let text = match result {
                    content::SubtitleText::Text(text) => {
                        replay.record_subtitle(&imdb, episode.season, episode.number, Some(&text));
                        Some(text)
                    }
                    content::SubtitleText::NotFound => {
                        replay.record_subtitle(&imdb, episode.season, episode.number, None);
                        None
                    }
                    content::SubtitleText::NoAccount => {
                        outcome.reasons.push("The uploader has no OpenSubtitles account; subtitle comparison was skipped.".into());
                        subtitles_usable = false;
                        None
                    }
                    content::SubtitleText::Quota => {
                        outcome
                            .reasons
                            .push("The OpenSubtitles daily download limit was reached.".into());
                        subtitles_usable = false;
                        None
                    }
                    content::SubtitleText::Unavailable(error) => {
                        outcome.reasons.push(format!(
                            "OpenSubtitles comparison is unavailable: {error:#}"
                        ));
                        subtitles_usable = false;
                        None
                    }
                };
                subtitle_cache.insert(candidate, text);
            }
            if let Some(Some(reference)) = subtitle_cache.get(&candidate) {
                containment.push((candidate, text::trigram_containment(&transcript, reference)));
            }
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
            Some(Pick {
                pool: best,
                evidence: format!(
                    "dialogue matches the episode's subtitles ({:.0}% of phrases)",
                    containment[0].1 * 100.0
                ),
            })
        } else {
            match (model_pick, keyword_top) {
                (Some((chosen, confidence)), Some(top))
                    if chosen == top && confidence >= args.bonsai_min_confidence =>
                {
                    Some(Pick {
                        pool: chosen,
                        evidence: "dialogue matches the episode summary".into(),
                    })
                }
                _ => None,
            }
        };
        if pick.is_none() {
            outcome.reasons.push(format!(
                "Title {title}: the dialogue did not clearly match one episode."
            ));
        }
        // A contradicted subtitle comparison is worth reporting even without a pick.
        if let (Some(proposed), Some((best, score))) = (proposed, containment.first())
            && *best != proposed
            && *score >= args.subtitle_min_containment
        {
            outcome.reasons.push(format!(
                "Title {title}: dialogue matches {} rather than the disc-order guess.",
                episode_label(pool[*best].season, pool[*best].number, pool[*best].number)
            ));
        }
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

    // With a menu-based proposal: confirmed when at least one title's
    // dialogue confirms it and none contradicts it.
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
                "Identified as {} {}.",
                series.as_ref().map(show_label).unwrap_or_default(),
                episode_label(first.season, first.episode, last.episode)
            );
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
        return Ok(outcome);
    }
    if all_picked && !consecutive(&pairs) {
        outcome
            .reasons
            .push("The matched episodes are not consecutive in disc order.".into());
    }
    // Best guess for a person to confirm: the proposal, else whatever matched.
    outcome.assignments = if !proposal.is_empty() {
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
    Ok(outcome)
}

fn main() {
    let cli = Cli::parse();
    let result = match &cli.command {
        Command::Disc(args) => run_disc(args),
        Command::Content(args) => run_content(args),
    };
    match result {
        Ok(outcome) => {
            println!(
                "{}",
                serde_json::to_string(&outcome).expect("outcome serializes")
            );
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
