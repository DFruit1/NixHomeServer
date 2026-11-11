# Excel editing

Prefer `spreadsheet_edit` for changes to existing XLSX tables. Call
`office_inspect` first to obtain exact worksheet/table names and the revision.
Use `spreadsheet_write(action="create")` for genuinely new workbooks, and the
older cell-patch tool only for intentional isolated A1/formula edits.

A target is `{"sheet":"Sales","table":"SalesData"}` or an explicit bounded
rectangle `{"sheet":"Sales","range":"A1:D20"}` including its header row.
For a clearly headerless rectangle, add `header_rows:0`. Prefer named tables:
their dimensions and autofilter bounds are updated automatically. Reusing the
same selector later in the batch uses its expanded/current bounds. Distinct
overlapping selectors are rejected. Only cells inside the selected table move;
the tool never inserts or deletes whole worksheet rows.

Operations:

- `append_rows` with literal `rows`; `insert_rows` with `row` and `rows`.
- `delete_rows` with `row` and `count` for intended removal.
- `set_cells` with `cells:[{row,column,value}]` for literal values.
- `set_formula` with `cells:[{row,column,formula:"=B2*C2"}]` for an intended
  calculation. Row and column selectors refer to 1-based data records, excluding
  headers/totals; A1 references inside formulas use real worksheet coordinates.
- `sort_rows` with 1–4 `keys:[{column,direction,kind}]`; all record cells move
  together. `auto` sorts typed numbers numerically and text case-insensitively.
  Mixed types need an explicit interpretation. Formula cells cannot be keys.
- `import_rows`: load the import skill for authorized, mapped source copying.

New rows inherit destination cell styles and supported calculated cells from
the last data row when a supplied value is null. Row-local formulas such as
`=B2*C2` are translated as records move or append. Explicit values override
inherited calculations. Structured current-row references and supported
structured SUM/SUBTOTAL-style totals can follow table growth. Fixed totals rows
stay at the bottom. Formula caches are invalidated; formulas are **not calculated**
by this service. Never use an old cache as evidence that a new result is right.

The editor checks for occupied cells below a growing table, adjacent tables,
incoming A1 dependencies, names, special/shared/array formulas and unsupported
metadata. Cross-record formulas, dynamic/external calculations, relevant
validation/conditional formatting, merged cells, comments, drawings/pivots and
active filters may require refusal. The refusal explains the actual limitation.
Do not replace the workbook from its read projection to bypass it.

Sorting includes all table data records, including manually hidden row
positions; row visibility/height settings stay at their worksheet positions.
Active filters are refused because saved hidden-row flags cannot be safely
reapplied here. Headers, totals, duplicates and stable ties are retained;
blank keys remain last in ascending and descending sorts.

Limits: 32 operations, 500 rows per insertion/import, 5000 data rows per target,
64 columns and 100000 affected cells per batch, inside the existing 32 MiB file
limit. These limits bound changes independently from the small inspected page.
After saving, inspect the output's table bounds, order and important formula
text. Report that Excel must recalculate when opened.
