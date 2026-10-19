# filesync-selection-contract

Dormant reference implementation of the proposed filesync **selection contract
v1** (Rust reference dialect) plus its executable corpus.

This crate is intentionally **not wired into anything**. No app, native plugin,
API, service or store imports it. It exists so the strict decoder, the extension
semantics and the basename matcher can be reviewed and tested on their own
before anyone proposes enabling filters in the product. Finding CI-FSYNC-003
stays deferred: accepting this foundation is not accepting the full feature.

Provenance: `FSYNC-FILTER-FOUNDATION-20261020-v1.md`
(SHA256 `3fe388e0f3a484e3266b03a5b9251f07dd1dfac1db89f3f1dfa758150fe53813`) and
its mandatory addendum `FSYNC-FILTER-FOUNDATION-20261020-v2.md`
(SHA256 `f66fd8d0a671441d8ad9d9df66a5c38cf99ed34110ae161660f150b8b45f2dfa`).
Both documents govern this package; v1 history is never rewritten.

## What it does

- Strict decoder: explicit ABSENT sentinel or raw contract JSON text.
- Normalizer: canonical extension, validated pattern and compiled matcher.
- Matcher: one already-extracted final file basename → `Result<bool, SelectionError>`.
- Effective-selection rule over validated values (no storage, no inheritance).

## Contract v1

Input is either the explicit ABSENT sentinel or raw JSON text with exactly
these four required members (any order):

```text
{"version":1,"dialect":"rust-regex-1","filenameRegex":"","extension":""}
```

Rules:

- `version` is the integer `1`. Booleans, strings, floats, negative numbers,
  `null` and other integers are errors.
- `dialect` is exactly `rust-regex-1`.
- `filenameRegex` and `extension` are strings.

Absence is **never** JSON `null`. Present `null`, malformed JSON, missing,
duplicate, unknown or wrongly typed members, an unknown version or dialect and
an invalid regex are all errors. Raw text is parsed directly with a map visitor,
so duplicate keys are reported instead of silently collapsed. A decoder error
never degrades into an all-files selection, and the caller's text is only
borrowed, never rewritten.

### States

| Input | State tag | Selects |
| --- | --- | --- |
| ABSENT sentinel | `legacy-all` | every valid basename |
| valid object, no effective constraint | `explicit-all` | every valid basename |
| valid object with a regex and/or extension constraint | `constrained` | matches only |

`legacy-all` and `explicit-all` behave the same but keep distinct state tags.
Canonical serialization of `legacy-all` is absence; it is never `null` or `{}`.

### Error classes

`malformed-json`, `not-an-object`, `present-null`, `duplicate-member`,
`missing-member`, `unknown-member`, `wrong-type`, `unknown-version`,
`unknown-dialect`, `pattern-too-long`, `pattern-resource-limit`,
`invalid-regex`, `invalid-extension`, `invalid-basename`, `basename-too-long`.

## Match semantics

### filenameRegex

The pattern is passed to `regex` 1.13.1 **unchanged** — no trimming. An empty
string means "no regex constraint", never an invalid pattern. A pattern made of
spaces is a real pattern.

Matching is Rust `Regex::is_match` (search) semantics: case-sensitive by
default, Unicode enabled, non-multiline, `.` excludes newline, ordinary
whitespace significant, inline flags such as `(?i)` honoured. This is Rust regex
syntax; JavaScript or JVM syntax equivalence is not claimed. Look-around and
backreferences are unsupported by the engine and surface as `invalid-regex`
decoder errors.

### extension

One suffix, not a list, glob or comma language.

1. Trim ASCII space, tab, CR and LF at both ends.
2. A blank/whitespace-only value means no extension constraint.
3. Remove at most one leading dot. A lone dot is invalid, not empty.
4. ASCII-lowercase the remainder.
5. A non-empty suffix must be 1..=32 ASCII letters, digits, underscore or
   hyphen. Internal whitespace, further dots, commas, separators and non-ASCII
   characters are invalid.

Canonical serialization stores the lowercase suffix without the leading dot.
The regex is never lowercased. Case-insensitivity is ASCII-only suffix
comparison; there is no Unicode normalization or Unicode case folding, while
Unicode stems are supported (`résumé.docx` matches `docx`).

### Candidates

The candidate is the already-extracted **final file basename**, not a path or
URI: UTF-8, 1..=4096 bytes. Empty, NUL-containing, slash-containing, `.` and
`..` candidates are errors. Backslash is a literal character on this project's
Linux/Android targets, not a separator.

The candidate's extension is the text after its final dot, only when that dot is
neither first nor last. Thus `.docx`, `.bashrc`, `report.` and `reportdocx` have
no extension and `archive.tar.gz` has `gz`.

Both constraints are ANDed; a missing constraint is always true. Any candidate
or resource error is an error, never a broadened selection.

### Limits

- pattern: 1024 UTF-8 bytes (`pattern-too-long` above that)
- compiled regex size limit: 1 MiB
- lazy DFA cache limit: 1 MiB
- parser nesting limit: 32

Breaching an engine limit is `pattern-resource-limit`. The limits are not
disabled, and no wall-clock latency bound is claimed from the engine's
complexity statement.

## Effective selection

`resolve_effective(kind, preset_default, explicit)` is a pure rule over
validated values:

- `Existing`: the stored selection is kept; a legacy pair stays `legacy-all` and
  never acquires a later default.
- `NewManual`: an explicit selection, otherwise `explicit-all`.
- `NewPreset`: an explicit override always wins (including an explicit empty
  selection), otherwise the preset default, otherwise `explicit-all`.

It performs no storage access, inheritance or authorization.

## Corpus

`fixtures/selection-v1.json` is a single `schemaVersion: 1` document with
uniquely named `decodeCases`, `effectiveCases` and `negativeControls`. Decoder
input is encoded as `{"present": boolean, "raw": string|null}` so absent,
literal `null`, malformed and duplicate-member JSON survive without
object-normalization loss. Expected values are reviewed literal vectors, not
output of the implementation under test.

`tests/selection.rs` reads that file from disk and drives only public API. It
checks state, canonical extension, canonical bytes where frozen, round-trip
idempotence and per-basename match/error vectors. `negativeControls` names the
live cases that fail if the regex or the extension is ignored, if AND becomes
OR, if a decoder error becomes all-files, or if a default refresh replaces an
explicit empty selection.

## Verification

From the repository root:

```sh
cargo test --locked --manifest-path custom_apps/node/apps/filesync/selection-contract/Cargo.toml --all-targets
cargo fmt --manifest-path custom_apps/node/apps/filesync/selection-contract/Cargo.toml --all -- --check
pnpm --dir custom_apps/node/apps/filesync test
git diff --check
bash scripts/validate-repo.sh
```

Pins: `regex =1.13.1`, `serde =1.0.228` (derive) and `serde_json =1.0.145`,
mirroring the two versions the app already declares. `Cargo.lock` is generated
and owned by this package; no existing lockfile or manifest is modified, and
acceptance runs `--locked` with before/after lock hashes recorded.

## Explicit non-claims

- Not wire-compatible with any stored or transported payload; no public wire
  adoption has been approved.
- No portable JavaScript/JVM dialect, no Kotlin/Android implementation, no
  Rust-to-background bridge.
- No min-reader barrier, migration, store access, preset projection or UI.
- No path adapter and no directory-traversal filtering: the library rejects
  slash-containing input and expects real basenames. A future consumer must
  extract basenames itself; nothing here filters a traversal.
- No claim that filters are enabled, that excluded destinations are protected
  from deletion, or that CI-FSYNC-003 is closed.

## Rollback

Revert the single commit that adds this directory, or leave the unused library
in place. Nothing imports it, no pair/preset data is written and no constrained
transfer was enabled, so removing it cannot silently expand a previously
constrained transfer. A future adopter invalidates that simple rollback and
needs its own plan.
