//! Assemble a folder of disc ISOs into one book and decide what may happen.
//!
//! A book is published without a person only when every disc is an exact
//! MusicBrainz Disc ID match or carries the author and title typed at the
//! drive, the discs agree with each other, and the full set is present.
//! A folder name ending in `[N discs]` is a person's statement of both the
//! identity and the completeness of the set, like a descriptive DVD ISO name.

use crate::{
    disc::Disc,
    fsops::{natural_key, normalized, safe_component},
};
use serde::{Deserialize, Serialize};
use std::collections::BTreeSet;

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Series {
    pub name: String,
    /// The book's position, as the provider writes it (`8`, `2.5`); may be empty.
    pub sequence: String,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct Proposal {
    pub author: String,
    /// One or more narrators, separated by `, `.
    pub narrator: String,
    pub title: String,
    pub year: Option<i32>,
    pub category: String,
    pub release_id: String,
    pub publisher: String,
    pub disc_total: Option<u32>,
    /// What made the identity certain: `musicbrainz-disc-id`,
    /// `ripper-answer`, `folder-name`, or a pair of sources such as
    /// `spoken-credits+audible-runtime`. Empty while nothing has.
    pub confirmed_by: String,
    // The rest comes from a matching provider edition.
    #[serde(skip_serializing_if = "String::is_empty")]
    pub subtitle: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub series: Option<Series>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub description: String,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub asin: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub abridged: Option<bool>,
    #[serde(skip_serializing_if = "String::is_empty")]
    pub cover_url: String,
}

/// Why a set could not be settled from the ripper's own evidence.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum HoldKind {
    /// Nothing certain names the book; identification may still find it.
    Unidentified,
    /// The book is certain but nothing says how many discs it has.
    UnknownTotal,
    /// The evidence contradicts itself; only a person can settle it.
    Conflict,
}

#[derive(Debug, PartialEq)]
pub enum Decision {
    /// Publish the discs in this order (indexes into the input slice).
    Publish {
        proposal: Proposal,
        order: Vec<usize>,
    },
    /// Known book, discs still to come: stays in the inbox.
    Wait {
        proposal: Proposal,
        missing: Vec<u32>,
        message: String,
    },
    /// A person has to look, unless identification can settle `kind`:
    /// moves to `_NeedsIdentification`.
    Hold {
        kind: HoldKind,
        proposal: Option<Proposal>,
        reason: String,
    },
    /// Not this importer's business yet: left untouched in the inbox.
    Skip { message: String },
}

#[derive(Debug, PartialEq)]
pub struct NameClaim {
    pub author: String,
    pub title: String,
    pub year: Option<i32>,
    pub discs: Option<u32>,
}

/// Read `Author - Title (Year) [N discs]`; the year and disc tag are optional
/// and the ripper's `[mbid-…]` tag is ignored.
pub fn parse_folder_name(name: &str) -> Option<NameClaim> {
    let mut rest = name.trim();
    let mut discs = None;
    while rest.ends_with(']') {
        let open = rest.rfind('[')?;
        let tag = rest[open + 1..rest.len() - 1].trim().to_ascii_lowercase();
        if tag.starts_with("mbid-") {
        } else if let Some(count) = tag
            .strip_suffix(" discs")
            .or_else(|| tag.strip_suffix(" disc"))
        {
            discs = Some(
                count
                    .trim()
                    .parse::<u32>()
                    .ok()
                    .filter(|count| *count > 0)?,
            );
        } else {
            break;
        }
        rest = rest[..open].trim_end();
    }
    let mut year = None;
    if rest.ends_with(')')
        && let Some(open) = rest.rfind('(')
        && let Ok(value) = rest[open + 1..rest.len() - 1].parse::<i32>()
        && (1000..=2999).contains(&value)
    {
        year = Some(value);
        rest = rest[..open].trim_end();
    }
    let (author, title) = rest.split_once(" - ")?;
    let (author, title) = (author.trim(), title.trim());
    (!author.is_empty() && !title.is_empty()).then(|| NameClaim {
        author: author.to_string(),
        title: title.to_string(),
        year,
        discs,
    })
}

/// The folder name a person gives a held set to confirm it. Empty when
/// nothing names the book: a made-up "Author - Title" could be accepted by
/// mistake and published under that name.
pub fn confirming_name(proposal: Option<&Proposal>, present: usize) -> String {
    let (author, title, year) = match proposal {
        Some(proposal) if !proposal.author.is_empty() && !proposal.title.is_empty() => (
            proposal.author.as_str(),
            proposal.title.as_str(),
            proposal.year,
        ),
        _ => return String::new(),
    };
    let mut name = format!(
        "{} - {}",
        safe_component(&author.replace(" - ", " "), "Author"),
        safe_component(title, "Title")
    );
    if let Some(year) = year {
        name.push_str(&format!(" ({year})"));
    }
    let noun = if present == 1 { "disc" } else { "discs" };
    name.push_str(&format!(" [{present} {noun}]"));
    name
}

/// MusicBrainz credits audiobooks as "Author read by Narrator".
fn split_narrator(credit: &str) -> (String, String) {
    let lower = credit.to_lowercase();
    for marker in [" read by ", " narrated by ", ", read by ", " (read by "] {
        if let Some(index) = lower.find(marker)
            && credit.is_char_boundary(index)
            && credit.is_char_boundary(index + marker.len())
        {
            let author = credit[..index].trim().trim_end_matches(',').trim();
            let narrator = credit[index + marker.len()..]
                .trim()
                .trim_end_matches(')')
                .trim();
            if !author.is_empty() && !narrator.is_empty() {
                return (author.to_string(), narrator.to_string());
            }
        }
    }
    (credit.trim().to_string(), String::new())
}

fn common_year(discs: &[Disc]) -> Option<i32> {
    let mut years: Vec<i32> = discs.iter().filter_map(|disc| disc.year).collect();
    years.sort_unstable();
    let mut best: Option<(usize, i32)> = None;
    for year in &years {
        let count = years.iter().filter(|other| *other == year).count();
        if best.is_none_or(|(most, _)| count > most) {
            best = Some((count, *year));
        }
    }
    best.map(|(_, year)| year)
}

fn numbered_order(discs: &[Disc], total: u32) -> Option<Vec<usize>> {
    let mut seen = BTreeSet::new();
    let mut order: Vec<(u32, usize)> = Vec::new();
    for (index, disc) in discs.iter().enumerate() {
        let number = disc.disc_number.filter(|number| *number <= total)?;
        if !seen.insert(number) {
            return None;
        }
        order.push((number, index));
    }
    order.sort_unstable();
    Some(order.into_iter().map(|(_, index)| index).collect())
}

fn missing_numbers(discs: &[Disc], total: u32) -> Vec<u32> {
    let present: BTreeSet<u32> = discs.iter().filter_map(|disc| disc.disc_number).collect();
    (1..=total)
        .filter(|number| !present.contains(number))
        .collect()
}

fn list_numbers(numbers: &[u32]) -> String {
    numbers
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(", ")
}

/// What the discs themselves propose, before any certainty rule.
fn proposal_from_discs(discs: &[Disc]) -> Option<Proposal> {
    let first = discs.iter().min_by_key(|disc| {
        (
            disc.disc_number.unwrap_or(u32::MAX),
            natural_key(&disc.iso_name),
        )
    })?;
    if first.title.is_empty() {
        return None;
    }
    let (author, narrator) = split_narrator(&first.author);
    Some(Proposal {
        author,
        narrator,
        title: first.title.clone(),
        year: common_year(discs),
        category: first.category.clone(),
        release_id: first.release_id.clone(),
        publisher: first.publisher.clone(),
        disc_total: discs.iter().filter_map(|disc| disc.disc_total).max(),
        ..Proposal::default()
    })
}

/// Decide what to do with the discs in one folder.
pub fn decide(folder: &str, discs: &[Disc], marker_total: Option<u32>) -> Decision {
    if discs.is_empty() {
        return Decision::Hold {
            kind: HoldKind::Conflict,
            proposal: None,
            reason: "The folder holds no ISO.".to_string(),
        };
    }
    let from_discs = proposal_from_discs(discs);

    if let Some(claim) = parse_folder_name(folder)
        && let Some(total) = claim.discs
    {
        let (author, narrator) = split_narrator(&claim.author);
        let proposal = Proposal {
            author,
            narrator: if narrator.is_empty() {
                from_discs
                    .as_ref()
                    .map(|proposal| proposal.narrator.clone())
                    .unwrap_or_default()
            } else {
                narrator
            },
            title: claim.title,
            year: claim
                .year
                .or_else(|| from_discs.as_ref().and_then(|proposal| proposal.year)),
            category: "audiobook".to_string(),
            release_id: from_discs
                .as_ref()
                .map(|proposal| proposal.release_id.clone())
                .unwrap_or_default(),
            publisher: from_discs
                .as_ref()
                .map(|proposal| proposal.publisher.clone())
                .unwrap_or_default(),
            disc_total: Some(total),
            confirmed_by: "folder-name".to_string(),
            ..Proposal::default()
        };
        let present = discs.len() as u32;
        if present > total {
            return Decision::Hold {
                kind: HoldKind::Conflict,
                proposal: Some(proposal),
                reason: format!("The folder name says {total} discs but {present} are present."),
            };
        }
        if present < total {
            let message =
                format!("The folder name says {total} discs; {present} have arrived so far.");
            return Decision::Wait {
                proposal,
                missing: Vec::new(),
                message,
            };
        }
        let order = numbered_order(discs, total).unwrap_or_else(|| {
            let mut order: Vec<usize> = (0..discs.len()).collect();
            order.sort_by_key(|index| natural_key(&discs[*index].iso_name));
            order
        });
        return Decision::Publish { proposal, order };
    }

    let hold_as = |kind: HoldKind, reason: String| Decision::Hold {
        kind,
        proposal: from_discs.clone(),
        reason,
    };
    let hold = |reason: String| hold_as(HoldKind::Conflict, reason);

    let categories: BTreeSet<&str> = discs.iter().map(|disc| disc.category.as_str()).collect();
    if categories
        .iter()
        .all(|category| matches!(*category, "music" | "other"))
    {
        return Decision::Skip {
            message: "Music discs are not imported yet; they stay in the inbox.".to_string(),
        };
    }
    if categories.contains("unidentified") {
        return hold_as(
            HoldKind::Unidentified,
            "The disc was not identified: MusicBrainz has no exact match for it and nobody typed its author and title at the drive."
                .to_string(),
        );
    }
    if !categories
        .iter()
        .all(|category| matches!(*category, "audiobook" | "spoken-word"))
    {
        return hold(format!(
            "The ripper did not class every disc as an audiobook ({}).",
            categories.into_iter().collect::<Vec<_>>().join(", ")
        ));
    }

    if discs
        .iter()
        .any(|disc| disc.author.is_empty() || disc.title.is_empty())
    {
        return hold_as(
            HoldKind::Unidentified,
            "At least one disc has no author or title.".to_string(),
        );
    }
    let books: BTreeSet<(String, String)> = discs
        .iter()
        .map(|disc| (normalized(&disc.author), normalized(&disc.title)))
        .collect();
    if books.len() > 1 {
        let names: BTreeSet<String> = discs
            .iter()
            .map(|disc| format!("{} - {}", disc.author, disc.title))
            .collect();
        return hold(format!(
            "The discs in this folder name different books: {}.",
            names.into_iter().collect::<Vec<_>>().join("; ")
        ));
    }

    if let Some(disc) = discs
        .iter()
        .find(|disc| !disc.hint_applied && !disc.exact_match())
    {
        let status = if disc.lookup_status.is_empty() {
            "none"
        } else {
            &disc.lookup_status
        };
        return hold_as(
            HoldKind::Unidentified,
            format!(
                "{} is not an exact MusicBrainz Disc ID match (lookup: {status}) and nobody typed its author and title at the drive.",
                disc.iso_name
            ),
        );
    }

    let mut proposal = from_discs.clone().expect("discs have a title");
    proposal.confirmed_by = if discs.iter().any(|disc| disc.hint_applied) {
        "ripper-answer".to_string()
    } else {
        "musicbrainz-disc-id".to_string()
    };

    let mut totals: BTreeSet<u32> = discs.iter().filter_map(|disc| disc.disc_total).collect();
    totals.extend(marker_total);
    let total = match totals.len() {
        0 => {
            return Decision::Hold {
                kind: HoldKind::UnknownTotal,
                proposal: Some(proposal),
                reason: "The number of discs in this book is unknown.".to_string(),
            };
        }
        1 => *totals.iter().next().expect("one total"),
        _ => {
            return hold(format!(
                "The discs disagree about how many discs the book has ({}).",
                list_numbers(&totals.into_iter().collect::<Vec<_>>())
            ));
        }
    };
    let Some(order) = numbered_order(discs, total) else {
        return hold(format!(
            "The disc numbers are missing, repeated or above the total of {total}."
        ));
    };

    proposal.disc_total = Some(total);

    let missing = missing_numbers(discs, total);
    if !missing.is_empty() {
        let message = match missing.as_slice() {
            [one] => format!("Waiting for disc {one} of {total}."),
            [rest @ .., last] => format!(
                "Waiting for discs {} and {last} of {total}.",
                list_numbers(rest)
            ),
            [] => unreachable!("checked above"),
        };
        return Decision::Wait {
            proposal,
            missing,
            message,
        };
    }
    Decision::Publish { proposal, order }
}
