# Copy records between documents, then sort

For “add rows to my table from this document and then sort the tables”:

Prefer `office_import_table` for one source and one destination table. Its flat
arguments avoid assembling a batch: source_path/source_revision plus the source
selector fields; destination_path/destination_revision plus the destination
selector fields; optional column_map and sort_by/sort_kind/sort_direction.
For a Word source use source_table_index; for an Excel destination use
destination_sheet and destination_table (or destination_range). The tool does
the import and sort together, once. Omit output_name for a unique copy.

Example arguments after inspecting both files:

```json
{"source_path":"incoming.docx","source_revision":"<source revision>","source_table_index":0,
 "destination_path":"destination.xlsx","destination_revision":"<destination revision>",
 "destination_sheet":"Sales","destination_table":"SalesData",
 "column_map":[{"source":"Name","target":"Name"},{"source":"Amount","target":"Amount","kind":"number"}],
 "sort_by":"Amount","sort_kind":"number","sort_direction":"ascending"}
```

Use the general edit batch below when changing several destination tables or
combining import with other edits.

1. Identify both files and inspect their structures and relevant table pages.
   Resolve the source table, destination table(s), headers and sort intention
   from context. If there is one obvious Name/Item primary label and no other
   cue, ascending label order is a reasonable reversible default; mention it.
   Ask about genuinely competing keys/targets, not JSON or file mechanics.
2. Choose the matching destination edit tool. Add an `import_rows` operation
   for each intended source/target pair, followed by the requested `sort_rows`
   operations in the **same batch**. Multiple tables can be changed atomically.
   `import_rows` already copies/appends the records: do not also append the
   same source values with `append_rows`. The usual batch is import followed
   by sort, not import plus append plus sort. Copy the destination's
   `edit_target` into `destination` or `target`; the source selector belongs
   only in `source.selector`. An Excel destination needs sheet/table, never
   a Word source table_index.
3. Supply the destination revision at the tool's top level and each source's
   revision in its import specification. Every source is independently opened
   through the caller's file-access broker. Native DOCX and XLSX are supported.
4. Inspect the resulting copy. Check row counts and ordering; retain duplicate
   records unless the user requested deduplication. Report the saved copy.

Example Excel import operation, followed by a numeric sort:

```json
[
  {"op":"import_rows","target":{"sheet":"Sales","table":"SalesData"},
   "source":{"path":"Reports/incoming.docx","revision":"<revision from source inspection>","selector":{"table_index":0}},
   "column_map":[{"source":"Customer","target":"Name"},{"source":"Amount","target":"Amount","kind":"number"}]},
  {"op":"sort_rows","target":{"sheet":"Sales","table":"SalesData"},
   "keys":[{"column":"Amount","kind":"number","direction":"ascending"}]}
]
```

Header matching without `column_map` is exact after trimming/case-folding, never
fuzzy. An explicit mapping uses unique header names or 1-based column indexes.
Retain every selected source column: inspect/select a narrower XLSX rectangle
when the user intentionally wants fewer columns. Repeated/ambiguous headers
need explicit indexes. Unmapped destination columns become blank, or inherit
supported destination formulas when present.

Mapping `kind` defaults to `preserve`. Use `number` for clearly numeric business
values when the destination schema and unambiguous plain decimals support that
interpretation. It rejects leading-zero identifiers, precision loss, currency,
units, separators and guessed locales. Use `text` when explicit text conversion
is intended. Preserve identifiers such as `00123`, large exact IDs and ambiguous
date strings as text. All `=...` imports remain literal strings; formulas are
never inferred from source text. Formula-valued source cells are refused because
the service cannot trust their cached values.

Source `offset` is zero-based and `limit` is 1–500. If a source has more than
500 remaining records, the tool requires an explicit page rather than silently
importing a prefix. Use deliberate consecutive pages with matching revisions
and a final sort; respect the total change budget. Do not claim completion if
any intended source rows remain unimported. For prose, read the relevant text
and supply literal rows only when the requested field mapping is clear; do not
invent missing business data.

If validation rejects a call, correct the named argument using destination
inspection or the destination format skill. Do not replay an unchanged failed
batch; after two identical errors, stop and inspect rather than looping.
