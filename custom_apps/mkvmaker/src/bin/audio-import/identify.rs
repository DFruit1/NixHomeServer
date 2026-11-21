//! Settle what the ripper's own evidence could not, and enrich what it could.
//!
//! Two independent sources must agree before a book is named without a
//! person: what the discs say about themselves (the spoken opening and
//! closing announcements read by Bonsai from a Parakeet transcript, or a
//! MusicBrainz CD stub) and an Audible catalogue edition of that title and
//! author whose runtime matches the discs. The runtime match also shows
//! that the set is complete, which settles a book whose number of discs
//! nobody recorded.
//!
//! A book that is already certain is only enriched: its author and title
//! stay as they are, and a matching edition adds narrator, series,
//! description and cover. Nothing Bonsai or the transcript says is used
//! unless the catalogue confirms it.

use crate::{
    bonsai::Bonsai,
    book::{HoldKind, Proposal, Series},
    build::{media_seconds, Tools},
    content::{post_unix, transcribe_excerpt, Asr},
    disc::{extract_member, Disc, DiscKind},
    fsops::natural_key,
    text::{clip, normalize, similarity, words},
};
use base64::Engine;
use serde::{Deserialize, Serialize};
use serde_json::{json, Value};
use sha2::{Digest, Sha256};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::{Path, PathBuf},
};

/// Seconds of the book's start and end that are transcribed.
const OPENING_SECONDS: f64 = 240.0;
const CLOSING_SECONDS: f64 = 120.0;
const SEARCH_ROUTE: &str = "/system/v1/audible/search";
const COVER_ROUTE: &str = "/system/v1/audible/cover";

pub struct Identifier {
    pub bonsai: Option<Bonsai>,
    /// `parakeet-cli` and its model.
    pub parakeet: Option<(PathBuf, PathBuf)>,
    pub threads: u32,
    /// The provider broker's system socket.
    pub socket: Option<PathBuf>,
}

/// One disc of the set being identified.
pub struct Source<'a> {
    pub path: &'a Path,
    pub disc: &'a Disc,
    pub sha256: &'a str,
}

/// Transcripts and Bonsai readings kept in the importer's state, so a retry
/// repeats neither speech recognition nor a Bonsai request.
#[derive(Default, Serialize, Deserialize)]
pub struct Cache {
    #[serde(default)]
    pub transcripts: BTreeMap<String, String>,
    #[serde(default)]
    pub credits: BTreeMap<String, Credits>,
}

/// What the announcements say, as Bonsai read them.
#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Credits {
    pub title: String,
    pub author: String,
    pub narrator: String,
    pub publisher: String,
    pub abridged: Option<bool>,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct EditionSeries {
    title: String,
    sequence: String,
}

#[derive(Clone, Debug, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct Edition {
    asin: String,
    title: String,
    subtitle: String,
    authors: Vec<String>,
    narrators: Vec<String>,
    runtime_minutes: Option<u64>,
    abridged: Option<bool>,
    language: String,
    release_date: String,
    publisher: String,
    description: String,
    series: Vec<EditionSeries>,
    image: String,
}

/// What `book::decide` could not settle, and why.
pub struct Unsettled {
    pub kind: HoldKind,
    pub proposal: Option<Proposal>,
    pub reason: String,
}

/// A provider or model was unreachable or busy; worth trying again later.
pub struct Unavailable(pub String);

pub enum Resolution {
    /// Identity and completeness are certain; the proposal is enriched.
    Publish {
        proposal: Proposal,
        order: Vec<usize>,
        evidence: Value,
    },
    Hold {
        proposal: Option<Proposal>,
        reason: String,
        evidence: Value,
    },
    /// Something was temporarily unavailable.
    Retry {
        proposal: Option<Proposal>,
        reason: String,
        evidence: Value,
    },
}

struct Matches {
    /// Editions of this title and author.
    all: Vec<Edition>,
    /// Those whose runtime matches the discs.
    timed: Vec<Edition>,
}

fn span(seconds: f64) -> String {
    let minutes = (seconds / 60.0).round() as u64;
    format!("{} h {:02} min", minutes / 60, minutes % 60)
}

/// The part of a catalogue title before an edition note, as in
/// `The Bad Beginning, A Multi-Voice Recording`.
fn leading_title(title: &str) -> &str {
    let mut end = title.len();
    for marker in [": ", ", ", " (", " - ", " ["] {
        if let Some(index) = title.find(marker) {
            end = end.min(index);
        }
    }
    title[..end].trim()
}

fn title_matches(candidate: &str, wanted: &str) -> bool {
    let (candidate_key, wanted_key) = (normalize(candidate), normalize(wanted));
    if candidate_key.is_empty() || wanted_key.is_empty() {
        return false;
    }
    candidate_key == wanted_key
        || normalize(leading_title(candidate)) == wanted_key
        || candidate_key == normalize(leading_title(wanted))
        || similarity(candidate, wanted) >= 0.9
}

/// Surname and first initial, which survive both speech recognition and
/// `J.K.` against `Joanne`.
fn surname_initial(name: &str) -> Option<(String, char)> {
    let tokens = words(name);
    let surname = tokens.last()?.clone();
    let initial = tokens.first()?.chars().next()?;
    (tokens.len() >= 2 && surname.chars().count() >= 3).then_some((surname, initial))
}

fn person_matches(known: &str, wanted: &str) -> bool {
    !normalize(known).is_empty()
        && (similarity(known, wanted) >= 0.8
            || surname_initial(known).is_some_and(|pair| Some(pair) == surname_initial(wanted)))
}

fn matching_author<'a>(edition: &'a Edition, wanted: &str) -> Option<&'a str> {
    edition
        .authors
        .iter()
        .map(String::as_str)
        .find(|author| person_matches(author, wanted))
}

/// Announcements and disc changes add a little to the catalogue's runtime.
fn runtime_matches(disc_seconds: f64, minutes: u64) -> bool {
    let edition = minutes as f64 * 60.0;
    (disc_seconds - edition).abs() <= f64::max(240.0, edition * 0.03)
}

fn edition_summary(edition: &Edition, runtime: Option<f64>) -> Value {
    json!({
        "asin": edition.asin,
        "title": edition.title,
        "authors": edition.authors,
        "narrators": edition.narrators,
        "runtimeMinutes": edition.runtime_minutes,
        "abridged": edition.abridged,
        "runtimeMatches": match (runtime, edition.runtime_minutes) {
            (Some(seconds), Some(minutes)) => json!(runtime_matches(seconds, minutes)),
            _ => Value::Null,
        },
    })
}

/// The one edition the discs are, when the runtime leaves a choice: the one
/// read by the announced narrator, or any when they share their narrators.
fn choose_edition<'a>(timed: &'a [Edition], narrator: &str) -> Option<&'a Edition> {
    if timed.len() == 1 {
        return timed.first();
    }
    if !narrator.is_empty() {
        let by_narrator: Vec<&Edition> = timed
            .iter()
            .filter(|edition| {
                narrator.split(", ").any(|wanted| {
                    edition
                        .narrators
                        .iter()
                        .any(|known| person_matches(known, wanted))
                })
            })
            .collect();
        if by_narrator.len() == 1 {
            return by_narrator.first().copied();
        }
    }
    let narrators: BTreeSet<Vec<String>> = timed
        .iter()
        .map(|edition| {
            edition
                .narrators
                .iter()
                .map(|name| normalize(name))
                .collect()
        })
        .collect();
    (narrators.len() == 1).then(|| timed.first()).flatten()
}

/// Add an edition's details without touching the author or title. `exact`
/// is true when the edition is this very recording, so its narrator, ASIN
/// and abridgement apply; otherwise only what every edition of the book
/// shares is taken.
fn apply_edition(proposal: &mut Proposal, edition: &Edition, exact: bool) {
    if let Some(series) = edition.series.first() {
        let name = series
            .title
            .trim()
            .trim_end_matches("(abridged)")
            .trim_end_matches("(Abridged)")
            .trim()
            .to_string();
        if !name.is_empty() {
            proposal.series = Some(Series {
                name,
                sequence: series.sequence.trim().to_string(),
            });
        }
    }
    if proposal.description.is_empty() {
        proposal.description.clone_from(&edition.description);
    }
    if proposal.cover_url.is_empty() {
        proposal.cover_url.clone_from(&edition.image);
    }
    if !exact {
        return;
    }
    if proposal.narrator.is_empty() {
        proposal.narrator = edition.narrators.join(", ");
    }
    proposal.asin.clone_from(&edition.asin);
    proposal.abridged = edition.abridged;
    if proposal.publisher.is_empty() {
        proposal.publisher.clone_from(&edition.publisher);
    }
    if proposal.year.is_none() {
        proposal.year = edition
            .release_date
            .get(..4)
            .and_then(|year| year.parse().ok())
            .filter(|year| (1900..=2999).contains(year));
    }
    let restates_series = proposal
        .series
        .as_ref()
        .is_some_and(|series| normalize(&edition.subtitle).contains(&normalize(&series.name)));
    if !edition.subtitle.is_empty() && !restates_series {
        proposal.subtitle.clone_from(&edition.subtitle);
    }
}

/// Discs in playing order, and whether that order is known rather than
/// taken from the file names.
fn disc_order(sources: &[Source]) -> (Vec<usize>, bool) {
    let numbers: Vec<Option<u32>> = sources
        .iter()
        .map(|source| source.disc.disc_number)
        .collect();
    let mut by_number: Vec<(u32, usize)> = numbers
        .iter()
        .enumerate()
        .filter_map(|(index, number)| number.map(|number| (number, index)))
        .collect();
    by_number.sort_unstable();
    let contiguous = by_number.len() == sources.len()
        && by_number
            .iter()
            .enumerate()
            .all(|(position, (number, _))| *number as usize == position + 1);
    if contiguous {
        return (
            by_number.into_iter().map(|(_, index)| index).collect(),
            true,
        );
    }
    let mut order: Vec<usize> = (0..sources.len()).collect();
    order.sort_by_key(|index| natural_key(&sources[*index].disc.iso_name));
    (order, sources.len() == 1)
}

/// True when every word of `phrase` (short joining words aside) occurs in
/// the transcript. Bonsai recognises famous prose and will name a book that
/// was never announced: asked for the credits of an excerpt with none, it
/// answered "1984" on 2026-11-21. Only what was actually said counts.
fn was_said(transcript: &BTreeSet<String>, phrase: &str) -> bool {
    let tokens = words(phrase);
    let mut significant: Vec<&String> = tokens
        .iter()
        .filter(|word| word.chars().count() >= 3)
        .collect();
    if significant.is_empty() {
        significant = tokens.iter().collect();
    }
    !significant.is_empty()
        && significant
            .into_iter()
            .all(|word| transcript.contains(word))
}

fn text_key(parts: &[&str]) -> String {
    let mut hasher = Sha256::new();
    for part in parts {
        hasher.update(part.as_bytes());
        hasher.update([0]);
    }
    hasher
        .finalize()
        .iter()
        .map(|byte| format!("{byte:02x}"))
        .collect()
}

impl Identifier {
    pub fn can_identify(&self) -> bool {
        self.socket.is_some()
    }

    fn search(&self, title: &str, author: Option<&str>) -> Result<Vec<Edition>, Unavailable> {
        let Some(socket) = &self.socket else {
            return Ok(Vec::new());
        };
        let body =
            json!({ "title": clip(title, 200), "author": author.map(|name| clip(name, 200)) });
        match post_unix(socket, SEARCH_ROUTE, &body.to_string()) {
            Ok((200, value)) => {
                Ok(serde_json::from_value(value["products"].clone()).unwrap_or_default())
            }
            // The broker refused the query itself, so asking again cannot help.
            Ok((400, _)) => Ok(Vec::new()),
            Ok((status, value)) => Err(Unavailable(format!(
                "The Audible catalogue lookup failed ({status} {}).",
                value["error"].as_str().unwrap_or("no detail")
            ))),
            Err(error) => Err(Unavailable(format!(
                "The provider broker could not be reached: {error:#}."
            ))),
        }
    }

    /// English editions of this title and author. Speech recognition often
    /// misspells an author, which the catalogue search does not forgive, so
    /// a search that finds nothing is repeated on the title alone and then
    /// once more with the catalogue's own spelling, which brings back the
    /// book's other editions.
    fn find(
        &self,
        title: &str,
        author: &str,
        runtime: Option<f64>,
    ) -> Result<Matches, Unavailable> {
        let keep = |editions: Vec<Edition>| -> Vec<Edition> {
            editions
                .into_iter()
                .filter(|edition| {
                    matches!(edition.language.as_str(), "" | "english")
                        && title_matches(&edition.title, title)
                        && matching_author(edition, author).is_some()
                })
                .collect()
        };
        let mut all = keep(self.search(title, Some(author))?);
        if all.is_empty() {
            all = keep(self.search(title, None)?);
            let canonical = all.first().and_then(|edition| {
                Some((
                    leading_title(&edition.title).to_string(),
                    matching_author(edition, author)?.to_string(),
                ))
            });
            if let Some((canonical_title, canonical_author)) = canonical {
                for edition in keep(self.search(&canonical_title, Some(&canonical_author))?) {
                    if !all.iter().any(|known| known.asin == edition.asin) {
                        all.push(edition);
                    }
                }
            }
        }
        let timed = all
            .iter()
            .filter(|edition| match (runtime, edition.runtime_minutes) {
                (Some(seconds), Some(minutes)) => runtime_matches(seconds, minutes),
                _ => false,
            })
            .cloned()
            .collect();
        Ok(Matches { all, timed })
    }

    /// Download an edition's cover through the broker; false when it cannot.
    pub fn fetch_cover(&self, url: &str, destination: &Path) -> bool {
        let Some(socket) = &self.socket else {
            return false;
        };
        let Ok((200, value)) = post_unix(socket, COVER_ROUTE, &json!({ "image": url }).to_string())
        else {
            return false;
        };
        value["base64"]
            .as_str()
            .and_then(|encoded| {
                base64::engine::general_purpose::STANDARD
                    .decode(encoded)
                    .ok()
            })
            .filter(|bytes| bytes.starts_with(&[0xff, 0xd8, 0xff]))
            .is_some_and(|bytes| fs::write(destination, bytes).is_ok())
    }

    /// Add narrator, series, description and cover to a book whose identity
    /// is already certain. Returns what was found, for the import record.
    pub fn enrich(
        &self,
        proposal: &mut Proposal,
        runtime: Option<f64>,
    ) -> Result<Value, Unavailable> {
        if self.socket.is_none() || proposal.title.is_empty() || proposal.author.is_empty() {
            return Ok(Value::Null);
        }
        let matches = self.find(&proposal.title, &proposal.author, runtime)?;
        let chosen = choose_edition(&matches.timed, &proposal.narrator);
        let basis = if let Some(edition) = chosen {
            apply_edition(proposal, edition, true);
            "runtime"
        } else if let Some(edition) = matches.timed.first().or(matches.all.first()) {
            apply_edition(proposal, edition, false);
            "title-and-author"
        } else {
            "none"
        };
        Ok(json!({
            "provider": "audible",
            "matchedBy": basis,
            "asin": chosen.map(|edition| edition.asin.as_str()),
            "editions": matches.all.iter().map(|edition| edition_summary(edition, runtime)).collect::<Vec<_>>(),
        }))
    }

    /// Transcribe part of one file of a disc; empty when it holds no speech
    /// or the tools are not configured.
    fn hear(
        &self,
        tools: &Tools,
        source: &Source,
        member: &str,
        from_end: bool,
        budget: f64,
        work: &Path,
    ) -> (String, f64) {
        let Some((parakeet, model)) = &self.parakeet else {
            return (String::new(), 0.0);
        };
        let extension = Path::new(member)
            .extension()
            .and_then(|ext| ext.to_str())
            .unwrap_or("bin");
        let file = work.join(format!("excerpt-source.{extension}"));
        let _ = fs::remove_file(&file);
        if extract_member(&tools.sevenzip, source.path, member, &file).is_err() {
            return (String::new(), 0.0);
        }
        let Some(seconds) = media_seconds(tools, &file) else {
            let _ = fs::remove_file(&file);
            return (String::new(), 0.0);
        };
        let take = seconds.min(budget);
        let start = if from_end { seconds - take } else { 0.0 };
        let asr = Asr {
            ffmpeg: &tools.ffmpeg,
            parakeet,
            model,
            threads: self.threads,
        };
        let text = transcribe_excerpt(&asr, &file, work, start.floor() as u32, take.ceil() as u32)
            .unwrap_or_default();
        let _ = fs::remove_file(&file);
        (text, take)
    }

    fn members(disc: &Disc) -> Vec<String> {
        if disc.kind == DiscKind::AudioArchive {
            let mut tracks = disc.tracks.clone();
            tracks.sort_by_key(|track| track.number);
            tracks.into_iter().map(|track| track.file).collect()
        } else {
            disc.audio_files.clone()
        }
    }

    /// What is said at the start of the first disc and the end of the last.
    fn announcements(
        &self,
        tools: &Tools,
        first: &Source,
        last: &Source,
        cache: &mut Cache,
        work: &Path,
    ) -> (String, String) {
        let opening_key = format!("{}:opening", first.sha256);
        let opening = match cache.transcripts.get(&opening_key) {
            Some(text) => text.clone(),
            None => {
                let mut heard = Vec::new();
                let mut remaining = OPENING_SECONDS;
                for member in Self::members(first.disc).iter().take(6) {
                    let (text, used) = self.hear(tools, first, member, false, remaining, work);
                    if used <= 0.0 {
                        break;
                    }
                    heard.push(text);
                    remaining -= used;
                    if remaining < 20.0 {
                        break;
                    }
                }
                let text = heard.join(" ").trim().to_string();
                if self.parakeet.is_some() {
                    cache.transcripts.insert(opening_key, text.clone());
                }
                text
            }
        };
        let closing_key = format!("{}:closing", last.sha256);
        let closing = match cache.transcripts.get(&closing_key) {
            Some(text) => text.clone(),
            None => {
                let text = Self::members(last.disc)
                    .last()
                    .map(|member| {
                        self.hear(tools, last, member, true, CLOSING_SECONDS, work)
                            .0
                    })
                    .unwrap_or_default();
                if self.parakeet.is_some() {
                    cache.transcripts.insert(closing_key, text.clone());
                }
                text
            }
        };
        (opening, closing)
    }

    fn read_credits(
        &self,
        opening: &str,
        closing: &str,
        cache: &mut Cache,
    ) -> Result<Option<Credits>, Unavailable> {
        let Some(bonsai) = &self.bonsai else {
            return Ok(None);
        };
        if opening.is_empty() && closing.is_empty() {
            return Ok(None);
        }
        let key = text_key(&[opening, closing]);
        if let Some(credits) = cache.credits.get(&key) {
            return Ok((!credits.title.is_empty()).then(|| credits.clone()));
        }
        let schema = json!({
            "type": "object",
            "properties": {
                "title": {"type": ["string", "null"]},
                "author": {"type": ["string", "null"]},
                "narrator": {"type": ["string", "null"]},
                "publisher": {"type": ["string", "null"]},
                "abridged": {"type": ["boolean", "null"]}
            },
            "required": ["title", "author", "narrator", "publisher", "abridged"]
        });
        let prompt = format!(
            "This is a speech-recognition transcript of the start and the end of an audiobook \
on CD. The recogniser may misspell names. Report the book's title, its author, its narrator \
(the reader), its publisher and whether it is announced as abridged (true) or unabridged \
(false), as announced. Use null for anything that is not announced. Do not guess and do not \
use outside knowledge.\n\nStart of the first disc:\n{}\n\nEnd of the last disc:\n{}",
            clip(opening, 6000),
            clip(closing, 3000)
        );
        let answer = bonsai
            .chat_json(
                vec![json!({"type": "text", "text": prompt})],
                schema,
                400,
                false,
            )
            .map_err(|error| {
                Unavailable(format!(
                    "Bonsai could not read the spoken announcements: {error:#}."
                ))
            })?;
        let field = |name: &str| {
            answer[name]
                .as_str()
                .map(|text| text.split_whitespace().collect::<Vec<_>>().join(" "))
                .filter(|text| text.chars().count() <= 200)
                .unwrap_or_default()
        };
        let said: BTreeSet<String> = words(opening).into_iter().chain(words(closing)).collect();
        let spoken = |name: &str| {
            Some(field(name))
                .filter(|text| was_said(&said, text))
                .unwrap_or_default()
        };
        let credits = Credits {
            title: spoken("title"),
            author: spoken("author"),
            narrator: spoken("narrator"),
            publisher: spoken("publisher"),
            abridged: answer["abridged"].as_bool(),
        };
        cache.credits.insert(key, credits.clone());
        Ok((!credits.title.is_empty()).then_some(credits))
    }

    /// Try to settle a set that `book::decide` held as unidentified or as
    /// having an unknown number of discs.
    pub fn resolve(
        &self,
        tools: &Tools,
        unsettled: Unsettled,
        sources: &[Source],
        cache: &mut Cache,
        work: &Path,
    ) -> Resolution {
        let Unsettled {
            kind,
            proposal: base,
            reason: fallback_reason,
        } = unsettled;
        let runtime: Option<f64> = sources.iter().map(|source| source.disc.seconds).sum();
        let (order, order_known) = disc_order(sources);
        let mut evidence = json!({
            "playingTime": runtime.map(span),
            "discOrderKnown": order_known,
        });
        if sources.is_empty() || !self.can_identify() || kind == HoldKind::Conflict {
            return Resolution::Hold {
                proposal: base,
                reason: fallback_reason,
                evidence,
            };
        }

        // Who the discs say they are.
        let mut proposal;
        let named_by;
        if kind == HoldKind::UnknownTotal {
            let Some(certain) = base else {
                return Resolution::Hold {
                    proposal: None,
                    reason: fallback_reason,
                    evidence,
                };
            };
            named_by = certain.confirmed_by.clone();
            proposal = certain;
        } else {
            let (first, last) = (&sources[order[0]], &sources[order[order.len() - 1]]);
            let (opening, closing) = self.announcements(tools, first, last, cache, work);
            evidence["openingTranscript"] = json!(clip(&opening, 600));
            evidence["closingTranscript"] = json!(clip(&closing, 300));
            let credits = match self.read_credits(&opening, &closing, cache) {
                Ok(credits) => credits,
                Err(Unavailable(reason)) => {
                    return Resolution::Retry {
                        proposal: base,
                        reason,
                        evidence,
                    };
                }
            };
            evidence["spokenCredits"] = json!(credits);
            let stub = base.clone().filter(|stub| {
                !stub.title.is_empty()
                    && !stub.author.is_empty()
                    && sources
                        .iter()
                        .all(|source| source.disc.lookup_status == "cdstub")
            });
            proposal = match (credits, stub) {
                (Some(credits), _) if !credits.author.is_empty() => {
                    named_by = "spoken-credits".to_string();
                    Proposal {
                        author: credits.author,
                        narrator: credits.narrator,
                        title: credits.title,
                        category: "audiobook".to_string(),
                        ..Proposal::default()
                    }
                }
                (_, Some(stub)) => {
                    named_by = "musicbrainz-cd-stub".to_string();
                    Proposal {
                        category: "audiobook".to_string(),
                        ..stub
                    }
                }
                _ => {
                    return Resolution::Hold {
                        proposal: base,
                        reason: format!(
                            "{fallback_reason} The opening and closing announcements did not name a title and an author either."
                        ),
                        evidence,
                    };
                }
            };
        }
        proposal.disc_total = Some(sources.len() as u32);
        let named = format!("{} by {}", proposal.title, proposal.author);

        // Whether the catalogue has that book at this length.
        let matches = match self.find(&proposal.title, &proposal.author, runtime) {
            Ok(matches) => matches,
            Err(Unavailable(reason)) => {
                return Resolution::Retry {
                    proposal: Some(proposal),
                    reason,
                    evidence,
                };
            }
        };
        evidence["editions"] = json!(matches
            .all
            .iter()
            .map(|edition| edition_summary(edition, runtime))
            .collect::<Vec<_>>());
        let heard = if kind == HoldKind::UnknownTotal {
            fallback_reason.clone()
        } else {
            format!("The discs name {named}.")
        };
        if matches.all.is_empty() {
            return Resolution::Hold {
                proposal: Some(proposal),
                reason: format!(
                    "{heard} Audible lists no edition of that title and author to compare with."
                ),
                evidence,
            };
        }
        if kind == HoldKind::Unidentified {
            // The catalogue's spelling replaces the recogniser's, also in
            // the name a person is offered when the book stays held.
            let reference = &matches.all[0];
            if let Some(author) = matching_author(reference, &proposal.author) {
                proposal.author = author.to_string();
            }
            proposal.title = if normalize(&reference.title) == normalize(&proposal.title) {
                reference.title.clone()
            } else {
                leading_title(&reference.title).to_string()
            };
        }
        let Some(runtime) = runtime else {
            return Resolution::Hold {
                proposal: Some(proposal),
                reason: format!("{heard} The discs' playing time is not known, so no edition could be confirmed."),
                evidence,
            };
        };
        if matches.timed.is_empty() {
            let lengths: Vec<String> = matches
                .all
                .iter()
                .filter_map(|edition| {
                    let minutes = edition.runtime_minutes?;
                    let kind = match edition.abridged {
                        Some(true) => " (abridged)",
                        Some(false) => " (unabridged)",
                        None => "",
                    };
                    Some(format!("{}{kind}", span(minutes as f64 * 60.0)))
                })
                .collect::<BTreeSet<_>>()
                .into_iter()
                .collect();
            return Resolution::Hold {
                proposal: Some(proposal),
                reason: format!(
                    "{heard} The discs present play for {}; Audible lists the book at {}. Discs may be missing, or this is a different recording.",
                    span(runtime),
                    lengths.join(", ")
                ),
                evidence,
            };
        }

        // Both sources agree, and the playing time shows the set is whole.
        let chosen = choose_edition(&matches.timed, &proposal.narrator);
        let edition = chosen.unwrap_or(&matches.timed[0]);
        if kind == HoldKind::Unidentified {
            // The narrator comes from the edition, never from the transcript.
            proposal.narrator.clear();
        }
        apply_edition(&mut proposal, edition, chosen.is_some());
        proposal.confirmed_by = format!("{named_by}+audible-runtime");
        evidence["matchedAsin"] = json!(chosen.map(|edition| edition.asin.as_str()));
        if !order_known {
            return Resolution::Hold {
                reason: format!(
                    "Identified as {} by {}, but the discs carry no usable disc numbers. Renaming the folder to its confirmWith name imports them in file-name order.",
                    proposal.title, proposal.author
                ),
                proposal: Some(proposal),
                evidence,
            };
        }
        Resolution::Publish {
            proposal,
            order,
            evidence,
        }
    }
}
