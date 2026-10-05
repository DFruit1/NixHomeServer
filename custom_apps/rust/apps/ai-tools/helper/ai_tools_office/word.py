"""Native docx reads and writes with `python-docx`.

The Rust side of this closure has no usable Word pairing: the `docx` crate has
been unmaintained since 2020, so there is no reader, and `docx-rs` only writes.
`python-docx` is the mature component for both halves, which is why this
module exists alongside `spreadsheet.py` rather than instead of it.

A docx round-trip is not lossless in either direction, and pretending otherwise
would make the tool quietly wrong. What survives is the document's block
structure: paragraphs with their style, runs with their text and basic
character formatting, and tables with their cells. What does not survive is
tracked-change state, comments, embedded objects, and any content that lives
in parts `python-docx` does not model. The read side therefore reports what it
saw, and the write side says what it did not keep, rather than implying a
document round-trips intact.
"""

from __future__ import annotations

import base64
import io
import json
import sys
from typing import Any

import docx
from docx.document import Document as DocumentObject
from docx.table import Table
from docx.text.paragraph import Paragraph

#: Blocks returned per document. Same reasoning as the spreadsheet row ceiling:
#: the input is user-supplied and the process has a hard memory bound.
MAX_BLOCKS = 5000

#: Characters of text retained per block, so one enormous paragraph cannot
#: crowd every other block out of the response.
MAX_BLOCK_CHARS = 8192

#: Rows and columns per table, for the same reason.
MAX_TABLE_ROWS = 500
MAX_TABLE_COLUMNS = 64

NOT_RETAINED = [
    "tracked changes, revisions and their acceptance state",
    "comments and threaded discussion",
    "footnotes, endnotes and their references",
    "headers and footers, including first-page and even/odd variants",
    "embedded objects: images, charts, equations, OLE and media parts",
    "fields that were never calculated, so their displayed result is lost",
    "section properties beyond the final section, and document-level metadata",
    "numbering and list definitions resolve to their rendered text only",
]


def _iter_blocks(parent: DocumentObject) -> list[Any]:
    """Yield paragraphs and tables in document order.

    `python-docx` exposes body content as two independent collections, so the
    real order has to come from the XML element tree. A paragraph that appears
    after a table is a normal Word document, and returning all paragraphs then
    all tables would silently reorder the document.
    """
    blocks: list[Any] = []
    body = parent.element.body
    for child in body.iterchildren():
        tag = child.tag.split("}")[-1]
        if tag == "p":
            blocks.append(Paragraph(child, parent))
        elif tag == "tbl":
            blocks.append(Table(child, parent))
        if len(blocks) >= MAX_BLOCKS:
            break
    return blocks


def _paragraph_payload(paragraph: Paragraph) -> dict[str, Any]:
    text = paragraph.text
    truncated = len(text) > MAX_BLOCK_CHARS
    runs = [
        {
            "text": run.text[:MAX_BLOCK_CHARS],
            "bold": run.bold,
            "italic": run.italic,
        }
        for run in paragraph.runs[:256]
    ]
    return {
        "kind": "paragraph",
        "style": paragraph.style.name if paragraph.style is not None else None,
        "text": text[:MAX_BLOCK_CHARS],
        "text_truncated": truncated,
        "run_count": len(paragraph.runs),
        "runs": runs,
    }


def _table_payload(table: Table) -> dict[str, Any]:
    rows = []
    for row in table.rows[:MAX_TABLE_ROWS]:
        cells = [cell.text[:MAX_BLOCK_CHARS] for cell in row.cells[:MAX_TABLE_COLUMNS]]
        rows.append(cells)
    return {
        "kind": "table",
        "rows": rows,
        "row_count": len(rows),
        "declared_row_count": len(table.rows),
        "declared_column_count": len(table.columns),
    }


def _payload(blocks: list[Any]) -> dict[str, Any]:
    payloads = []
    truncated = False
    for block in blocks:
        if isinstance(block, Table):
            payload = _table_payload(block)
        else:
            payload = _paragraph_payload(block)
        truncated = truncated or payload.get("text_truncated", False)
        payloads.append(payload)
    return {
        "block_count": len(payloads),
        "truncated": truncated or len(blocks) >= MAX_BLOCKS,
        "blocks": payloads,
        "not_retained": NOT_RETAINED,
    }


def read(document: bytes) -> dict[str, Any]:
    """Read a docx's block structure from bytes.

    Bytes rather than a path for the same reason as the spreadsheet side: the
    caller owns containment, and this package never opens a file for reading.
    """
    parsed = docx.Document(io.BytesIO(document))
    return _payload(_iter_blocks(parsed))


def write(spec: dict[str, Any], path: str) -> dict[str, Any]:
    """Write blocks from a spec to a native docx at `path`.

    `path` is absolute and has already been resolved inside the AI workspace by
    the caller. Nothing here resolves, contains or re-checks it.
    """
    blocks = spec.get("blocks")
    if not isinstance(blocks, list) or not blocks:
        raise ValueError("spec must carry a non-empty 'blocks' array")

    document = docx.Document()
    for entry in blocks:
        if not isinstance(entry, dict):
            raise ValueError("every block must be an object")
        kind = entry.get("kind", "paragraph")
        if kind == "paragraph":
            paragraph = document.add_paragraph()
            style = entry.get("style")
            if isinstance(style, str) and style.strip():
                paragraph.style = document.styles[style]
            _add_runs(paragraph, entry.get("runs"), entry.get("text"))
        elif kind == "table":
            _add_table(document, entry)
        else:
            raise ValueError(f"unknown block kind {kind!r}")

    document.save(path)
    return {
        "path": path,
        "block_count": len(blocks),
        "not_retained": NOT_RETAINED,
    }


def _add_runs(paragraph: Paragraph, runs: Any, text: Any) -> None:
    """Add run-level content, preferring explicit runs over plain text."""
    if isinstance(runs, list) and runs:
        for entry in runs:
            if not isinstance(entry, dict):
                raise ValueError("every run must be an object")
            value = entry.get("text")
            if not isinstance(value, str):
                raise ValueError("every run needs a 'text' string")
            run = paragraph.add_run(value[:MAX_BLOCK_CHARS])
            if entry.get("bold") is True:
                run.bold = True
            if entry.get("italic") is True:
                run.italic = True
        return
    if isinstance(text, str):
        paragraph.add_run(text[:MAX_BLOCK_CHARS])


def _add_table(document: DocumentObject, entry: dict[str, Any]) -> None:
    rows = entry.get("rows")
    if not isinstance(rows, list) or not rows:
        raise ValueError("a table block needs a non-empty 'rows' array")
    clamped = [row[:MAX_TABLE_COLUMNS] for row in rows[:MAX_TABLE_ROWS]]
    width = max((len(row) for row in clamped), default=0)
    table = document.add_table(rows=len(clamped), cols=max(width, 1))
    for row_index, row in enumerate(clamped):
        for column_index, value in enumerate(row):
            cell = table.cell(row_index, column_index)
            cell.text = str(value)[:MAX_BLOCK_CHARS] if value is not None else ""


def _main() -> int:
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