# Meaningful Word and Excel edits

The former Office interface could replace a cell or a unique phrase but could
not add/remove records, identify tables precisely, copy mapped source columns,
or physically sort table contents. Its paginated read view also stopped at the
old global projection limits. Those primitives were insufficient for an
ordinary request such as “add rows from this document, then sort the tables.”

The structural interface adds five gateway-only tools alongside the existing
native creation and phrase/cell editing tools:

| Tool | Role |
| --- | --- |
| `office_skill` | Load practical overview, Word, Excel or import guidance. |
| `office_inspect` | Discover revision-bound table/paragraph selectors and read actual targeted data pages. |
| `office_import_table` | Import and optionally sort one table using direct source/destination fields. |
| `word_edit` | Apply table and paragraph operations to one new DOCX copy. |
| `spreadsheet_edit` | Apply table-local record and supported formula operations to one new XLSX copy. |

The skills are [packaged with the application](../custom_apps/rust/apps/ai-tools/skills/office-editing/SKILL.md)
and compiled into the tool server, so Bonsai can load them through an ordinary
tool call. They are not a developer-only skill installation or a dependency on
MCP clients supporting a separate prompt/resource interface. Gateway handshake
instructions and tool descriptions direct the model to this workflow.

## Ordinary intentions

The assistant inspects the documents and resolves table names, column mappings,
revisions, operation indexes and copy filenames itself. It uses conventional
defaults: append data records, retain headers/totals/duplicates, sort complete
records together, stable ties, blanks last, and preserve formatting. An obvious
primary Name/Item label ascending is a reasonable unqualified sort default when
context supports it; the assistant states that assumption. Competing business
keys, conflicting mappings or ambiguous dates need a focused clarification.
Users do not need to supply JSON or technical qualifiers.

The common import-and-sort subtool assembles the safe batch itself. The general
edit tools retain explicit batches for multi-table and other compound changes.
Their schemas expose actual object properties rather than reference-only
variants that can hide parameters from small-model tool templates.

For example, given a Word source with Customer/Amount headers and a named Excel
table with Name/Amount headers, the assistant reads both revisions, maps
Customer to Name and unambiguous decimal Amount values to numeric cells,
imports the records, and sorts the expanded target in the same batch. It then
inspects the resulting copy. Missing optional destination columns remain blank
or inherit supported calculated cells. Every selected source column must be
retained; there is no silent fuzzy matching, deduplication or lossy conversion.

## Enforced editing contract

- Every call requires the current authenticated gateway actor. Every imported
  source is independently read through the caller's file-access broker.
- Destination and import sources must match SHA-256 revisions returned by
  inspection. IDs bind to objects within that revision, not across saved copies.
- Operations apply sequentially in memory. Reusing one table selector after an
  append sees its new bounds. A batch creates one new file only after all
  operations succeed; no intermediate document is published. Existing files
  and source documents are never overwritten.
- Inserts/deletes are **table-local record operations**, never whole worksheet
  row shifts. Growth into occupied cells or other tables is refused.
- Record sorting moves actual cells/rows, not merely Excel `sortState` metadata.
  Formula keys are refused because cached results may be stale.
- Imported `=...` strings are literal data. Formula creation is an explicit
  `set_formula` operation. Plain-decimal numeric mapping rejects leading-zero
  identifiers, lost precision, currency/unit strings and guessed locales.
- The existing file roots, kernel permissions, no-symlink/single-link checks,
  new-copy publication and byte-only Landlock/seccomp parser boundary remain.

Supported table operations are append, insert, delete, set cells, mapped import
and multi-key sort. Word additionally supports body paragraph set/insert/append
with existing styles. Excel supports a bounded, non-external calculation
subset: row-local formulas, supported current-row structured references and
structured totals. Formulas are translated/marked for recalculation, not
evaluated here. Untouched package parts remain intact.

Formula translation is deliberately separated from dependency preservation:
[openpyxl documents that structural edits do not maintain workbook dependencies](https://openpyxl.readthedocs.io/en/stable/editing_worksheets.html).
Unsupported incoming references, shared/array/spill dependencies, names,
overlapping metadata and relevant charts/pivots are refused rather than
silently shifted. Word merged/ragged/nested/annotated tables, tracked changes,
complex body fields and protection are likewise bounded exclusions. Active
Excel filters are refused because saved row visibility cannot safely be
reapplied by this editor. Manually hidden row positions participate in sorting
but retain their existing worksheet visibility/height settings.

## Bounds and outcomes

Inspection returns real table bounds, header/totals counts, data-row counts,
capabilities/refusal reasons, revisions and continuation offsets. Its 24 KiB
response budget is separate from change limits; it never reconstructs a source
from a page. A table below worksheet row 2000 remains inspectable/editable.
Text cell previews default to 1000 characters; `truncated_columns` marks the
affected 1-based columns. `text_limit` (16–8192) controls the preview, within
the same byte budget. Mapped imports always copy complete source values rather
than these previews. Word cell replacements retain existing paragraph layout;
both structural and legacy phrase edits refuse document protection.

Each batch permits 32 operations, four import documents, 500 rows per insert or
import page, 5000 data rows per table, 64 columns, 100000 affected cells, 256 KiB
operation arguments and 32 MiB combined native document input. Existing parser
process, archive expansion and output limits also apply. Larger sources require
deliberate pages; imports never silently select only the first 500 records.

Results include the new path, output/source revisions, operation row counts,
updated target bounds, warnings and `recalculated:false`. Skills require a
readback check before reporting completion and prohibit blind retries after an
uncertain save. Conversion from legacy/ODF formats remains a separate operation;
it is not represented as a preservation-guaranteed structural edit.

## Verification evidence

The focused implementation checks passed 77 `ai-tools` Rust tests (one existing
mapped-namespace kernel-permission test remains explicitly ignored) and 38
Office-helper tests. Regressions cover atomic failure, independently pinned
source revisions, caller isolation, literal imports, stable sorting, formula
dependencies, merged/ragged tables and paragraph pagination/insertion order.
Independent same-model Word and Excel reviews found nine correctness defects;
the fixes were reproduced and checked against the affected regressions. No
cross-model review or repository-wide suite is claimed.

Two end-to-end inference trials used the running `bonsai-ternary-27b` model,
the real Rust MCP gateway, its actual tool schemas and packaged skills, the
packaged Python helper and its Landlock/seccomp sandbox. Files and identity
were isolated synthetic fixtures through a fixture broker; these trials do not
represent production SSO or live private-file acceptance. Tool responses used
the pinned llama.cpp UI's joined-text format.

- “Add the rows … then sort … by Amount from smallest to largest” selected
  numeric mapping and produced Alice/2.5, Zed/9, Bob/10.
- “Please add in rows to my table from incoming.docx and then sort the tables
  in destination.xlsx” selected the obvious Name column ascending and produced
  Alice, Bob, Zed without a technical clarification.

Each trial loaded the import skill, inspected both files and tables, performed
one `office_import_table` call and inspected the output: seven tool calls, one
new copy, no duplicate import. Native table bounds, translated formulas, an
unrelated styled heading and a hidden worksheet were verified in the saved
workbook. A separate independent skill trial exercised a mapped import plus
sorting two destination tables in one general batch, retaining styles and
unchanged hidden-sheet XML. Word document preservation is covered by the
focused helper checks, not a live-model Word-output trial.

The Nix helper package built successfully, and all four runtime skill files
were verified byte-for-byte in the assembled Nix application source. These
checks do not activate the feature: the deployment owner still needs the
guarded test/switch and authenticated live acceptance for the committed change.
