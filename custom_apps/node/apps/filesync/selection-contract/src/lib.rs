//! Filesync selection contract v1 — Rust reference dialect.
//!
//! This crate is a dormant, non-persisted reference implementation of the
//! selection contract proposed for filesync presets and pairs. Nothing in the
//! filesync app, the native plugin or the API imports it; it exists so the
//! decoder, the extension semantics and the matcher can be tested on their own.
//!
//! # Contract v1
//!
//! A selection is either the explicit ABSENT sentinel or a raw JSON document
//! with exactly these four required members in any order:
//!
//! ```text
//! {"version":1,"dialect":"rust-regex-1","filenameRegex":"","extension":""}
//! ```
//!
//! - `version` is the integer `1`. Booleans, strings, floats, negative numbers,
//!   `null` and unknown integers are errors.
//! - `dialect` is exactly `rust-regex-1`.
//! - `filenameRegex` and `extension` are strings.
//!
//! Parsing is strict. Present `null`, malformed JSON, missing, duplicate,
//! unknown or wrongly typed members, an unknown version or dialect and an
//! invalid regex are errors. Raw text is parsed directly; a duplicate member is
//! reported, never silently collapsed. An error never degrades into an
//! all-files selection.
//!
//! # States
//!
//! - ABSENT decodes to [`SelectionState::LegacyAll`]; it encodes back to
//!   absence, never to `null` or an empty object.
//! - A valid object with no effective constraint (empty regex and an empty or
//!   whitespace-only extension) decodes to [`SelectionState::ExplicitAll`].
//! - Any effective regex or extension constraint decodes to
//!   [`SelectionState::Constrained`].
//!
//! `LegacyAll` and `ExplicitAll` both select every valid basename, but their
//! state tags stay distinguishable.
//!
//! # Match semantics
//!
//! - `filenameRegex` is used unchanged (no trimming) with `regex` 1.13.1
//!   string `is_match` (search) semantics: case-sensitive by default, Unicode
//!   enabled, non-multiline, `.` excludes newline, ordinary whitespace is
//!   significant and inline flags (`(?i)` and friends) are honoured. This is
//!   Rust regex syntax; JavaScript or JVM syntax equivalence is not claimed.
//!   Look-around and backreferences are rejected by the engine and surface as
//!   decoder errors.
//! - `extension` is a single suffix, not a list, glob or comma language. ASCII
//!   space, tab, CR and LF are trimmed at both ends, at most one leading dot is
//!   removed and the remainder is ASCII-lowercased. Blank input means no
//!   extension constraint; a lone dot is invalid. A non-empty suffix must be
//!   1..=32 ASCII letters, digits, underscores or hyphens.
//! - Both constraints apply with AND; a missing constraint is always true.
//! - Candidates are already-extracted final FILE basenames, not paths or URIs.
//!   Empty, NUL-containing, slash-containing, `.` and `..` candidates are
//!   errors. A basename carries an extension only when its final dot is neither
//!   its first nor its last character. Case folding is ASCII-only; Unicode
//!   normalization and Unicode case folding are not performed.
//!
//! # Limits
//!
//! Patterns are limited to [`MAX_PATTERN_BYTES`] UTF-8 bytes, compiled regex
//! size and DFA cache to [`REGEX_SIZE_LIMIT`] bytes each and parser nesting to
//! [`REGEX_NEST_LIMIT`]. Breaching a limit is an error. The limits are not
//! disabled and no wall-clock latency bound is implied by the engine's
//! complexity statement.
//!
//! # Non-goals
//!
//! There is no wire-compatibility promise, no portable JS/JVM subset, no
//! Android implementation, no min-reader barrier, no store access, no
//! migration and no UI. A future public adoption needs its own enabling plan.

use std::cell::RefCell;
use std::fmt;

use regex::{Regex, RegexBuilder};
use serde::de::{DeserializeSeed, Error as DeError, MapAccess, Visitor};
use serde_json::error::Category;
use serde_json::Value;

/// The only accepted contract `version` value.
pub const CONTRACT_VERSION: u64 = 1;
/// The only accepted contract `dialect` value.
pub const DIALECT: &str = "rust-regex-1";
/// Maximum `filenameRegex` length in UTF-8 bytes.
pub const MAX_PATTERN_BYTES: usize = 1024;
/// Maximum candidate basename length in UTF-8 bytes.
pub const MAX_BASENAME_BYTES: usize = 4096;
/// Maximum canonical extension length in ASCII bytes.
pub const MAX_EXTENSION_BYTES: usize = 32;
/// Maximum regex parser nesting depth.
pub const REGEX_NEST_LIMIT: u32 = 32;
/// Compiled regex size limit in bytes.
pub const REGEX_SIZE_LIMIT: usize = 1024 * 1024;
/// Lazy DFA cache size limit in bytes.
pub const REGEX_DFA_SIZE_LIMIT: usize = 1024 * 1024;

/// Decoder input: the explicit ABSENT sentinel or raw JSON text.
///
/// Absence is never represented as JSON `null`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum DecodeInput<'a> {
    /// No selection was stored at all.
    Absent,
    /// Raw, undecoded JSON text.
    Raw(&'a str),
}

/// The closed set of selection states distinguishable in this library.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum SelectionState {
    /// No stored selection; legacy all-files behaviour.
    LegacyAll,
    /// A stored selection without an effective constraint.
    ExplicitAll,
    /// A stored selection with at least one effective constraint.
    Constrained,
}

impl SelectionState {
    /// Stable tag used by the corpus and by callers that log state.
    pub fn tag(self) -> &'static str {
        match self {
            Self::LegacyAll => "legacy-all",
            Self::ExplicitAll => "explicit-all",
            Self::Constrained => "constrained",
        }
    }
}

/// Kind of pair a selection is being resolved for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum PairKind {
    /// A new preset-backed pair.
    NewPreset,
    /// A new manual pair.
    NewManual,
    /// An existing pair, which keeps whatever it stored.
    Existing,
}

/// Structured selection error. `class()` is the stable corpus-facing code.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum SelectionError {
    /// The raw text was not valid JSON.
    MalformedJson(String),
    /// Valid JSON that is not an object.
    NotAnObject,
    /// Present JSON `null`.
    PresentNull,
    /// The same member appeared twice.
    DuplicateMember(&'static str),
    /// A required member is missing.
    MissingMember(&'static str),
    /// A member outside the contract appeared.
    UnknownMember(String),
    /// A member had the wrong JSON type.
    WrongType(&'static str),
    /// `version` was an integer other than `1`.
    UnknownVersion(String),
    /// `dialect` was a string other than the supported dialect.
    UnknownDialect(String),
    /// The pattern exceeded [`MAX_PATTERN_BYTES`].
    PatternTooLong(usize),
    /// The engine refused the pattern for a resource limit.
    PatternResourceLimit(String),
    /// The engine refused the pattern as invalid syntax.
    InvalidRegex(String),
    /// The extension was not a single valid suffix.
    InvalidExtension(String),
    /// The candidate was not an acceptable final basename.
    InvalidBasename(String),
    /// The candidate exceeded [`MAX_BASENAME_BYTES`].
    BasenameTooLong(usize),
}

impl SelectionError {
    /// Stable, corpus-facing error class.
    pub fn class(&self) -> &'static str {
        match self {
            Self::MalformedJson(_) => "malformed-json",
            Self::NotAnObject => "not-an-object",
            Self::PresentNull => "present-null",
            Self::DuplicateMember(_) => "duplicate-member",
            Self::MissingMember(_) => "missing-member",
            Self::UnknownMember(_) => "unknown-member",
            Self::WrongType(_) => "wrong-type",
            Self::UnknownVersion(_) => "unknown-version",
            Self::UnknownDialect(_) => "unknown-dialect",
            Self::PatternTooLong(_) => "pattern-too-long",
            Self::PatternResourceLimit(_) => "pattern-resource-limit",
            Self::InvalidRegex(_) => "invalid-regex",
            Self::InvalidExtension(_) => "invalid-extension",
            Self::InvalidBasename(_) => "invalid-basename",
            Self::BasenameTooLong(_) => "basename-too-long",
        }
    }
}

impl fmt::Display for SelectionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::MalformedJson(detail) => write!(f, "malformed selection JSON: {detail}"),
            Self::NotAnObject => f.write_str("selection JSON must be an object"),
            Self::PresentNull => f.write_str("present selection must not be null"),
            Self::DuplicateMember(name) => write!(f, "duplicate selection member {name}"),
            Self::MissingMember(name) => write!(f, "missing selection member {name}"),
            Self::UnknownMember(name) => write!(f, "unknown selection member {name}"),
            Self::WrongType(name) => write!(f, "wrong JSON type for selection member {name}"),
            Self::UnknownVersion(value) => write!(f, "unsupported selection version {value}"),
            Self::UnknownDialect(value) => write!(f, "unsupported selection dialect {value}"),
            Self::PatternTooLong(len) => {
                write!(f, "pattern is {len} bytes; limit is {MAX_PATTERN_BYTES}")
            }
            Self::PatternResourceLimit(detail) => {
                write!(f, "pattern exceeded an engine resource limit: {detail}")
            }
            Self::InvalidRegex(detail) => write!(f, "invalid pattern: {detail}"),
            Self::InvalidExtension(detail) => write!(f, "invalid extension: {detail}"),
            Self::InvalidBasename(detail) => write!(f, "invalid candidate basename: {detail}"),
            Self::BasenameTooLong(len) => {
                write!(f, "candidate is {len} bytes; limit is {MAX_BASENAME_BYTES}")
            }
        }
    }
}

impl std::error::Error for SelectionError {}

/// Canonical serialization of a selection.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum EncodedSelection {
    /// Absence — the canonical form of [`SelectionState::LegacyAll`].
    Absent,
    /// Canonical contract JSON text.
    Json(String),
}

impl EncodedSelection {
    /// Borrow this encoding as decoder input, so a round trip is easy to write.
    pub fn as_input(&self) -> DecodeInput<'_> {
        match self {
            Self::Absent => DecodeInput::Absent,
            Self::Json(raw) => DecodeInput::Raw(raw),
        }
    }
}

/// A validated selection. Fields are private; values only come from
/// [`Selection::decode`], [`Selection::validated`] or the two all-files
/// constructors, so no caller can fabricate an unchecked runnable matcher.
#[derive(Debug, Clone)]
pub struct Selection {
    inner: SelectionInner,
}

#[derive(Debug, Clone)]
enum SelectionInner {
    LegacyAll,
    ExplicitAll,
    Constrained {
        pattern: String,
        regex: Option<Regex>,
        extension: Option<String>,
    },
}

impl PartialEq for Selection {
    fn eq(&self, other: &Self) -> bool {
        self.state() == other.state()
            && self.pattern() == other.pattern()
            && self.extension() == other.extension()
    }
}

impl Eq for Selection {}

impl Selection {
    /// The ABSENT selection: legacy all-files behaviour.
    pub fn legacy_all() -> Self {
        Self {
            inner: SelectionInner::LegacyAll,
        }
    }

    /// A stored selection without an effective constraint.
    pub fn explicit_all() -> Self {
        Self {
            inner: SelectionInner::ExplicitAll,
        }
    }

    /// Normalizer: validate an already-separated pattern and extension.
    ///
    /// The pattern is used unchanged; an empty pattern means no regex
    /// constraint. The extension is canonicalized per the contract.
    pub fn validated(pattern: &str, extension: &str) -> Result<Self, SelectionError> {
        let canonical_extension = canonicalize_extension(extension)?;
        let regex = if pattern.is_empty() {
            None
        } else {
            if pattern.len() > MAX_PATTERN_BYTES {
                return Err(SelectionError::PatternTooLong(pattern.len()));
            }
            Some(compile_pattern(pattern)?)
        };

        if regex.is_none() && canonical_extension.is_none() {
            return Ok(Self::explicit_all());
        }

        Ok(Self {
            inner: SelectionInner::Constrained {
                pattern: pattern.to_string(),
                regex,
                extension: canonical_extension,
            },
        })
    }

    /// Decode the ABSENT sentinel or raw contract JSON text.
    pub fn decode(input: DecodeInput<'_>) -> Result<Self, SelectionError> {
        match input {
            DecodeInput::Absent => Ok(Self::legacy_all()),
            DecodeInput::Raw(raw) => {
                let document = parse_document(raw)?;
                Self::validated(&document.filename_regex, &document.extension)
            }
        }
    }

    /// State tag of this selection.
    pub fn state(&self) -> SelectionState {
        match &self.inner {
            SelectionInner::LegacyAll => SelectionState::LegacyAll,
            SelectionInner::ExplicitAll => SelectionState::ExplicitAll,
            SelectionInner::Constrained { .. } => SelectionState::Constrained,
        }
    }

    /// The unchanged pattern, or `""` when there is no regex constraint.
    pub fn pattern(&self) -> &str {
        match &self.inner {
            SelectionInner::Constrained { pattern, .. } => pattern,
            _ => "",
        }
    }

    /// The canonical extension, or `None` when there is no extension
    /// constraint.
    pub fn extension(&self) -> Option<&str> {
        match &self.inner {
            SelectionInner::Constrained { extension, .. } => extension.as_deref(),
            _ => None,
        }
    }

    /// Canonical serialization. `LegacyAll` encodes as absence.
    pub fn encode(&self) -> EncodedSelection {
        match &self.inner {
            SelectionInner::LegacyAll => EncodedSelection::Absent,
            SelectionInner::ExplicitAll => EncodedSelection::Json(encode_parts("", "")),
            SelectionInner::Constrained {
                pattern, extension, ..
            } => EncodedSelection::Json(encode_parts(pattern, extension.as_deref().unwrap_or(""))),
        }
    }

    /// Evaluate one already-extracted final file basename.
    ///
    /// Returns `Ok(false)` for a valid non-match; any candidate or state error
    /// is `Err`, never a broadened selection.
    pub fn matches(&self, basename: &str) -> Result<bool, SelectionError> {
        validate_basename(basename)?;

        let (regex, extension) = match &self.inner {
            SelectionInner::LegacyAll | SelectionInner::ExplicitAll => return Ok(true),
            SelectionInner::Constrained {
                regex, extension, ..
            } => (regex, extension),
        };

        if let Some(regex) = regex {
            if !regex.is_match(basename) {
                return Ok(false);
            }
        }

        match extension {
            None => Ok(true),
            Some(expected) => Ok(candidate_extension(basename)
                .map(|found| found.eq_ignore_ascii_case(expected))
                .unwrap_or(false)),
        }
    }
}

/// Resolve the effective selection for an in-memory pair.
///
/// - An explicit override always wins, including an explicit empty selection.
/// - A new preset pair otherwise inherits its preset default.
/// - A new manual pair without settings is explicitly all-files.
/// - An existing pair keeps what it stored; a legacy pair never acquires a
///   later default.
///
/// This is a pure rule over validated values: no storage, inheritance or
/// authorization is performed.
pub fn resolve_effective(
    kind: PairKind,
    preset_default: Option<&Selection>,
    explicit: Option<&Selection>,
) -> Selection {
    match kind {
        PairKind::Existing => explicit.cloned().unwrap_or_else(Selection::legacy_all),
        PairKind::NewManual => explicit.cloned().unwrap_or_else(Selection::explicit_all),
        PairKind::NewPreset => explicit
            .cloned()
            .or_else(|| preset_default.cloned())
            .unwrap_or_else(Selection::explicit_all),
    }
}

fn compile_pattern(pattern: &str) -> Result<Regex, SelectionError> {
    RegexBuilder::new(pattern)
        .size_limit(REGEX_SIZE_LIMIT)
        .dfa_size_limit(REGEX_DFA_SIZE_LIMIT)
        .nest_limit(REGEX_NEST_LIMIT)
        .build()
        .map_err(|error| match &error {
            regex::Error::CompiledTooBig(_) => {
                SelectionError::PatternResourceLimit(error.to_string())
            }
            regex::Error::Syntax(detail) if detail.contains("nest") => {
                SelectionError::PatternResourceLimit(error.to_string())
            }
            _ => SelectionError::InvalidRegex(error.to_string()),
        })
}

fn canonicalize_extension(raw: &str) -> Result<Option<String>, SelectionError> {
    let trimmed = raw.trim_matches([' ', '\t', '\r', '\n']);
    if trimmed.is_empty() {
        return Ok(None);
    }

    let body = trimmed.strip_prefix('.').unwrap_or(trimmed);
    if body.is_empty() {
        return Err(SelectionError::InvalidExtension(
            "a lone dot is not an extension".to_string(),
        ));
    }
    if body.len() > MAX_EXTENSION_BYTES {
        return Err(SelectionError::InvalidExtension(format!(
            "{body:?} is longer than {MAX_EXTENSION_BYTES} bytes"
        )));
    }
    if !body
        .chars()
        .all(|c| c.is_ascii_alphanumeric() || c == '_' || c == '-')
    {
        return Err(SelectionError::InvalidExtension(format!(
            "{body:?} contains a character outside ASCII letters, digits, underscore and hyphen"
        )));
    }

    Ok(Some(body.to_ascii_lowercase()))
}

fn validate_basename(basename: &str) -> Result<(), SelectionError> {
    if basename.len() > MAX_BASENAME_BYTES {
        return Err(SelectionError::BasenameTooLong(basename.len()));
    }
    if basename.is_empty() {
        return Err(SelectionError::InvalidBasename(
            "empty candidate".to_string(),
        ));
    }
    if basename.contains('\0') {
        return Err(SelectionError::InvalidBasename(
            "candidate contains NUL".to_string(),
        ));
    }
    if basename.contains('/') {
        return Err(SelectionError::InvalidBasename(
            "candidate must be a final basename, not a path".to_string(),
        ));
    }
    if basename == "." || basename == ".." {
        return Err(SelectionError::InvalidBasename(format!(
            "{basename:?} is a directory entry, not a file basename"
        )));
    }
    Ok(())
}

/// Text after the final dot, only when that dot is neither first nor last.
fn candidate_extension(basename: &str) -> Option<&str> {
    let dot = basename.rfind('.')?;
    if dot == 0 || dot + 1 == basename.len() {
        return None;
    }
    Some(&basename[dot + 1..])
}

fn encode_parts(pattern: &str, extension: &str) -> String {
    let pattern =
        serde_json::to_string(pattern).expect("serializing a string into JSON cannot fail");
    let extension =
        serde_json::to_string(extension).expect("serializing a string into JSON cannot fail");
    format!(
        "{{\"version\":{CONTRACT_VERSION},\"dialect\":\"{DIALECT}\",\"filenameRegex\":{pattern},\"extension\":{extension}}}"
    )
}

struct RawDocument {
    filename_regex: String,
    extension: String,
}

fn parse_document(raw: &str) -> Result<RawDocument, SelectionError> {
    let slot: RefCell<Option<SelectionError>> = RefCell::new(None);
    let mut deserializer = serde_json::Deserializer::from_str(raw);
    let parsed = DocumentSeed { error: &slot }.deserialize(&mut deserializer);

    match parsed {
        Ok(document) => match deserializer.end() {
            Ok(()) => Ok(document),
            Err(error) => Err(SelectionError::MalformedJson(error.to_string())),
        },
        Err(error) => {
            if let Some(selection_error) = slot.into_inner() {
                return Err(selection_error);
            }
            match error.classify() {
                Category::Data => Err(SelectionError::NotAnObject),
                _ => Err(SelectionError::MalformedJson(error.to_string())),
            }
        }
    }
}

struct DocumentSeed<'a> {
    error: &'a RefCell<Option<SelectionError>>,
}

impl<'a, 'de> DeserializeSeed<'de> for DocumentSeed<'a> {
    type Value = RawDocument;

    fn deserialize<D>(self, deserializer: D) -> Result<Self::Value, D::Error>
    where
        D: serde::Deserializer<'de>,
    {
        deserializer.deserialize_any(DocumentVisitor { error: self.error })
    }
}

struct DocumentVisitor<'a> {
    error: &'a RefCell<Option<SelectionError>>,
}

impl<'a> DocumentVisitor<'a> {
    fn reject<E: DeError>(&self, error: SelectionError) -> E {
        *self.error.borrow_mut() = Some(error);
        E::custom("selection document rejected")
    }
}

impl<'a, 'de> Visitor<'de> for DocumentVisitor<'a> {
    type Value = RawDocument;

    fn expecting(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str("a selection contract object")
    }

    fn visit_unit<E: DeError>(self) -> Result<Self::Value, E> {
        Err(self.reject(SelectionError::PresentNull))
    }

    fn visit_map<A: MapAccess<'de>>(self, mut map: A) -> Result<Self::Value, A::Error> {
        let mut version: Option<u64> = None;
        let mut dialect: Option<String> = None;
        let mut filename_regex: Option<String> = None;
        let mut extension: Option<String> = None;

        while let Some(member) = map.next_key::<String>()? {
            match member.as_str() {
                "version" => {
                    if version.is_some() {
                        return Err(self.reject(SelectionError::DuplicateMember("version")));
                    }
                    let value = map.next_value::<Value>()?;
                    version = Some(match value {
                        Value::Number(number) => {
                            if let Some(found) = number.as_u64() {
                                if found != CONTRACT_VERSION {
                                    return Err(self.reject(SelectionError::UnknownVersion(
                                        found.to_string(),
                                    )));
                                }
                                found
                            } else if number.as_i64().is_some() {
                                return Err(
                                    self.reject(SelectionError::UnknownVersion(number.to_string()))
                                );
                            } else {
                                return Err(self.reject(SelectionError::WrongType("version")));
                            }
                        }
                        _ => return Err(self.reject(SelectionError::WrongType("version"))),
                    });
                }
                "dialect" => {
                    if dialect.is_some() {
                        return Err(self.reject(SelectionError::DuplicateMember("dialect")));
                    }
                    let value = map.next_value::<Value>()?;
                    match value {
                        Value::String(found) => {
                            if found != DIALECT {
                                return Err(self.reject(SelectionError::UnknownDialect(found)));
                            }
                            dialect = Some(found);
                        }
                        _ => return Err(self.reject(SelectionError::WrongType("dialect"))),
                    }
                }
                "filenameRegex" => {
                    if filename_regex.is_some() {
                        return Err(self.reject(SelectionError::DuplicateMember("filenameRegex")));
                    }
                    let value = map.next_value::<Value>()?;
                    match value {
                        Value::String(found) => filename_regex = Some(found),
                        _ => return Err(self.reject(SelectionError::WrongType("filenameRegex"))),
                    }
                }
                "extension" => {
                    if extension.is_some() {
                        return Err(self.reject(SelectionError::DuplicateMember("extension")));
                    }
                    let value = map.next_value::<Value>()?;
                    match value {
                        Value::String(found) => extension = Some(found),
                        _ => return Err(self.reject(SelectionError::WrongType("extension"))),
                    }
                }
                other => {
                    return Err(self.reject(SelectionError::UnknownMember(other.to_string())));
                }
            }
        }

        if version.is_none() {
            return Err(self.reject(SelectionError::MissingMember("version")));
        }
        if dialect.is_none() {
            return Err(self.reject(SelectionError::MissingMember("dialect")));
        }
        let Some(filename_regex) = filename_regex else {
            return Err(self.reject(SelectionError::MissingMember("filenameRegex")));
        };
        let Some(extension) = extension else {
            return Err(self.reject(SelectionError::MissingMember("extension")));
        };

        Ok(RawDocument {
            filename_regex,
            extension,
        })
    }
}
