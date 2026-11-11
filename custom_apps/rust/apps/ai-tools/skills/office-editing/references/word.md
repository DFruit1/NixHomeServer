# Word editing

Use `office_inspect` to discover body `paragraph_index` and `table_index`
selectors. Use `word_edit` for structural edits; use the existing
`word_document(action="edit")` unique-text replacement for small phrase edits
that must retain run formatting. Neither operation rebuilds the read view.

Table targets are `{"table_index":0}`. The first row is a header by default;
an existing run of repeating header rows is retained. Set `header_rows:0` for
a clearly headerless table. Data row and column indexes are 1-based; table and
paragraph indexes are 0-based. Use unique header names instead of column
indexes when available. A batch can edit multiple tables in the same file.

Operations:

- `append_rows`: add literal `rows`, with exactly the table's column count.
- `insert_rows`: same, with `row` indicating the data row to insert before.
- `delete_rows`: `row` and `count`, only when removal is intended.
- `set_cells`: `cells:[{row,column,value}]`; replaces the selected cell text.
- `sort_rows`: `keys:[{column,direction,kind}]`, highest priority first.
- `import_rows`: see `office_skill(topic="import")`.
- `paragraph_set`: `paragraph_index`, single-paragraph `text`, optional existing
  `style` name/ID. This intentionally replaces the paragraph text.
- `paragraph_insert`: same, plus `where:before|after` (default after).
- `paragraph_append`: single-paragraph `text`, optional existing `style`.

For new records the editor copies supported row/cell/paragraph/run formatting,
not old text, identifiers, bookmarks, comments, drawings or header-repeat flags.
Sorting moves whole existing formatted rows. Paragraph operations preserve
unrelated paragraphs, tables, headers/footers, sections and package parts.
Use an existing heading style such as `Heading 1` for a requested heading, and
`Normal` for an ordinary new body paragraph after a heading.

Unqualified numeric-looking Word text is still text. For amounts that are plain
decimals, choose `kind:"number"` when the task and column make that intention
clear. Text sorting is Unicode case-folded; date sorting requires ISO
YYYY-MM-DD. Stable ties and duplicates remain. Blank cells sort last in both
directions. Never sort each column independently.

Merged/ragged/nested or annotated/rich-content tables and protected documents
are refused. Complex body fields and tracked changes are refused for structural
editing. Do not flatten them to bypass the refusal. A source table can be read
without altering other source content.

Example operations after inspecting a table with Name and Amount headers:

```json
[
  {"op":"append_rows","target":{"table_index":0},"rows":[["Alice","2.50"],["Bob","10"]]},
  {"op":"sort_rows","target":{"table_index":0},"keys":[{"column":"Amount","kind":"number","direction":"ascending"}]}
]
```

Pass these operations with `source_path` and its inspected `source_revision`
to `word_edit`. Omitting `output_name` creates a unique reviewed copy.
