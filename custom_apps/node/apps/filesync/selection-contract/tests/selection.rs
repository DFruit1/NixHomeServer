//! Integration test for the frozen v1 selection contract corpus.
//!
//! The expected values in `fixtures/selection-v1.json` are reviewed literal
//! vectors. Nothing here regenerates them from the implementation under test:
//! the test only reads the file and calls the public library.

use std::collections::BTreeSet;
use std::fs;
use std::path::PathBuf;

use filesync_selection_contract::{
    resolve_effective, DecodeInput, EncodedSelection, PairKind, Selection, SelectionState,
    CONTRACT_VERSION, DIALECT,
};
use serde_json::Value;

fn fixture() -> Value {
    let path = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("fixtures/selection-v1.json");
    let text = fs::read_to_string(&path)
        .unwrap_or_else(|error| panic!("cannot read {}: {error}", path.display()));
    serde_json::from_str(&text)
        .unwrap_or_else(|error| panic!("{} is not valid JSON: {error}", path.display()))
}

fn case_name(case: &Value) -> &str {
    case.get("name")
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("case without a string name: {case}"))
}

fn decode_input(input: &Value) -> DecodeInput<'_> {
    let present = input
        .get("present")
        .and_then(Value::as_bool)
        .unwrap_or_else(|| panic!("input must carry a boolean 'present': {input}"));
    let raw = input
        .get("raw")
        .unwrap_or_else(|| panic!("input must carry 'raw': {input}"));
    match (present, raw) {
        (false, Value::Null) => DecodeInput::Absent,
        (true, Value::String(text)) => DecodeInput::Raw(text),
        _ => panic!(
            "input must be {{\"present\":false,\"raw\":null}} or {{\"present\":true,\"raw\":\"...\"}}, got {input}"
        ),
    }
}

fn decoded_optional(input: Option<&Value>) -> Option<Selection> {
    match input {
        None | Some(Value::Null) => None,
        Some(input) => Some(
            Selection::decode(decode_input(input)).unwrap_or_else(|error| {
                panic!("fixture input must decode: {} ({error})", error.class())
            }),
        ),
    }
}

fn expect_str<'a>(expect: &'a Value, key: &str, name: &str) -> &'a str {
    expect
        .get(key)
        .and_then(Value::as_str)
        .unwrap_or_else(|| panic!("case {name}: expect.{key} must be a string"))
}

fn check_state(name: &str, selection: &Selection, expect: &Value) {
    assert_eq!(
        selection.state().tag(),
        expect_str(expect, "state", name),
        "case {name}: state"
    );
    assert_eq!(
        selection.pattern(),
        expect_str(expect, "pattern", name),
        "case {name}: pattern"
    );

    let extension = expect
        .get("extension")
        .unwrap_or_else(|| panic!("case {name}: expect.extension must be present"));
    let expected_extension = match extension {
        Value::Null => None,
        Value::String(text) => Some(text.as_str()),
        other => panic!("case {name}: expect.extension must be string or null, got {other}"),
    };
    assert_eq!(
        selection.extension(),
        expected_extension,
        "case {name}: canonical extension"
    );
}

fn check_canonical(name: &str, selection: &Selection, expect: &Value) {
    let Some(canonical) = expect.get("canonical") else {
        return;
    };

    match canonical {
        Value::Null => {
            assert_eq!(
                selection.state(),
                SelectionState::LegacyAll,
                "case {name}: only legacy-all may encode as absence"
            );
            assert_eq!(
                selection.encode(),
                EncodedSelection::Absent,
                "case {name}: canonical form of legacy-all is absence"
            );
        }
        Value::String(text) => {
            assert_eq!(
                selection.encode(),
                EncodedSelection::Json(text.clone()),
                "case {name}: canonical bytes"
            );
        }
        other => panic!("case {name}: expect.canonical must be string or null, got {other}"),
    }
}

fn check_round_trip(name: &str, selection: &Selection) {
    let encoded = selection.encode();
    let round_tripped = Selection::decode(encoded.as_input())
        .unwrap_or_else(|error| panic!("case {name}: canonical form must decode: {error}"));
    assert_eq!(
        &round_tripped, selection,
        "case {name}: round trip preserves the selection"
    );
    assert_eq!(
        round_tripped.encode(),
        encoded,
        "case {name}: canonical form is idempotent"
    );
}

fn check_matches(name: &str, selection: &Selection, case: &Value) {
    let Some(vectors) = case.get("matches") else {
        return;
    };
    let vectors = vectors
        .as_array()
        .unwrap_or_else(|| panic!("case {name}: matches must be an array"));
    assert!(
        !vectors.is_empty(),
        "case {name}: matches must not be empty"
    );

    for vector in vectors {
        let basename = vector
            .get("basename")
            .and_then(Value::as_str)
            .unwrap_or_else(|| panic!("case {name}: match vector without a basename: {vector}"));

        match (
            vector.get("matches").and_then(Value::as_bool),
            vector.get("error").and_then(Value::as_str),
        ) {
            (Some(expected), None) => {
                let actual = selection.matches(basename).unwrap_or_else(|error| {
                    panic!("case {name}: {basename:?} must evaluate, got {error}")
                });
                assert_eq!(actual, expected, "case {name}: basename {basename:?}");
            }
            (None, Some(class)) => {
                let error = selection
                    .matches(basename)
                    .expect_err(&format!("case {name}: {basename:?} must fail to evaluate"));
                assert_eq!(error.class(), class, "case {name}: basename {basename:?}");
            }
            _ => panic!("case {name}: match vector must set exactly one of matches/error"),
        }
    }
}

#[test]
fn fixture_metadata_is_version_one() {
    let fixture = fixture();
    assert_eq!(
        fixture.get("schemaVersion").and_then(Value::as_u64),
        Some(1),
        "fixture schemaVersion"
    );

    let engine = fixture
        .get("engine")
        .expect("fixture must describe the engine");
    assert_eq!(
        engine.get("contractVersion").and_then(Value::as_u64),
        Some(CONTRACT_VERSION)
    );
    assert_eq!(engine.get("dialect").and_then(Value::as_str), Some(DIALECT));
    assert_eq!(
        engine.get("regexCrate").and_then(Value::as_str),
        Some("regex")
    );
    assert_eq!(
        engine.get("regexVersion").and_then(Value::as_str),
        Some("1.13.1")
    );
}

#[test]
fn decode_cases_match_reviewed_vectors() {
    let fixture = fixture();
    let cases = fixture
        .get("decodeCases")
        .and_then(Value::as_array)
        .expect("decodeCases array");
    assert!(cases.len() >= 50, "corpus must stay substantial");

    let mut states = BTreeSet::new();
    let mut errors = BTreeSet::new();
    let mut candidate_errors = BTreeSet::new();

    for case in cases {
        for vector in case
            .get("matches")
            .and_then(Value::as_array)
            .map(Vec::as_slice)
            .unwrap_or(&[])
        {
            if let Some(class) = vector.get("error").and_then(Value::as_str) {
                candidate_errors.insert(class);
            }
        }
    }

    for case in cases {
        let name = case_name(case);
        let input = decode_input(case.get("input").expect("case input"));
        let expect = case.get("expect").expect("case expect");
        let outcome = expect_str(expect, "outcome", name);

        match outcome {
            "selection" => {
                let selection = Selection::decode(input).unwrap_or_else(|error| {
                    panic!(
                        "case {name}: expected a selection, got error {}",
                        error.class()
                    )
                });
                check_state(name, &selection, expect);
                check_canonical(name, &selection, expect);
                check_round_trip(name, &selection);
                check_matches(name, &selection, case);
                states.insert(selection.state().tag());
            }
            "error" => {
                let class = expect_str(expect, "errorClass", name);
                let error = Selection::decode(input)
                    .expect_err(&format!("case {name}: expected decoder error {class}"));
                assert_eq!(error.class(), class, "case {name}: error class");
                errors.insert(error.class());
            }
            other => panic!("case {name}: unknown expect.outcome {other}"),
        }
    }

    for required in ["legacy-all", "explicit-all", "constrained"] {
        assert!(states.contains(required), "corpus lost state {required}");
    }
    for required in [
        "malformed-json",
        "not-an-object",
        "present-null",
        "duplicate-member",
        "missing-member",
        "unknown-member",
        "wrong-type",
        "unknown-version",
        "unknown-dialect",
        "pattern-too-long",
        "pattern-resource-limit",
        "invalid-regex",
        "invalid-extension",
    ] {
        assert!(
            errors.contains(required),
            "corpus lost error class {required}"
        );
    }
    for required in ["invalid-basename", "basename-too-long"] {
        assert!(
            candidate_errors.contains(required),
            "corpus lost candidate error class {required}"
        );
    }
}

#[test]
fn effective_cases_match_reviewed_vectors() {
    let fixture = fixture();
    let cases = fixture
        .get("effectiveCases")
        .and_then(Value::as_array)
        .expect("effectiveCases array");
    assert!(!cases.is_empty(), "effectiveCases must not be empty");

    for case in cases {
        let name = case_name(case);
        let kind = match expect_str(case, "pairKind", name) {
            "new-preset" => PairKind::NewPreset,
            "new-manual" => PairKind::NewManual,
            "existing" => PairKind::Existing,
            other => panic!("case {name}: unknown pairKind {other}"),
        };

        let preset_default = decoded_optional(case.get("presetDefault"));
        let explicit = decoded_optional(case.get("explicit"));
        let resolved = resolve_effective(kind, preset_default.as_ref(), explicit.as_ref());
        let expect = case.get("expect").expect("case expect");

        check_state(name, &resolved, expect);
        check_matches(name, &resolved, case);
    }
}

#[test]
fn negative_controls_reference_live_cases() {
    let fixture = fixture();
    let decode_names: BTreeSet<&str> = fixture["decodeCases"]
        .as_array()
        .expect("decodeCases array")
        .iter()
        .map(case_name)
        .collect();
    let effective_names: BTreeSet<&str> = fixture["effectiveCases"]
        .as_array()
        .expect("effectiveCases array")
        .iter()
        .map(case_name)
        .collect();

    let controls = fixture
        .get("negativeControls")
        .and_then(Value::as_array)
        .expect("negativeControls array");
    assert!(controls.len() >= 6, "negative controls must not shrink");

    for control in controls {
        let name = control
            .get("name")
            .and_then(Value::as_str)
            .expect("control name");
        let kind = control
            .get("kind")
            .and_then(Value::as_str)
            .expect("control kind");
        let mutation = control
            .get("mutation")
            .and_then(Value::as_str)
            .expect("control mutation");
        assert!(!mutation.is_empty(), "control {name} needs a mutation note");

        let live = match kind {
            "decode" => decode_names.contains(name),
            "effective" => effective_names.contains(name),
            other => panic!("control {name}: unknown kind {other}"),
        };
        assert!(live, "control {name} does not reference a live {kind} case");
    }
}

#[test]
fn required_coverage_cases_are_present() {
    let fixture = fixture();
    let names: BTreeSet<&str> = fixture["decodeCases"]
        .as_array()
        .expect("decodeCases array")
        .iter()
        .map(case_name)
        .collect();

    for required in [
        "absent-is-legacy-all",
        "present-both-empty-is-explicit-all",
        "regex-only-is-constrained",
        "extension-only-is-constrained",
        "regex-and-extension-is-constrained",
        "schema-present-null",
        "schema-malformed-truncated",
        "schema-duplicate-version",
        "schema-duplicate-dialect",
        "schema-duplicate-filenameRegex",
        "schema-duplicate-extension",
        "schema-unknown-member",
        "schema-missing-version",
        "schema-missing-dialect",
        "schema-missing-filenameRegex",
        "schema-missing-extension",
        "schema-unknown-version-999",
        "schema-dialect-unknown",
        "extension-lone-dot-invalid",
        "extension-two-dots-invalid",
        "extension-unicode-invalid",
        "regex-backreference-invalid",
        "regex-double-backslash-is-literal",
        "limit-pattern-1024-valid",
        "limit-pattern-1025-invalid",
        "limit-pattern-nesting-33-invalid",
        "limit-pattern-size-invalid",
        "candidate-length-4096-valid",
        "candidate-length-4097-invalid",
        "candidate-path-invalid",
    ] {
        assert!(
            names.contains(required),
            "required corpus case {required} is missing"
        );
    }
}

#[test]
fn all_files_states_keep_their_distinct_identity() {
    let legacy = Selection::legacy_all();
    let explicit = Selection::explicit_all();

    assert_eq!(legacy.state(), SelectionState::LegacyAll);
    assert_eq!(explicit.state(), SelectionState::ExplicitAll);
    assert_ne!(legacy, explicit);

    assert_eq!(legacy.encode(), EncodedSelection::Absent);
    assert_eq!(
        explicit.encode(),
        EncodedSelection::Json(
            "{\"version\":1,\"dialect\":\"rust-regex-1\",\"filenameRegex\":\"\",\"extension\":\"\"}"
                .to_string()
        )
    );

    assert_eq!(
        Selection::decode(DecodeInput::Raw("null"))
            .map(|selection| selection.state())
            .unwrap_err()
            .class(),
        "present-null"
    );
}

#[test]
fn normalizer_enforces_extension_rules() {
    assert_eq!(
        Selection::validated("", "  \t ").unwrap().state(),
        SelectionState::ExplicitAll
    );
    assert_eq!(
        Selection::validated("   ", "").unwrap().state(),
        SelectionState::Constrained
    );
    assert_eq!(
        Selection::validated("", ".DOCX").unwrap().extension(),
        Some("docx")
    );
    assert_eq!(
        Selection::validated("", ".").unwrap_err().class(),
        "invalid-extension"
    );
    assert_eq!(
        Selection::validated("", "tar.gz").unwrap_err().class(),
        "invalid-extension"
    );
    assert_eq!(
        Selection::validated("(", "").unwrap_err().class(),
        "invalid-regex"
    );
}
