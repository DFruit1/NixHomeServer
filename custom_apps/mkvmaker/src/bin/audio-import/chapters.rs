//! Real chapter starts, heard rather than assumed.
//!
//! CD tracks are index points, often every few minutes, so a chapter per
//! track says little. A narrator announces a chapter after a pause, so the
//! first seconds after every track start and every long silence are
//! transcribed with Parakeet (in batches, on the CPU) and kept when they
//! begin with a spoken heading: `Chapter seven`, `Part two`, `Prologue`.
//! Bonsai only tidies the wording of a heading that was found; it never
//! decides whether one is there.
//!
//! The headings are used only when their numbers form a believable run.
//! Otherwise the caller keeps one chapter per track.

use crate::{
    bonsai::Bonsai,
    build::{Chapter, Stopped},
    text::words,
};
use anyhow::{bail, Context, Result};
use serde_json::{json, Value};
use std::{
    collections::BTreeSet,
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::atomic::{AtomicBool, Ordering},
};

/// A pause this long may precede a heading. Measured on a commercial
/// audiobook: about ten such pauses an hour, and one before every chapter.
const SILENCE_SECONDS: f64 = 1.8;
const SILENCE_NOISE: &str = "-35dB";
/// A heading and the start of its title fit in this much speech.
const EXCERPT_SECONDS: f64 = 12.0;
/// Candidates closer than this to the previous one are the same pause.
const MIN_SPACING: f64 = 4.0;
/// Files handed to one Parakeet run, which loads its model once.
const BATCH: usize = 60;

pub struct Speech<'a> {
    pub ffmpeg: &'a Path,
    pub parakeet: &'a Path,
    pub model: &'a Path,
    pub threads: u32,
    pub bonsai: Option<&'a Bonsai>,
}

pub struct Found {
    pub chapters: Vec<Chapter>,
    /// What was examined, for the import record.
    pub note: Value,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Kind {
    Chapter,
    /// Part, Book or Section: a division above chapters.
    Division,
    /// Prologue, Preface, Epilogue and the like, which carry no number.
    Matter,
}

#[derive(Clone, Debug, PartialEq)]
struct Heading {
    kind: Kind,
    number: Option<u32>,
    /// `Chapter 7`, `Part 2`, `Prologue`.
    label: String,
}

struct Hit {
    start: f64,
    heading: Heading,
    excerpt: String,
    title: String,
}

fn small_number(word: &str) -> Option<u32> {
    const UNITS: [&str; 20] = [
        "zero",
        "one",
        "two",
        "three",
        "four",
        "five",
        "six",
        "seven",
        "eight",
        "nine",
        "ten",
        "eleven",
        "twelve",
        "thirteen",
        "fourteen",
        "fifteen",
        "sixteen",
        "seventeen",
        "eighteen",
        "nineteen",
    ];
    const ORDINALS: [&str; 20] = [
        "zeroth",
        "first",
        "second",
        "third",
        "fourth",
        "fifth",
        "sixth",
        "seventh",
        "eighth",
        "ninth",
        "tenth",
        "eleventh",
        "twelfth",
        "thirteenth",
        "fourteenth",
        "fifteenth",
        "sixteenth",
        "seventeenth",
        "eighteenth",
        "nineteenth",
    ];
    UNITS
        .iter()
        .position(|unit| *unit == word)
        .or_else(|| ORDINALS.iter().position(|ordinal| *ordinal == word))
        .map(|value| value as u32)
}

fn tens(word: &str) -> Option<u32> {
    const TENS: [(&str, u32); 16] = [
        ("twenty", 20),
        ("thirty", 30),
        ("forty", 40),
        ("fifty", 50),
        ("sixty", 60),
        ("seventy", 70),
        ("eighty", 80),
        ("ninety", 90),
        ("twentieth", 20),
        ("thirtieth", 30),
        ("fortieth", 40),
        ("fiftieth", 50),
        ("sixtieth", 60),
        ("seventieth", 70),
        ("eightieth", 80),
        ("ninetieth", 90),
    ];
    TENS.iter()
        .find(|(name, _)| *name == word)
        .map(|(_, value)| *value)
}

/// A spoken or written number at the start of `tokens` (up to 199), and how
/// many tokens it took.
fn leading_number(tokens: &[String]) -> Option<(u32, usize)> {
    let mut index = 0;
    if tokens
        .first()
        .is_some_and(|word| word == "the" || word == "number")
    {
        index = 1;
    }
    let first = tokens.get(index)?;
    if let Ok(value) = first.parse::<u32>() {
        return (1..=999).contains(&value).then_some((value, index + 1));
    }
    let mut value = 0;
    let mut used = index;
    let mut word = first.as_str();
    if word == "one" && tokens.get(used + 1).is_some_and(|next| next == "hundred") {
        value = 100;
        used += 2;
        if tokens.get(used).is_some_and(|next| next == "and") {
            used += 1;
        }
        match tokens.get(used) {
            Some(next) => word = next.as_str(),
            None => return Some((value, used)),
        }
    }
    if let Some(ten) = tens(word) {
        used += 1;
        let unit = tokens
            .get(used)
            .and_then(|next| small_number(next))
            .filter(|unit| (1..=9).contains(unit));
        if unit.is_some() {
            used += 1;
        }
        return Some((value + ten + unit.unwrap_or(0), used));
    }
    if let Some(unit) = small_number(word).filter(|unit| *unit >= 1) {
        return Some((value + unit, used + 1));
    }
    (value > 0).then_some((value, used))
}

/// Words with spoken numbers written as digits, for comparing wordings.
fn comparable(text: &str) -> Vec<String> {
    words(text)
        .into_iter()
        .map(|word| match small_number(&word).or_else(|| tens(&word)) {
            Some(value) => value.to_string(),
            None => word,
        })
        .collect()
}

/// The heading an excerpt begins with, if it begins with one.
fn leading_heading(excerpt: &str) -> Option<Heading> {
    let tokens = words(excerpt);
    let first = tokens.first()?.as_str();
    let numbered = match first {
        "chapter" => Some((Kind::Chapter, "Chapter")),
        "part" => Some((Kind::Division, "Part")),
        "book" => Some((Kind::Division, "Book")),
        "section" => Some((Kind::Division, "Section")),
        _ => None,
    };
    if let Some((kind, name)) = numbered {
        // "Part of the problem" and "Book in hand" are not headings.
        let (number, _) = leading_number(&tokens[1..])?;
        return Some(Heading {
            kind,
            number: Some(number),
            label: format!("{name} {number}"),
        });
    }
    let second = tokens.get(1).map(String::as_str).unwrap_or_default();
    let label = match (first, second) {
        ("prologue", _) => "Prologue",
        ("epilogue", _) => "Epilogue",
        ("preface", _) => "Preface",
        // The recogniser writes the homophone.
        ("foreword" | "forward", _) => "Foreword",
        ("introduction", _) => "Introduction",
        ("afterword", _) => "Afterword",
        ("appendix", _) => "Appendix",
        ("postscript", _) => "Postscript",
        ("interlude", _) => "Interlude",
        ("acknowledgments" | "acknowledgements", _) => "Acknowledgements",
        ("authors", "note") => "Author's Note",
        _ => return None,
    };
    Some(Heading {
        kind: Kind::Matter,
        number: None,
        label: label.to_string(),
    })
}

/// The heading an excerpt opens with, and the excerpt from that heading on.
/// A numbered heading also counts when it starts a later sentence within the
/// first words, as in "Ten principles every detective needs. Chapter 1."
/// A mention inside a sentence ("as we saw in chapter two") does not.
fn find_heading(excerpt: &str) -> Option<(Heading, String)> {
    if let Some(heading) = leading_heading(excerpt) {
        return Some((heading, excerpt.to_string()));
    }
    let mut words_before = 0;
    let mut rest = excerpt;
    while let Some(end) = rest.find(['.', '?', '!']) {
        words_before += words(&rest[..end]).len();
        rest = rest[end + 1..].trim_start();
        if words_before > 20 {
            break;
        }
        if let Some(heading) = leading_heading(rest).filter(|heading| heading.kind != Kind::Matter)
        {
            return Some((heading, rest.to_string()));
        }
    }
    None
}

/// Indexes of the longest strictly increasing run of `numbers`.
fn increasing_run(numbers: &[u32]) -> Vec<usize> {
    let mut best: Vec<Vec<usize>> = Vec::with_capacity(numbers.len());
    for (index, number) in numbers.iter().enumerate() {
        let mut run = (0..index)
            .filter(|earlier| numbers[*earlier] < *number)
            .map(|earlier| best[earlier].clone())
            .max_by_key(Vec::len)
            .unwrap_or_default();
        run.push(index);
        best.push(run);
    }
    best.into_iter().max_by_key(Vec::len).unwrap_or_default()
}

/// Keep the headings that make a believable table of contents: chapter
/// numbers rising within each part, divisions rising overall, and front or
/// back matter only outside the numbered headings. `None` when fewer than
/// three chapters (or, failing that, three divisions) were heard, or when
/// they leave more than two fifths of their number range unheard.
fn believable(hits: Vec<Hit>) -> Option<Vec<Hit>> {
    let division_indexes: Vec<usize> = (0..hits.len())
        .filter(|index| hits[*index].heading.kind == Kind::Division)
        .collect();
    let division_numbers: Vec<u32> = division_indexes
        .iter()
        .filter_map(|index| hits[*index].heading.number)
        .collect();
    let kept_divisions: BTreeSet<usize> = increasing_run(&division_numbers)
        .into_iter()
        .map(|at| division_indexes[at])
        .collect();

    // Chapter numbers may start again after each kept division.
    let mut kept: BTreeSet<usize> = kept_divisions.clone();
    let mut chapters_kept = 0;
    let mut expected = 0;
    let mut segment: Vec<usize> = Vec::new();
    let mut close = |segment: &mut Vec<usize>, kept: &mut BTreeSet<usize>| {
        let numbers: Vec<u32> = segment
            .iter()
            .filter_map(|index| hits[*index].heading.number)
            .collect();
        let run = increasing_run(&numbers);
        if let (Some(first), Some(last)) = (run.first(), run.last()) {
            expected += numbers[*last] - numbers[*first] + 1;
            chapters_kept += run.len();
        }
        kept.extend(run.into_iter().map(|at| segment[at]));
        segment.clear();
    };
    for (index, hit) in hits.iter().enumerate() {
        match hit.heading.kind {
            Kind::Chapter => segment.push(index),
            Kind::Division if kept_divisions.contains(&index) => close(&mut segment, &mut kept),
            _ => {}
        }
    }
    close(&mut segment, &mut kept);
    let chapters_believable = chapters_kept >= 3 && chapters_kept as f64 >= expected as f64 * 0.6;
    if !chapters_believable {
        // A book split only into "Part One", "Part Two" (or a LibriVox
        // "Section 3") is still a table of contents.
        let run = increasing_run(&division_numbers);
        let span = match (run.first(), run.last()) {
            (Some(first), Some(last)) => division_numbers[*last] - division_numbers[*first] + 1,
            _ => 0,
        };
        if run.len() < 3 || (run.len() as f64) < f64::from(span) * 0.6 {
            return None;
        }
        kept.clone_from(&kept_divisions);
    }
    let (Some(first_numbered), Some(last_numbered)) = (kept.first().copied(), kept.last().copied())
    else {
        return None;
    };
    Some(
        hits.into_iter()
            .enumerate()
            .filter(|(index, hit)| {
                kept.contains(index)
                    || (hit.heading.kind == Kind::Matter
                        && (*index < first_numbered || *index > last_numbered))
            })
            .map(|(_, hit)| hit)
            .collect(),
    )
}

fn check_stop(stop: &AtomicBool) -> Result<()> {
    if stop.load(Ordering::Relaxed) {
        return Err(Stopped.into());
    }
    Ok(())
}

/// Ends of the long silences in one file, in seconds from its start.
fn silence_ends(speech: &Speech, file: &Path) -> Result<Vec<f64>> {
    let output = Command::new(speech.ffmpeg)
        .args(["-hide_banner", "-nostdin", "-v", "info", "-i"])
        .arg(file)
        .args([
            "-map",
            "0:a:0",
            "-af",
            &format!("silencedetect=noise={SILENCE_NOISE}:d={SILENCE_SECONDS}"),
            "-f",
            "null",
            "-",
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .output()
        .with_context(|| format!("cannot run {}", speech.ffmpeg.display()))?;
    if !output.status.success() {
        bail!("ffmpeg cannot scan {} for silences", file.display());
    }
    Ok(String::from_utf8_lossy(&output.stderr)
        .lines()
        .filter_map(|line| line.split("silence_end: ").nth(1))
        .filter_map(|rest| rest.split_whitespace().next()?.parse::<f64>().ok())
        .collect())
}

fn cut_excerpt(speech: &Speech, file: &Path, start: f64, destination: &Path) -> bool {
    Command::new(speech.ffmpeg)
        .args([
            "-hide_banner",
            "-nostdin",
            "-v",
            "error",
            "-y",
            "-ss",
            &format!("{start:.3}"),
        ])
        .args(["-t", &EXCERPT_SECONDS.to_string(), "-i"])
        .arg(file)
        .args([
            "-map",
            "0:a:0",
            "-ac",
            "1",
            "-ar",
            "16000",
            "-c:a",
            "pcm_s16le",
        ])
        .arg(destination)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .is_ok_and(|status| status.success())
}

/// Transcribe a batch of excerpts in one Parakeet run; a missing transcript
/// is an empty one.
fn transcribe(speech: &Speech, files: &[PathBuf]) -> Result<Vec<String>> {
    let status = Command::new(speech.parakeet)
        .arg("-m")
        .arg(speech.model)
        .args(["-t", &speech.threads.to_string(), "-ng", "-np", "-otxt"])
        .args(files)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .context("cannot start Parakeet")?;
    if !status.success() {
        bail!("Parakeet failed with {status}");
    }
    Ok(files
        .iter()
        .map(|file| {
            let mut name = file.as_os_str().to_os_string();
            name.push(".txt");
            fs::read_to_string(PathBuf::from(name))
                .map(|text| text.split_whitespace().collect::<Vec<_>>().join(" "))
                .unwrap_or_default()
        })
        .collect())
}

/// Ask Bonsai how each found heading should be printed. A wording is used
/// only if it starts with the heading that was detected and adds nothing
/// that was not said.
fn tidy_titles(bonsai: &Bonsai, hits: &mut [Hit]) {
    for (offset, batch) in hits.chunks_mut(25).enumerate() {
        let lines: Vec<String> = batch
            .iter()
            .enumerate()
            .map(|(index, hit)| {
                let opening: Vec<&str> = hit.excerpt.split_whitespace().take(28).collect();
                format!("{}. {}", index + 1, opening.join(" "))
            })
            .collect();
        let prompt = format!(
            "Each numbered line is a speech-recognition transcript of the first seconds of a \
chapter of an audiobook. It begins with the spoken chapter heading and runs on into the \
chapter's text. For each line give the heading as a table of contents would print it: the \
kind and number (for example \"Chapter 7\"), then a colon and the chapter's title in title \
case if a title is announced. Leave out the chapter's text. Use only words from the line.\n\n{}",
            lines.join("\n")
        );
        let schema = json!({
            "type": "object",
            "properties": {"headings": {"type": "array", "items": {
                "type": "object",
                "properties": {"line": {"type": "integer"}, "heading": {"type": "string"}},
                "required": ["line", "heading"]
            }}},
            "required": ["headings"]
        });
        let Ok(answer) = bonsai.chat_json(
            vec![json!({"type": "text", "text": prompt})],
            schema,
            1500,
            false,
        ) else {
            eprintln!(
                "Bonsai could not tidy chapter headings {}+; plain labels are used",
                offset * 25
            );
            continue;
        };
        for item in answer["headings"].as_array().into_iter().flatten() {
            let Some(hit) = item["line"]
                .as_u64()
                .and_then(|line| usize::try_from(line).ok())
                .and_then(|line| batch.get_mut(line.checked_sub(1)?))
            else {
                continue;
            };
            let heading = item["heading"]
                .as_str()
                .unwrap_or_default()
                .split_whitespace()
                .collect::<Vec<_>>()
                .join(" ");
            // Only the title is taken from Bonsai, which writes the number
            // as it pleases ("Chapter Two"); the kind and number stay as
            // detected. The recogniser writes "two" in one excerpt and "2"
            // in the next, so the title's numbers compare by value.
            let title = heading
                .split_once(':')
                .filter(|(head, _)| {
                    leading_heading(head).is_some_and(|read| read.label == hit.heading.label)
                })
                .map(|(_, title)| title.trim().trim_end_matches(['.', ':']).trim())
                .unwrap_or_default();
            let said: BTreeSet<String> = comparable(&hit.excerpt).into_iter().collect();
            let spoken = comparable(title).iter().all(|word| said.contains(word));
            if !title.is_empty() && spoken && title.chars().count() <= 100 {
                hit.title = format!("{}: {title}", hit.heading.label);
            }
        }
    }
}

/// Chapters heard in `pieces` (each a file and its playing time, in order),
/// or `None` when no believable run of headings was found.
pub fn spoken_chapters(
    speech: &Speech,
    pieces: &[(PathBuf, f64)],
    work: &Path,
    progress: &mut dyn FnMut(&str, f64),
    stop: &AtomicBool,
) -> Result<Option<Found>> {
    let total: f64 = pieces.iter().map(|(_, seconds)| seconds).sum();
    // Where a heading could be: every track start and the end of every pause.
    let mut candidates: Vec<(usize, f64, f64)> = Vec::new();
    let mut offset = 0.0;
    for (index, (file, seconds)) in pieces.iter().enumerate() {
        check_stop(stop)?;
        progress("Listening for pauses", offset / total.max(1.0) * 100.0);
        candidates.push((index, 0.0, offset));
        for end in silence_ends(speech, file)? {
            // The chapter starts just before the first word. The excerpt
            // starts a second earlier, inside the pause: cut at the word
            // itself, Parakeet garbled the heading ("SECTON ON").
            let mark = (end - 0.25).max(0.0);
            if mark + 3.0 < *seconds {
                candidates.push((index, (end - 1.0).max(0.0), offset + mark));
            }
        }
        offset += seconds;
    }
    candidates.sort_by(|left, right| left.2.total_cmp(&right.2));
    let mut spaced: Vec<(usize, f64, f64)> = Vec::new();
    for candidate in candidates {
        if spaced
            .last()
            .is_none_or(|previous| candidate.2 - previous.2 >= MIN_SPACING)
        {
            spaced.push(candidate);
        }
    }

    let directory = work.join("chapter-excerpts");
    let _ = fs::remove_dir_all(&directory);
    fs::create_dir_all(&directory)?;
    let mut hits = Vec::new();
    for (batch_index, batch) in spaced.chunks(BATCH).enumerate() {
        check_stop(stop)?;
        progress(
            "Listening for chapter headings",
            (batch_index * BATCH) as f64 / spaced.len().max(1) as f64 * 100.0,
        );
        let mut files = Vec::new();
        let mut cut = Vec::new();
        for (position, (piece, local, start)) in batch.iter().enumerate() {
            let file = directory.join(format!("c{position:03}.wav"));
            if cut_excerpt(speech, &pieces[*piece].0, *local, &file) {
                files.push(file);
                cut.push(*start);
            }
        }
        if files.is_empty() {
            continue;
        }
        for (start, excerpt) in cut.into_iter().zip(transcribe(speech, &files)?) {
            if let Some((heading, excerpt)) = find_heading(&excerpt) {
                let title = heading.label.clone();
                hits.push(Hit {
                    start,
                    heading,
                    excerpt,
                    title,
                });
            }
        }
        for file in &files {
            let mut text = file.as_os_str().to_os_string();
            text.push(".txt");
            let _ = fs::remove_file(PathBuf::from(text));
            let _ = fs::remove_file(file);
        }
    }
    let _ = fs::remove_dir_all(&directory);

    let heard = hits.len();
    let Some(mut kept) = believable(hits) else {
        return Ok(None);
    };
    check_stop(stop)?;
    if let Some(bonsai) = speech.bonsai {
        progress("Naming the chapters", 100.0);
        tidy_titles(bonsai, &mut kept);
    }
    let mut starts: Vec<(f64, String)> =
        kept.into_iter().map(|hit| (hit.start, hit.title)).collect();
    // Whatever precedes the first heading (publisher and title credits).
    if starts.first().is_some_and(|(start, _)| *start > 15.0) {
        starts.insert(0, (0.0, "Opening Credits".to_string()));
    } else if let Some(first) = starts.first_mut() {
        first.0 = 0.0;
    }
    let chapters: Vec<Chapter> = starts
        .iter()
        .enumerate()
        .map(|(id, (start, title))| Chapter {
            id,
            start: *start,
            end: starts.get(id + 1).map_or(total, |next| next.0),
            title: title.clone(),
        })
        .collect();
    Ok(Some(Found {
        note: json!({
            "placesExamined": spaced.len(),
            "headingsHeard": heard,
            "headingsKept": chapters.len(),
        }),
        chapters,
    }))
}
