//! Relations between search words: grammatical forms of one word, and curated
//! links between different words that people use for the same thing.
//!
//! Everything here widens what a query can *match*; none of it changes what
//! the user's own words mean. Callers weight a relation below the typed word,
//! keep it attached to the word it explains, and (for the indexed library)
//! drop relations the library does not contain before they reach a query.

/// Words whose final `s` is not a plural, plus irregulars that the suffix
/// rules below would damage ("news" must never become "new").
const INVARIANT: &[&str] = &[
    "news",
    "series",
    "species",
    "lens",
    "gas",
    "bias",
    "atlas",
    "canvas",
    "christmas",
    "jesus",
    "moses",
    "texas",
    "paris",
    "james",
    "thomas",
    "always",
    "perhaps",
    "this",
    "his",
    "its",
    "was",
    "has",
    "does",
    "is",
    "as",
    "us",
    "bus",
    "plus",
    "thus",
    "status",
    "virus",
    "census",
    "campus",
    "bonus",
    "focus",
    "corpus",
    "nexus",
    "analysis",
    "basis",
    "crisis",
    "thesis",
    "diagnosis",
    "physics",
    "mathematics",
    "maths",
    "economics",
    "politics",
    "electronics",
    "statistics",
    "ethics",
    "genesis",
    "exodus",
    "leviticus",
    "acts",
    "kings",
    "psalms",
    "proverbs",
    "corinthians",
    "galatians",
    "ephesians",
    "hebrews",
    "romans",
    "chaos",
    "cosmos",
    "glass",
    "class",
    "less",
    "address",
    "process",
    "access",
    "business",
    "express",
    "press",
    "wireless",
    "across",
    "progress",
    "success",
    "windows",
    "linux",
    "nixos",
    "kubernetes",
    "sms",
    "gps",
    "dns",
    "https",
    "aws",
    "ios",
    "macos",
    "tls",
    "cms",
    "rss",
    "css",
    "js",
    "during",
    "thing",
    "king",
    "ring",
    "spring",
    "string",
    "sing",
    "bring",
    "wing",
    "morning",
    "evening",
    "nothing",
    "something",
    "anything",
    "everything",
    "ceiling",
    "sibling",
    "wedding",
    "need",
    "seed",
    "feed",
    "speed",
    "bed",
    "red",
    "shed",
    "hundred",
    "sacred",
    "indeed",
];

fn plain_word(word: &str) -> bool {
    (3..=32).contains(&word.len()) && word.bytes().all(|byte| byte.is_ascii_lowercase())
}

fn is_vowel(byte: u8) -> bool {
    matches!(byte, b'a' | b'e' | b'i' | b'o' | b'u')
}

fn push_unique(forms: &mut Vec<String>, original: &str, candidate: String) {
    if candidate.len() >= 3 && candidate != original && !forms.contains(&candidate) {
        forms.push(candidate);
    }
}

/// Simpler dictionary forms of an inflected word: plural to singular, and
/// `-ing`/`-ed` verb forms to their stem. Suffix rules, not a dictionary, so a
/// result may be a non-word; the indexed path discards forms the library does
/// not contain. Returns nothing for short, non-ASCII or irregular words.
pub fn reduced_forms(word: &str) -> Vec<String> {
    let mut forms = singular_forms(word);
    for form in verb_stems(word) {
        if !forms.contains(&form) {
            forms.push(form);
        }
    }
    forms
}

/// The singular of a plural noun.
fn singular_forms(word: &str) -> Vec<String> {
    let mut forms = Vec::new();
    if !plain_word(word) || INVARIANT.contains(&word) {
        return forms;
    }
    let length = word.len();
    let stem = |cut: usize| word[..length - cut].to_string();
    if length > 4 && word.ends_with("ies") {
        push_unique(&mut forms, word, format!("{}y", stem(3)));
    } else if length > 4 && word.ends_with("ves") {
        push_unique(&mut forms, word, format!("{}f", stem(3)));
        push_unique(&mut forms, word, format!("{}fe", stem(3)));
        push_unique(&mut forms, word, stem(1));
    } else if length > 4 && (word.ends_with("xes") || word.ends_with("shes")) {
        push_unique(&mut forms, word, stem(2));
    } else if length > 4
        && (word.ends_with("ses") || word.ends_with("zes") || word.ends_with("ches"))
    {
        push_unique(&mut forms, word, stem(2));
        // "houses", "sizes", "caches": the singular keeps its final e.
        push_unique(&mut forms, word, stem(1));
    } else if length > 3
        && word.ends_with('s')
        && !word.ends_with("ss")
        && !word.ends_with("us")
        && !word.ends_with("is")
    {
        push_unique(&mut forms, word, stem(1));
    }
    forms
}

/// The stem of an `-ing` or `-ed` verb form.
fn verb_stems(word: &str) -> Vec<String> {
    let mut forms = Vec::new();
    if !plain_word(word) || INVARIANT.contains(&word) {
        return forms;
    }
    let length = word.len();
    let stem = |cut: usize| word[..length - cut].to_string();
    if length > 5 && word.ends_with("ing") {
        let base = stem(3);
        let base_bytes = base.as_bytes();
        let last = base_bytes[base_bytes.len() - 1];
        if base_bytes.len() >= 3 && last == base_bytes[base_bytes.len() - 2] && !is_vowel(last) {
            // running -> run, but filling -> fill stays available below.
            push_unique(&mut forms, word, base[..base.len() - 1].to_string());
        }
        push_unique(&mut forms, word, base.clone());
        push_unique(&mut forms, word, format!("{base}e"));
    } else if length > 4 && word.ends_with("ied") {
        push_unique(&mut forms, word, format!("{}y", stem(3)));
    } else if length >= 4 && word.ends_with("ed") {
        let base = stem(2);
        let base_bytes = base.as_bytes();
        let last = base_bytes[base_bytes.len() - 1];
        if base_bytes.len() >= 3 && last == base_bytes[base_bytes.len() - 2] && !is_vowel(last) {
            push_unique(&mut forms, word, base[..base.len() - 1].to_string());
        }
        push_unique(&mut forms, word, base);
        push_unique(&mut forms, word, stem(1));
    }
    forms
}

/// Longer forms of a base word: its plural and its `-ing`/`-ed` verb forms.
/// Speculative for nouns ("lawyering"), so callers keep these last and the
/// indexed path only uses the ones present in the library.
pub fn extended_forms(word: &str) -> Vec<String> {
    let mut forms = Vec::new();
    if !plain_word(word) || INVARIANT.contains(&word) {
        return forms;
    }
    let bytes = word.as_bytes();
    let length = word.len();
    let last = bytes[length - 1];
    let before = bytes[length - 2];
    // An inflected word already has its base in `reduced_forms`.
    let inflected = (word.ends_with('s') && !word.ends_with("ss"))
        || word.ends_with("ing")
        || word.ends_with("ed");
    if inflected {
        return forms;
    }
    if last == b'y' && !is_vowel(before) {
        push_unique(&mut forms, word, format!("{}ies", &word[..length - 1]));
    } else if matches!(last, b'x' | b'z') || word.ends_with("ch") || word.ends_with("sh") {
        push_unique(&mut forms, word, format!("{word}es"));
    } else {
        push_unique(&mut forms, word, format!("{word}s"));
    }
    if last == b'e' {
        push_unique(&mut forms, word, format!("{}ing", &word[..length - 1]));
        push_unique(&mut forms, word, format!("{word}d"));
    } else if last == b'y' && !is_vowel(before) {
        push_unique(&mut forms, word, format!("{word}ing"));
        push_unique(&mut forms, word, format!("{}ied", &word[..length - 1]));
    } else {
        push_unique(&mut forms, word, format!("{word}ing"));
        push_unique(&mut forms, word, format!("{word}ed"));
    }
    forms
}

/// Every grammatical form worth trying for a word, most reliable first.
pub fn word_forms(word: &str) -> Vec<String> {
    let mut forms = reduced_forms(word);
    for form in extended_forms(word) {
        if !forms.contains(&form) {
            forms.push(form);
        }
    }
    forms
}

/// The shortest plausible stem of a word, used for word-beginning matches so
/// "filters" also finds "filtering" and "filtration".
pub fn base_form(word: &str) -> String {
    reduced_forms(word)
        .into_iter()
        .filter(|form| form.len() >= 4)
        .min_by_key(String::len)
        .unwrap_or_else(|| word.to_string())
}

/// Interchangeable wording. Any member relates to every other member.
const FAMILIES: &[&[&str]] = &[
    // Media and formats
    &["movie", "film", "cinema"],
    &["tv", "television"],
    &["documentary", "doco", "docuseries"],
    &["cartoon", "animation", "animated"],
    &["comedy", "humour", "humor", "comic", "funny", "sitcom"],
    &["standup", "comedian", "comedy"],
    &["thriller", "suspense"],
    &["photo", "photograph", "photography", "picture", "image"],
    &["video", "footage", "clip", "recording"],
    &["music", "song", "album", "soundtrack"],
    &["audiobook", "narration", "narrated"],
    &["ebook", "epub", "book"],
    &["novel", "fiction"],
    &["magazine", "periodical", "journal"],
    &["article", "post", "essay"],
    &["newsletter", "bulletin", "digest"],
    &["manual", "handbook", "guide", "instructions"],
    &["tutorial", "howto", "walkthrough", "lesson"],
    &["subtitle", "caption", "subtitles", "captions"],
    // Money and paperwork
    &["invoice", "bill", "billing"],
    &["statement", "estatement"],
    &["receipt", "purchase", "order"],
    &["payment", "paid", "pay", "remittance"],
    &["refund", "reimbursement", "rebate"],
    &["quote", "quotation", "estimate"],
    &["salary", "payslip", "wage", "payroll"],
    &["tax", "taxation", "ato"],
    &["superannuation", "super", "pension"],
    &["insurance", "policy", "premium", "cover"],
    &["mortgage", "loan", "lending"],
    &["bank", "banking"],
    &["contract", "agreement"],
    &["lease", "rental", "tenancy", "rent"],
    &["warranty", "guarantee"],
    &["subscription", "membership", "renewal"],
    &["delivery", "shipping", "shipment", "dispatch", "courier"],
    &["parcel", "package"],
    &["resume", "cv"],
    &["certificate", "certification"],
    &["licence", "license", "permit"],
    &["rego", "registration"],
    // Utilities and home
    &["electricity", "power", "energy"],
    &["internet", "broadband", "nbn"],
    &["phone", "telephone", "mobile"],
    &["wifi", "wireless", "wlan"],
    &["house", "home", "property"],
    &["apartment", "unit", "flat"],
    &["repair", "fix", "repairs", "fixing", "maintenance"],
    &["plumber", "plumbing"],
    &["garden", "gardening", "horticulture"],
    &["cook", "cooking", "recipe", "culinary"],
    // Travel
    &["flight", "airline", "airfare", "itinerary", "boarding"],
    &["hotel", "accommodation", "lodging"],
    &["holiday", "vacation", "trip", "travel"],
    &["booking", "reservation"],
    &["ticket", "eticket"],
    &["car", "automobile", "vehicle"],
    &["bike", "bicycle", "cycling"],
    // Health and people
    &["doctor", "physician", "gp"],
    &["dentist", "dental"],
    &["medicine", "medication", "prescription"],
    &["hospital", "clinic"],
    &["lawyer", "solicitor", "attorney", "barrister"],
    &["kid", "child", "children"],
    &["wedding", "marriage"],
    &["job", "employment", "career"],
    &["meeting", "appointment"],
    // Technology
    &["computer", "computing", "pc"],
    &["laptop", "notebook"],
    &["tablet", "ipad"],
    &["software", "application", "app"],
    &["password", "passphrase", "credential"],
    &["backup", "backups", "restore"],
    &["database", "db"],
    &["network", "networking", "lan"],
    &["sensor", "probe", "transducer"],
    &["datalogger", "logger", "telemetry"],
    &["microcontroller", "mcu", "stm32"],
    &["solar", "photovoltaic", "pv"],
    &["circuit", "pcb", "schematic"],
    &["firmware", "embedded"],
    // Water, earth and science
    &["groundwater", "aquifer", "hydrogeology", "borehole"],
    &["filter", "filtration"],
    &["purification", "treatment", "purify", "disinfection"],
    &["sanitation", "hygiene"],
    &["rainwater", "rainfall", "rain"],
    &["flood", "flooding"],
    &["math", "maths", "mathematics"],
    &["chemistry", "chemical"],
    &["biology", "biological"],
    &["geology", "geological"],
    &["astronomy", "astrophysics", "cosmology"],
    &["evolution", "darwinism", "evolutionary"],
    &["creationism", "creationist"],
    &["climate", "weather"],
    // Faith and study
    &["bible", "scripture", "biblical"],
    &["church", "congregation"],
    &["christian", "christianity"],
    &["apologetics", "apologist"],
    &["theology", "theological", "doctrine"],
    &["prayer", "pray"],
    &["sermon", "preaching", "homily"],
    &["history", "historical"],
    &["archaeology", "archaeological", "archeology"],
    &["philosophy", "philosophical"],
    &["beginner", "introductory", "introduction", "basics"],
    &["course", "class", "training"],
    &["school", "education"],
    // Spelling variants
    &["colour", "color"],
    &["organisation", "organization"],
    &["behaviour", "behavior"],
    &["centre", "center"],
    &["programme", "program"],
    &["catalogue", "catalog"],
    &["analyse", "analyze"],
    &["email", "mail"],
];

/// One-way links from a word to wording that often accompanies the same
/// subject. Weaker than a family: "detective" suggests "mystery", but a search
/// for "mystery" should not pull in every detective.
const ASSOCIATIONS: &[(&str, &[&str])] = &[
    ("lawyer", &["legal", "law", "court"]),
    ("legal", &["law", "lawyer", "court"]),
    ("court", &["trial", "judge", "legal"]),
    ("detective", &["mystery", "crime", "sleuth", "investigator"]),
    ("mystery", &["detective", "crime"]),
    ("crime", &["detective", "police", "murder"]),
    ("police", &["crime", "detective"]),
    ("war", &["military", "battle", "army"]),
    ("space", &["astronomy", "nasa", "planet"]),
    ("animal", &["wildlife", "nature"]),
    ("nature", &["wildlife", "environment"]),
    ("bible", &["testament", "gospel"]),
    ("jesus", &["christ", "gospel"]),
    ("god", &["faith", "religion"]),
    ("religion", &["faith", "church"]),
    ("water", &["drinking", "hydro"]),
    ("filter", &["purification", "treatment"]),
    ("purification", &["filter", "filtration"]),
    ("pump", &["pumping", "borehole"]),
    ("well", &["borehole", "bore"]),
    ("farm", &["agriculture", "farming"]),
    ("fish", &["aquaculture", "aquaponic"]),
    ("food", &["nutrition", "cooking"]),
    ("health", &["medical", "wellbeing"]),
    ("medical", &["health", "doctor"]),
    ("money", &["finance", "financial", "budget"]),
    ("finance", &["financial", "money", "budget"]),
    ("bill", &["statement", "account", "due"]),
    ("creationism", &["creation"]),
    ("electricity", &["kwh", "usage"]),
    ("flight", &["airport", "departure"]),
    ("travel", &["flight", "hotel", "itinerary"]),
    ("house", &["mortgage", "strata", "settlement"]),
    ("job", &["position", "role", "recruitment"]),
    ("computer", &["laptop", "desktop"]),
    ("code", &["programming", "software"]),
    ("programming", &["code", "coding", "software"]),
    ("security", &["password", "authentication"]),
    ("kid", &["family", "school"]),
    ("funny", &["comedy", "humour"]),
    ("scary", &["horror", "thriller"]),
    ("romance", &["romantic", "love"]),
    ("action", &["adventure", "thriller"]),
    ("old", &["classic", "vintage"]),
    ("learn", &["tutorial", "course", "guide"]),
    ("build", &["construction", "assembly", "fabrication"]),
    ("install", &["installation", "setup"]),
    ("setup", &["installation", "configuration"]),
    ("error", &["failure", "fault", "problem"]),
    ("problem", &["issue", "fault", "error"]),
];

/// Most related words offered for one query word, across both tables.
pub const MAX_RELATED_PER_WORD: usize = 6;

/// Wording related to one word, strongest first. Never transitive: a related
/// word is not itself expanded, so a query cannot drift away from its subject.
pub fn related_to(word: &str) -> Vec<String> {
    // Only a plural shares its singular's relations. A verb form is a
    // different word: "booking" a flight has nothing to do with a "book".
    let mut keys = vec![word.to_string()];
    keys.extend(singular_forms(word));
    let mut related: Vec<String> = Vec::new();
    let add = |candidate: &str, related: &mut Vec<String>| {
        if related.len() < MAX_RELATED_PER_WORD
            && !keys.iter().any(|key| key == candidate)
            && !related.iter().any(|existing| existing == candidate)
        {
            related.push(candidate.to_string());
        }
    };
    for family in FAMILIES {
        if keys.iter().any(|key| family.contains(&key.as_str())) {
            for member in *family {
                add(member, &mut related);
            }
        }
    }
    for (head, linked) in ASSOCIATIONS {
        if keys.iter().any(|key| key == head) {
            for member in *linked {
                add(member, &mut related);
            }
        }
    }
    related
}
