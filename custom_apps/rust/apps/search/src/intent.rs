//! Conservative English query instructions: what kind of thing is wanted, who
//! made or sent it, when it is from, and whether the newest should come first.
//!
//! Quoted titles and explicit search syntax stay literal. Every inferred filter
//! is reported back as a visible, removable suggestion, never hidden state; a
//! filter the user removed leaves its words in the query untouched.
use std::collections::BTreeMap;

use chrono::{Datelike, Duration, NaiveDate};

#[derive(Debug, Default)]
pub(crate) struct Intent {
    pub query: String,
    pub filters: BTreeMap<String, String>,
}

#[derive(Debug, Clone)]
struct Token {
    original: String,
    lower: String,
}

fn tokens(text: &str) -> Vec<Token> {
    text.split_whitespace()
        .map(|word| Token {
            original: word.to_string(),
            lower: word
                .trim_matches(|ch: char| matches!(ch, '?' | '!' | ',' | ';'))
                .trim_end_matches('.')
                .to_lowercase(),
        })
        .collect()
}

fn starts_with(tokens: &[Token], phrase: &[&str]) -> bool {
    tokens.len() >= phrase.len()
        && phrase
            .iter()
            .zip(tokens)
            .all(|(word, token)| token.lower == *word)
}

/// Requests to the search itself. Longest first so "show me" wins over "show".
const COMMANDS: &[&[&str]] = &[
    &["can", "you", "show", "me"],
    &["could", "you", "show", "me"],
    &["can", "you", "find", "me"],
    &["i", "am", "looking", "for"],
    &["do", "we", "have", "any"],
    &["do", "i", "have", "any"],
    &["can", "you", "find"],
    &["could", "you", "find"],
    &["please", "show", "me"],
    &["i'm", "looking", "for"],
    &["i’m", "looking", "for"],
    &["im", "looking", "for"],
    &["are", "there", "any"],
    &["is", "there", "any"],
    &["is", "there", "a"],
    &["do", "we", "have"],
    &["do", "i", "have"],
    &["please", "find"],
    &["show", "me"],
    &["find", "me"],
    &["search", "for"],
    &["look", "for"],
    &["looking", "for"],
    &["get", "me"],
    &["give", "me"],
    &["i", "want"],
    &["i", "need"],
    &["find"],
    &["show"],
];

/// Commands that are also ordinary words; only an instruction when a kind of
/// content follows ("list my emails", not "list of prime numbers").
const WEAK_COMMANDS: &[&[&str]] = &[&["list", "all"], &["list"], &["any"]];

const DETERMINERS: &[&str] = &["all", "the", "my", "any", "some", "a", "an", "our", "every"];

/// A leading or trailing noun naming a kind of content.
struct KindNoun {
    words: &'static [&'static str],
    kind: &'static str,
    /// The singular is too ordinary a word to act on without a relation
    /// ("book of kells", "video card").
    plural: bool,
    /// Also a subject word ("documentaries"): filter by kind, keep the word.
    keep: bool,
    /// Safe to read as an instruction at the end of a query ("comedy movies").
    trailing: bool,
}

const fn noun(
    words: &'static [&'static str],
    kind: &'static str,
    plural: bool,
    trailing: bool,
) -> KindNoun {
    KindNoun {
        words,
        kind,
        plural,
        keep: false,
        trailing,
    }
}

const KIND_NOUNS: &[KindNoun] = &[
    noun(&["tv", "shows"], "episode", true, true),
    noun(&["tv", "show"], "episode", true, true),
    noun(&["tv", "series"], "episode", true, true),
    noun(&["tv", "episodes"], "episode", true, true),
    noun(&["television", "shows"], "episode", true, true),
    noun(&["television", "series"], "episode", true, true),
    noun(&["web", "pages"], "web-page", true, true),
    noun(&["audiobooks"], "audiobook", true, true),
    noun(&["audiobook"], "audiobook", false, true),
    noun(&["ebooks"], "book", true, true),
    noun(&["ebook"], "book", false, true),
    noun(&["books"], "book", true, true),
    noun(&["book"], "book", false, false),
    noun(&["emails"], "email", true, true),
    noun(&["email"], "email", false, true),
    noun(&["e-mails"], "email", true, true),
    noun(&["messages"], "email", true, false),
    noun(&["message"], "email", false, false),
    noun(&["mail"], "email", false, false),
    noun(&["movies"], "movie", true, true),
    noun(&["movie"], "movie", false, true),
    noun(&["films"], "movie", true, true),
    noun(&["film"], "movie", false, false),
    noun(&["episodes"], "episode", true, true),
    noun(&["episode"], "episode", false, false),
    noun(&["shows"], "episode", true, true),
    noun(&["series"], "episode", true, true),
    noun(&["videos"], "video", true, true),
    noun(&["video"], "video", false, true),
    noun(&["documents"], "document", true, true),
    noun(&["document"], "document", false, false),
    noun(&["articles"], "web-page", true, true),
    noun(&["article"], "web-page", false, false),
    noun(&["webpages"], "web-page", true, true),
    KindNoun {
        words: &["documentaries"],
        kind: "video",
        plural: true,
        keep: true,
        trailing: true,
    },
    KindNoun {
        words: &["documentary"],
        kind: "video",
        plural: false,
        keep: true,
        trailing: true,
    },
];

/// "time series", "world series": a trailing "series" after these words is a
/// subject, not a request for television.
const SERIES_SUBJECTS: &[&str] = &[
    "time", "fourier", "taylor", "power", "world", "data", "number", "harmonic", "book", "lecture",
    "sermon", "the", "a", "this",
];

const RELATIONS: &[&str] = &[
    "by",
    "from",
    "about",
    "written",
    "directed",
    "narrated",
    "authored",
    "sent",
    "regarding",
    "on",
    "with",
    "in",
    "during",
    "since",
    "before",
    "after",
    "last",
    "this",
];

const TOPIC_LEADS: &[&[&str]] = &[
    &["on", "the", "topic", "of"],
    &["to", "do", "with"],
    &["that", "mention"],
    &["that", "mentions"],
    &["related", "to"],
    &["about"],
    &["regarding"],
    &["concerning"],
    &["mentioning"],
    &["containing"],
];

const MONTHS: &[(&str, u32)] = &[
    ("january", 1),
    ("jan", 1),
    ("february", 2),
    ("feb", 2),
    ("march", 3),
    ("mar", 3),
    ("april", 4),
    ("apr", 4),
    ("may", 5),
    ("june", 6),
    ("jun", 6),
    ("july", 7),
    ("jul", 7),
    ("august", 8),
    ("aug", 8),
    ("september", 9),
    ("sep", 9),
    ("sept", 9),
    ("october", 10),
    ("oct", 10),
    ("november", 11),
    ("nov", 11),
    ("december", 12),
    ("dec", 12),
];

fn parse_year(word: &str, today: NaiveDate) -> Option<i32> {
    if word.len() != 4 || !word.bytes().all(|byte| byte.is_ascii_digit()) {
        return None;
    }
    let year: i32 = word.parse().ok()?;
    (1900..=today.year() + 1).contains(&year).then_some(year)
}

/// "90s", "1990s", "'90s": the first year of the decade.
fn parse_decade(word: &str, today: NaiveDate) -> Option<i32> {
    let digits = word
        .trim_start_matches(['\'', '’'])
        .strip_suffix('s')
        .or_else(|| word.strip_suffix("'s"))?;
    if !digits.bytes().all(|byte| byte.is_ascii_digit()) || !digits.ends_with('0') {
        return None;
    }
    let decade = match digits.len() {
        4 => digits.parse::<i32>().ok()?,
        2 => {
            let short: i32 = digits.parse().ok()?;
            // A two-digit decade is the most recent one that has started.
            if 2000 + short <= today.year() {
                2000 + short
            } else {
                1900 + short
            }
        }
        _ => return None,
    };
    (1900..=today.year()).contains(&decade).then_some(decade)
}

fn first_of_month(year: i32, month: u32) -> Option<NaiveDate> {
    NaiveDate::from_ymd_opt(year, month, 1)
}

fn last_of_month(year: i32, month: u32) -> Option<NaiveDate> {
    let (next_year, next_month) = if month == 12 {
        (year + 1, 1)
    } else {
        (year, month + 1)
    };
    Some(first_of_month(next_year, next_month)? - Duration::days(1))
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct DateRange {
    after: Option<NaiveDate>,
    before: Option<NaiveDate>,
}

fn range(after: Option<NaiveDate>, before: Option<NaiveDate>) -> Option<DateRange> {
    (after.is_some() || before.is_some()).then_some(DateRange { after, before })
}

const DATE_PREPOSITIONS: &[&str] = &[
    "from", "in", "during", "since", "for", "over", "within", "of", "after", "before", "until",
    "between",
];

/// Recognises a date expression starting at `tokens[0]`. Returns the range,
/// how many tokens it used, and whether it needed no preposition to be clear.
fn date_at(tokens: &[Token], today: NaiveDate) -> Option<(DateRange, usize, bool)> {
    let word = |index: usize| tokens.get(index).map(|token| token.lower.as_str());
    let year_start = |year: i32| NaiveDate::from_ymd_opt(year, 1, 1);
    let year_end = |year: i32| NaiveDate::from_ymd_opt(year, 12, 31);

    // between 2019 and 2021 / from 2019 to 2021
    if let (Some(lead), Some(first), Some(link), Some(second)) =
        (word(0), word(1), word(2), word(3))
        && ((lead == "between" && link == "and") || (lead == "from" && link == "to"))
        && let (Some(first), Some(second)) = (parse_year(first, today), parse_year(second, today))
        && first <= second
    {
        return Some((range(year_start(first), year_end(second))?, 4, true));
    }

    let (offset, preposition) = match word(0) {
        Some(lead) if DATE_PREPOSITIONS.contains(&lead) && lead != "between" => (1, Some(lead)),
        _ => (0, None),
    };
    let mut at = offset;
    let article = word(at) == Some("the");
    if article {
        at += 1;
    }
    let first = word(at)?;

    // the last 3 months / past 2 weeks
    if matches!(first, "last" | "past")
        && let Some(count) = word(at + 1).and_then(|value| value.parse::<i64>().ok())
        && (1..=120).contains(&count)
        && let Some(unit) = word(at + 2)
    {
        let days = match unit {
            "day" | "days" => count,
            "week" | "weeks" => count * 7,
            "month" | "months" => count * 30,
            "year" | "years" => count * 365,
            _ => 0,
        };
        if days > 0 {
            return Some((
                range(Some(today - Duration::days(days)), Some(today))?,
                at + 3,
                true,
            ));
        }
    }

    // last year / this month / past week
    if !article
        && matches!(first, "last" | "this" | "past")
        && let Some(unit) = word(at + 1)
    {
        let found = match (first, unit) {
            ("this", "year") => range(year_start(today.year()), year_end(today.year())),
            ("last", "year") => range(year_start(today.year() - 1), year_end(today.year() - 1)),
            ("past", "year") => range(Some(today - Duration::days(365)), Some(today)),
            ("this", "month") => range(
                first_of_month(today.year(), today.month()),
                last_of_month(today.year(), today.month()),
            ),
            ("last", "month") => {
                let (year, month) = if today.month() == 1 {
                    (today.year() - 1, 12)
                } else {
                    (today.year(), today.month() - 1)
                };
                range(first_of_month(year, month), last_of_month(year, month))
            }
            ("past", "month") => range(Some(today - Duration::days(30)), Some(today)),
            ("this", "week") | ("last", "week") => {
                let monday =
                    today - Duration::days(i64::from(today.weekday().num_days_from_monday()));
                let start = if first == "last" {
                    monday - Duration::days(7)
                } else {
                    monday
                };
                range(Some(start), Some(start + Duration::days(6)))
            }
            ("past", "week") => range(Some(today - Duration::days(7)), Some(today)),
            _ => None,
        };
        if let Some(found) = found {
            return Some((found, at + 2, true));
        }
    }

    if !article && matches!(first, "today" | "yesterday") {
        let day = if first == "today" {
            today
        } else {
            today - Duration::days(1)
        };
        return Some((range(Some(day), Some(day))?, at + 1, false));
    }

    // march 2024
    if !article
        && let Some((_, month)) = MONTHS.iter().find(|(name, _)| *name == first)
        && let Some(year) = word(at + 1).and_then(|value| parse_year(value, today))
    {
        return Some((
            range(first_of_month(year, *month), last_of_month(year, *month))?,
            at + 2,
            preposition.is_some(),
        ));
    }

    // the 90s
    if let Some(decade) = parse_decade(first, today) {
        return Some((
            range(year_start(decade), year_end(decade + 9))?,
            at + 1,
            preposition.is_some() || article,
        ));
    }

    // in 2024 / since 2020 / before 2019. A bare year is left to the caller.
    if !article && let Some(year) = parse_year(first, today) {
        let found = match preposition {
            Some("since") => range(year_start(year), None),
            Some("after") => range(year_start(year + 1), None),
            Some("before") => range(None, year_end(year - 1)),
            Some("until") => range(None, year_end(year)),
            _ => range(year_start(year), year_end(year)),
        };
        return Some((found?, at + 1, preposition.is_some()));
    }
    None
}

fn explicit_syntax(original: &str) -> bool {
    original.starts_with('"')
        || original.contains([':', '*', '~', '^', '[', ']', '(', ')'])
        || original
            .split_whitespace()
            .any(|word| matches!(word, "AND" | "OR" | "NOT") || word.starts_with(['-', '+']))
}

fn join(tokens: &[Token]) -> String {
    tokens
        .iter()
        .map(|token| token.original.as_str())
        .collect::<Vec<_>>()
        .join(" ")
}

/// Interprets `raw` as of `today`. `ignored` names inferred filters the user
/// has removed; their words then stay in the query as ordinary search terms.
pub(crate) fn parse(raw: &str, today: NaiveDate, ignored: &dyn Fn(&str) -> bool) -> Intent {
    let original = raw.trim();
    let mut out = Intent {
        query: original.into(),
        ..Default::default()
    };
    if explicit_syntax(original) {
        return out;
    }
    let mut rest = tokens(original);
    if rest.is_empty() || rest.len() > 24 {
        return out;
    }

    // 1. A request addressed to the search itself.
    let mut command = false;
    if let Some(phrase) = COMMANDS.iter().find(|phrase| starts_with(&rest, phrase))
        && rest.len() > phrase.len()
    {
        rest.drain(..phrase.len());
        command = true;
    }
    let leading_kind = |tokens: &[Token], skip: usize| -> Option<&'static KindNoun> {
        KIND_NOUNS
            .iter()
            .find(|noun| starts_with(&tokens[skip.min(tokens.len())..], noun.words))
    };
    let determiners = |tokens: &[Token]| -> usize {
        tokens
            .iter()
            .take_while(|token| DETERMINERS.contains(&token.lower.as_str()))
            .count()
    };
    if !command
        && let Some(phrase) = WEAK_COMMANDS
            .iter()
            .find(|phrase| starts_with(&rest, phrase))
    {
        let after = &rest[phrase.len()..];
        if leading_kind(after, determiners(after)).is_some() {
            rest.drain(..phrase.len());
            command = true;
        }
    }

    // 2. "latest ...", "most recent ...": newest first.
    let sort_ignored = ignored("sort");
    let skip = determiners(&rest);
    let sort_words = if starts_with(&rest[skip..], &["most", "recent"]) {
        2
    } else if rest
        .get(skip)
        .is_some_and(|token| matches!(token.lower.as_str(), "latest" | "newest" | "recent"))
    {
        1
    } else {
        0
    };
    if sort_words > 0 && rest.len() > skip + sort_words && !sort_ignored {
        rest.drain(skip..skip + sort_words);
        out.filters.insert("sort".into(), "newest".into());
    }

    // 3. A leading kind of content: "movies about ...", "find a book by ...".
    let kind_ignored = ignored("kind");
    let mut kind: Option<&'static KindNoun> = None;
    let skip = determiners(&rest);
    if !kind_ignored && let Some(noun) = leading_kind(&rest, skip) {
        let following = rest
            .get(skip + noun.words.len())
            .map(|token| token.lower.as_str());
        let relation = following.is_some_and(|word| RELATIONS.contains(&word));
        let instruction = command
            || out.filters.contains_key("sort")
            || relation
            || (noun.plural && following.is_some());
        // A bare noun is also a possible title; only act on a clear request.
        if instruction && (following.is_some() || command) {
            if noun.keep {
                rest.drain(..skip);
            } else {
                rest.drain(..skip + noun.words.len());
            }
            kind = Some(noun);
        }
    }

    // 4. When it is from. Relative dates and years need a preposition, an
    // instruction, or to close the query; a title that merely contains a year
    // is never reinterpreted.
    let date_ignored = ignored("after") || ignored("before");
    if !date_ignored {
        let instruction = command || kind.is_some();
        let mut index = 0;
        while index < rest.len() {
            let Some((found, used, clear)) = date_at(&rest[index..], today) else {
                index += 1;
                continue;
            };
            let closes = index + used == rest.len();
            let prepositioned = DATE_PREPOSITIONS.contains(&rest[index].lower.as_str());
            let topic =
                index > 0 && matches!(rest[index - 1].lower.as_str(), "about" | "regarding" | "on");
            let leaves_words = rest.len() > used || instruction;
            let accepted = !topic
                && leaves_words
                && ((clear && (closes || instruction))
                    || (prepositioned && (closes || instruction))
                    || (instruction && closes && index > 0)
                    || (instruction && closes && kind.is_some()));
            if !accepted {
                index += 1;
                continue;
            }
            rest.drain(index..index + used);
            if let Some(after) = found.after {
                out.filters
                    .insert("after".into(), after.format("%Y-%m-%d").to_string());
            }
            if let Some(before) = found.before {
                out.filters
                    .insert("before".into(), before.format("%Y-%m-%d").to_string());
            }
            break;
        }
    }

    // 5. A trailing kind of content: "comedy movies", "rumpole episodes".
    if kind.is_none()
        && !kind_ignored
        && rest.len() >= 2
        && let Some(noun) = KIND_NOUNS.iter().find(|noun| {
            noun.trailing
                && rest.len() > noun.words.len()
                && starts_with(&rest[rest.len() - noun.words.len()..], noun.words)
        })
    {
        let before = rest[rest.len() - noun.words.len() - 1].lower.as_str();
        let subject = noun.words == ["series"] && SERIES_SUBJECTS.contains(&before);
        // "movies by", "books about": the noun is mid-sentence, not a request.
        if !subject && !RELATIONS.contains(&before) {
            if !noun.keep {
                rest.truncate(rest.len() - noun.words.len());
            }
            kind = Some(noun);
        }
    }
    if let Some(noun) = kind {
        out.filters.insert("kind".into(), noun.kind.into());
    }

    // 6. Who made or sent it.
    if !ignored("creator") {
        let made_by = |tokens: &[Token], index: usize| {
            matches!(
                tokens[index].lower.as_str(),
                "written" | "directed" | "narrated" | "authored" | "sent" | "composed" | "created"
            ) && tokens
                .get(index + 1)
                .is_some_and(|token| token.lower == "by")
        };
        let email = kind.is_some_and(|noun| noun.kind == "email");
        let relation = (0..rest.len()).find_map(|index| {
            let word = rest[index].lower.as_str();
            if made_by(&rest, index) {
                Some((index, 2))
            } else if (kind.is_some() && word == "by") || (email && word == "from") {
                Some((index, 1))
            } else {
                None
            }
        });
        if let Some((index, words)) = relation {
            let start = index + words;
            let end = (start..rest.len())
                .find(|&at| {
                    TOPIC_LEADS
                        .iter()
                        .any(|lead| starts_with(&rest[at..], lead))
                        || matches!(rest[at].lower.as_str(), "with" | "on")
                        // A date the user chose to keep as words still ends the name.
                        || date_at(&rest[at..], today).is_some()
                })
                .unwrap_or(rest.len());
            let creator = join(&rest[start..end]);
            let creator = creator
                .trim()
                .trim_matches('"')
                .trim_end_matches(['?', '!']);
            if !creator.is_empty() && end - start <= 6 && creator.chars().count() <= 160 {
                out.filters.insert("creator".into(), creator.into());
                rest.drain(index..end);
            }
        }
    }

    // 7. "about ...": the subject follows.
    let instruction = command || !out.filters.is_empty();
    if instruction && let Some(lead) = TOPIC_LEADS.iter().find(|lead| starts_with(&rest, lead)) {
        rest.drain(..lead.len());
    }
    if !instruction {
        // Nothing was understood as an instruction: search exactly as typed.
        return out;
    }
    out.query = join(&rest).trim_end_matches(['?', '!']).trim().to_string();
    out
}
