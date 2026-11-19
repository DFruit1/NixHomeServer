//! Small, dependency-free text helpers for matching titles and dialogue.

use std::collections::{HashMap, HashSet};

const STOPWORDS: &[&str] = &[
    "a", "about", "after", "again", "all", "also", "an", "and", "any", "are", "as", "at", "be",
    "been", "before", "but", "by", "can", "could", "did", "do", "does", "for", "from", "get",
    "got", "had", "has", "have", "he", "her", "here", "him", "his", "how", "i", "if", "in", "into",
    "is", "it", "its", "just", "know", "like", "me", "more", "my", "no", "not", "now", "of", "oh",
    "on", "one", "or", "our", "out", "she", "so", "some", "that", "the", "their", "them", "then",
    "there", "they", "this", "to", "too", "up", "us", "very", "was", "we", "well", "were", "what",
    "when", "where", "which", "who", "will", "with", "would", "yes", "you", "your", "yeah",
    "right", "go", "going", "gonna", "want", "think", "see", "come", "back", "only", "own", "over",
    "while", "than", "being", "two", "new", "time", "way",
];

/// Lower-case alphanumeric words; apostrophes are dropped so "James's" ≈ "jamess".
pub fn words(text: &str) -> Vec<String> {
    let mut out = Vec::new();
    let mut current = String::new();
    for ch in text.chars() {
        if ch.is_alphanumeric() {
            current.extend(ch.to_lowercase());
        } else if ch == '\'' || ch == '’' {
            continue;
        } else if !current.is_empty() {
            out.push(std::mem::take(&mut current));
        }
    }
    if !current.is_empty() {
        out.push(current);
    }
    out
}

/// Canonical comparison form: words joined by single spaces, "&" as "and",
/// and a leading article removed.
pub fn normalize(text: &str) -> String {
    let replaced = text.replace('&', " and ");
    let mut tokens = words(&replaced);
    if tokens.len() > 1 && matches!(tokens[0].as_str(), "the" | "a" | "an") {
        tokens.remove(0);
    }
    tokens.join(" ")
}

/// Bigrams over the normalized text, spaces included: two titles that use
/// the same letters differently ("Now Here Man" vs "Nowhere Man") share fewer
/// bigrams than titles written the same way.
fn bigrams(text: &str) -> Vec<(char, char)> {
    let chars: Vec<char> = text.chars().collect();
    chars.windows(2).map(|pair| (pair[0], pair[1])).collect()
}

/// Similarity in 0..=1 between two names: the better of character-bigram Dice
/// and word Jaccard on their normalized forms. OCR-ish slips ("Of" vs "of",
/// a dropped quote) stay close to 1.
pub fn similarity(left: &str, right: &str) -> f64 {
    let left = normalize(left);
    let right = normalize(right);
    if left.is_empty() || right.is_empty() {
        return 0.0;
    }
    if left == right {
        return 1.0;
    }
    // A volume label with its words run together still names the same show,
    // but only when one side is that single run-together token: two
    // multi-word titles that merely share letters are compared as written.
    let squashed = |text: &str| !text.contains(' ');
    if squashed(&left) != squashed(&right) && left.replace(' ', "") == right.replace(' ', "") {
        return 0.98;
    }
    let lb = bigrams(&left);
    let rb = bigrams(&right);
    let dice = if lb.is_empty() || rb.is_empty() {
        0.0
    } else {
        let mut counts: HashMap<(char, char), i32> = HashMap::new();
        for pair in &lb {
            *counts.entry(*pair).or_default() += 1;
        }
        let mut shared = 0;
        for pair in &rb {
            if let Some(count) = counts.get_mut(pair)
                && *count > 0
            {
                *count -= 1;
                shared += 1;
            }
        }
        2.0 * f64::from(shared) / (lb.len() + rb.len()) as f64
    };
    let lw: HashSet<&str> = left.split(' ').collect();
    let rw: HashSet<&str> = right.split(' ').collect();
    let jaccard = lw.intersection(&rw).count() as f64 / lw.union(&rw).count().max(1) as f64;
    dice.max(jaccard)
}

/// Content words (no stopwords, at least four characters).
pub fn content_words(text: &str) -> Vec<String> {
    words(text)
        .into_iter()
        .filter(|word| word.chars().count() >= 4 && !STOPWORDS.contains(&word.as_str()))
        .collect()
}

/// Share of the transcript's word trigrams that also occur in `reference`.
/// Automatic transcripts and subtitles word lines differently, but the
/// matching episode still shares far more trigrams than any other episode.
pub fn trigram_containment(transcript: &str, reference: &str) -> f64 {
    fn trigrams(text: &str) -> HashSet<(String, String, String)> {
        let tokens = words(text);
        tokens
            .windows(3)
            .map(|w| (w[0].clone(), w[1].clone(), w[2].clone()))
            .collect()
    }
    let spoken = trigrams(transcript);
    if spoken.is_empty() {
        return 0.0;
    }
    let reference = trigrams(reference);
    spoken.intersection(&reference).count() as f64 / spoken.len() as f64
}

/// IDF-weighted share of each summary's distinctive words heard in the
/// transcript. Returns one score per summary, in order.
pub fn keyword_scores(transcript: &str, summaries: &[String]) -> Vec<f64> {
    let heard: HashSet<String> = content_words(transcript).into_iter().collect();
    let documents: Vec<HashSet<String>> = summaries
        .iter()
        .map(|summary| content_words(summary).into_iter().collect())
        .collect();
    let mut frequency: HashMap<&str, usize> = HashMap::new();
    for document in &documents {
        for word in document {
            *frequency.entry(word.as_str()).or_default() += 1;
        }
    }
    let total = documents.len().max(1) as f64;
    documents
        .iter()
        .map(|document| {
            let weight = |word: &String| (total / frequency[word.as_str()] as f64).ln() + 0.1;
            let all: f64 = document.iter().map(weight).sum();
            if all == 0.0 {
                return 0.0;
            }
            let found: f64 = document
                .iter()
                .filter(|w| heard.contains(*w))
                .map(weight)
                .sum();
            found / all
        })
        .collect()
}

/// Remove HTML tags and decode the few entities TVmaze summaries use.
pub fn strip_html(text: &str) -> String {
    let mut out = String::with_capacity(text.len());
    let mut in_tag = false;
    for ch in text.chars() {
        match ch {
            '<' => in_tag = true,
            '>' => {
                in_tag = false;
                out.push(' ');
            }
            _ if !in_tag => out.push(ch),
            _ => {}
        }
    }
    out.replace("&amp;", "&")
        .replace("&quot;", "\"")
        .replace("&#39;", "'")
        .replace("&nbsp;", " ")
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ")
}

/// Truncate to at most `max` characters on a word boundary.
pub fn clip(text: &str, max: usize) -> String {
    if text.chars().count() <= max {
        return text.to_string();
    }
    let mut out: String = text.chars().take(max).collect();
    if let Some(space) = out.rfind(' ') {
        out.truncate(space);
    }
    out.push('…');
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn titles_match_through_case_quotes_and_articles() {
        assert!(similarity("\"Out Of Practice\"", "Out of Practice") > 0.99);
        assert!(similarity("The Last Furlong", "Last Furlong") > 0.99);
        assert!(similarity("Fair Means and Fowl", "Fair Means & Fowl") > 0.99);
        assert!(similarity("Horse Sense", "Dog Days") < 0.4);
        assert!(similarity("Allcreaturesgreatandsmall", "All Creatures Great and Small") > 0.95);
    }

    #[test]
    fn run_together_labels_match_but_reworded_titles_do_not_get_that_score() {
        // The 0.98 shortcut is for a squashed volume label against a
        // properly spaced title, one side a single run-together token.
        assert!(similarity("All Creatures Great and Small", "Allcreaturesgreatandsmall") > 0.95);
        // Same letters, differently worded titles are compared as written,
        // not treated as the same name.
        let reworded = similarity("Now Here Man", "Nowhere Man");
        assert!(reworded < 0.9, "{reworded}");
        assert!(reworded > 0.5, "{reworded}");
        // A partially merged OCR reading of the real title still matches,
        // because the bigram comparison now counts the spaces it keeps.
        assert!(similarity("Outof Practice", "Out of Practice") >= 0.85);
    }

    #[test]
    fn keyword_scores_prefer_the_summary_whose_names_are_heard() {
        let summaries = vec![
            "Siegfried hires Miss Harbottle, a meticulous secretary.".to_string(),
            "Tristan deals with pigs and James meets Helen.".to_string(),
        ];
        let heard = "We're gonna have a secretary. My name's Miss Harbottle.";
        let scores = keyword_scores(heard, &summaries);
        assert!(scores[0] > scores[1]);
    }

    #[test]
    fn trigram_containment_separates_matching_dialogue() {
        let spoken = "we are going to have a secretary called miss harbottle tomorrow";
        let same = "Siegfried: We are going to have a secretary called Miss Harbottle tomorrow.";
        let other = "Tristan, the pigs have escaped again and Helen is waiting outside.";
        assert!(trigram_containment(spoken, same) > 0.8);
        assert!(trigram_containment(spoken, other) < 0.1);
    }

    #[test]
    fn summaries_lose_markup() {
        assert_eq!(strip_html("<p>Tom &amp; Jerry</p>"), "Tom & Jerry");
    }
}
