"""All-sheet spreadsheet reads and native xlsx writes.

Collabora's convert-to endpoint exports a workbook's first sheet only, which is
why `convert_document` cannot answer "analyse this Excel file" about a real
workbook. This module reads every sheet with `openpyxl`, which is why the read
tool exists separately from the converter.

Cell values are reported as they are stored. `openpyxl` is opened with
`data_only=False` deliberately: with `data_only=True` a formula cell yields the
cached result Excel wrote last, which is `None` for any workbook this helper
itself produced, because nothing has recalculated it. Reading the stored value
instead means a formula comes back as its formula text and a literal comes back
as its literal, which is at least never silently empty.
"""

from __future__ import annotations

import base64
import datetime
import io
import json
import math
import sys
from typing import Any

import openpyxl

#: Rows returned per sheet before truncation. The shared root is user-writable
#: and the caller holds a hard MemoryHigh, so a workbook with a million rows is
#: refused by the size check before it is parsed rather than by this ceiling.
MAX_ROWS_PER_SHEET = 2000

#: Cells returned per row. A spreadsheet with a few very wide columns is real,
#: but a model cannot use 16k columns and the payload has to stay bounded.
MAX_COLUMNS = 64

#: Total characters of cell text per sheet, so one sheet of long strings cannot
#: fill the response while every other sheet comes back empty.
MAX_CELL_CHARS_PER_SHEET = 256 * 1024

#: Ceiling on sheets handled per call, because a zip bomb of empty sheets parses
#: cheaply enough that the input size check alone does not bound it.
MAX_SHEETS = 256

#: xlsx's own sheet-name rules, checked here so a rejected name is a tool error
#: with a clear reason rather than a library traceback.
MAX_SHEET_NAME_CHARS = 31
ILLEGAL_SHEET_NAME_CHARS = set("[]:*?/\\")

NOT_RETAINED = [
    "cell formatting: fonts, fills, borders, number formats and column widths",
    "merged cell ranges",
    "conditional formatting, data validation and named ranges",
    "charts, images, pivot tables and their caches",
    "cell comments, hyperlinks and threaded discussion",
    "the cached result of a formula; formula text is returned instead",
    "hidden rows and columns are returned, but not marked as hidden",
    "the date/datetime distinction; a bare date reads back as midnight",
]


def _cell_value(value: Any) -> Any:
    """Reduce a stored cell value to something JSON can carry."""
    if value is None or isinstance(value, (bool, int, str)):
        return value
    if isinstance(value, float):
        # JSON has no NaN or Infinity, and a spreadsheet legitimately holds both
        # as error values rather than as numbers.
        if math.isnan(value) or math.isinf(value):
            return str(value)
        return value
    if isinstance(value, (datetime.datetime, datetime.date, datetime.time)):
        return value.isoformat()
    if isinstance(value, datetime.timedelta):
        return str(value)
    if isinstance(value, bytes):
        return value.decode("utf-8", "replace")
    return str(value)


def _sheet_rows(sheet: Any) -> tuple[list[list[Any]], bool, bool]:
    """Return the sheet's rows, whether rows/text were truncated, and whether columns were.

    `iter_rows` is deliberately called without `max_col`: passing one makes
    openpyxl pad *every* row out to that width, so a two-column sheet comes
    back as 65 cells per row, 63 of them None. The width is measured from the
    sheet instead and applied here, which is also the only way a caller learns
    that columns were dropped rather than silently receiving fewer cells.
    """
    rows: list[list[Any]] = []
    spent = 0
    truncated = False
    truncated_columns = sheet.max_column > MAX_COLUMNS

    # No max_row bound here either: openpyxl materialises exactly that many rows
    # whether or not the sheet has them, so an oversized-but-sparse sheet would
    # come back padded with thousands of empty rows. The break below stops after
    # MAX_ROWS_PER_SHEET + 1 iterations, which is the same amount of work the
    # bound cost while reading nothing the sheet does not actually contain.
    for index, row in enumerate(sheet.iter_rows()):
        if index >= MAX_ROWS_PER_SHEET:
            truncated = True
            break
        values = [_cell_value(cell.value) for cell in row][:MAX_COLUMNS]
        # openpyxl pads every row to the sheet's widest row; those empty cells
        # are not part of the data and would otherwise make a round-trip of a
        # ragged sheet look like every row gained cells.
        while values and values[-1] is None:
            values.pop()
        for value in values:
            if isinstance(value, str):
                spent += len(value)
        rows.append(values)
        if spent >= MAX_CELL_CHARS_PER_SHEET:
            truncated = True
            break
    return rows, truncated, truncated_columns


def _validate_sheet_name(name: Any) -> str:
    if not isinstance(name, str) or not name.strip():
        raise ValueError("every sheet needs a non-empty 'name'")
    if len(name) > MAX_SHEET_NAME_CHARS:
        raise ValueError(f"sheet name {name!r} is longer than {MAX_SHEET_NAME_CHARS} characters")
    if set(name) & ILLEGAL_SHEET_NAME_CHARS:
        raise ValueError(f"sheet name {name!r} contains a character xlsx does not allow")
    return name


def read(document: bytes) -> dict[str, Any]:
    """Read every sheet of an xlsx workbook into JSON-ready rows.

    The document arrives as bytes rather than a path: the caller owns
    containment and hands over only the document it already validated, so
    nothing in this package ever opens a file for reading.
    """
    workbook = openpyxl.load_workbook(io.BytesIO(document), data_only=False)
    try:
        sheets: list[dict[str, Any]] = []
        truncated = False
        truncated_columns = False
        declared = len(workbook.worksheets)
        for sheet in workbook.worksheets[:MAX_SHEETS]:
            rows, row_truncated, columns_dropped = _sheet_rows(sheet)
            truncated = truncated or row_truncated
            truncated_columns = truncated_columns or columns_dropped
            sheets.append(
                {
                    "name": sheet.title,
                    "state": sheet.sheet_state,
                    "rows": rows,
                    "row_count": len(rows),
                    "declared_row_count": sheet.max_row,
                }
            )
        if declared > len(sheets):
            truncated = True
        return {
            "sheet_count": len(sheets),
            "declared_sheet_count": declared,
            "truncated": truncated,
            "truncated_columns": truncated_columns,
            "sheets": sheets,
            "not_retained": NOT_RETAINED,
        }
    finally:
        workbook.close()


def _validate_cell(value: Any, sheet: str) -> Any:
    """Refuse a cell value that xlsx cannot actually store.

    openpyxl does not raise on NaN or Infinity: it writes them as empty cells,
    so a workbook silently loses them and the read back reports `None`. Since
    this helper's whole purpose is a round-trip that does not quietly drop
    things, it is better to refuse the value and name the cell than to accept
    it and lose it without saying so.
    """
    if isinstance(value, float) and (math.isnan(value) or math.isinf(value)):
        raise ValueError(
            f"sheet {sheet!r}: {value} cannot be stored in xlsx and would be "
            "written as an empty cell; write it as the text 'nan' or 'inf' "
            "if that is what the value means"
        )
    return value


def write(spec: dict[str, Any], path: str) -> dict[str, Any]:
    """Write sheets from a spec to a native xlsx workbook at `path`.

    `path` is absolute and has already been resolved inside the AI workspace by
    the caller. Nothing here resolves, contains or re-checks it: the property
    that matters is that no code path in this package can turn a relative or
    traversing path into a write, and the only path it uses is the one it was
    given.
    """
    entries = spec.get("sheets")
    if not isinstance(entries, list) or not entries:
        raise ValueError("spec must carry a non-empty 'sheets' array")
    if len(entries) > MAX_SHEETS:
        raise ValueError(f"at most {MAX_SHEETS} sheets can be written at once")

    # Every name is validated before anything is written, so a bad name in the
    # last sheet cannot leave a half-built workbook on disk.
    names = [_validate_sheet_name(entry.get("name")) for entry in entries]

    # Every cell is validated before anything is written, so a bad value in the
    # last sheet cannot leave a half-built workbook on disk.
    for entry, name in zip(entries, names, strict=True):
        rows = entry.get("rows")
        if not isinstance(rows, list):
            raise ValueError(f"sheet {name!r} needs a 'rows' array")
        for row in rows:
            if not isinstance(row, list):
                raise ValueError(f"sheet {name!r} has a row that is not an array")
            for value in row[:MAX_COLUMNS]:
                _validate_cell(value, name)

    workbook = openpyxl.Workbook()
    # openpyxl's fresh workbook already holds one empty sheet. It is renamed for
    # the first spec entry rather than removed, so a single-sheet document is
    # never left holding a stray "Sheet" the caller did not ask for and the
    # workbook never has zero sheets at save time.
    workbook.worksheets[0].title = names[0]
    for name in names[1:]:
        workbook.create_sheet(title=name)

    # Rows were validated above, so this loop only builds the workbook.
    for sheet, entry in zip(workbook.worksheets, entries, strict=True):
        for row in entry["rows"]:
            sheet.append(row[:MAX_COLUMNS])

    workbook.active = 0
    workbook.save(path)
    workbook.close()
    return {"path": path, "sheets": names, "sheet_count": len(names), "not_retained": NOT_RETAINED}


def _main() -> int:
    """Single-module entry point, used by the package tests and for debugging."""
    request = json.load(sys.stdin)
    operation = request.get("op")
    if operation == "read":
        result = read(base64.b64decode(request["document"]))
    elif operation == "write":
        result = write(request["spec"], request["path"])
    else:
        raise ValueError(f"unknown operation {operation!r}")
    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(_main())
    except SystemExit:
        raise
    except Exception as error:  # noqa: BLE001 - reported as a tool error, not a traceback
        json.dump({"error": str(error)}, sys.stderr)
        raise SystemExit(1) from None