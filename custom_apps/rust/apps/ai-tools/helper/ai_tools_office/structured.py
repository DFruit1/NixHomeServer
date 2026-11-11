"""Revision-bound inspection/import/edit batches for the authenticated gateway."""
from __future__ import annotations

import base64
from contextlib import ExitStack
from copy import deepcopy
import json
from lxml import etree
from . import ooxml
from .edit_common import revision, pin, fields, integer, matrix, permutation, column, mapped_rows, MAX_CHANGED_CELLS
from .excel_edit import ExcelDocument
from .word_edit import WordDocument, plain, new_cell, Q as WQ


def model(archive, format):
    if format == "xlsx":
        return ExcelDocument(archive)
    if format == "docx":
        return WordDocument(archive)
    raise ValueError("structural inspection/edits require native xlsx or docx")


def clean_selector(selector, format):
    if format == "xlsx":
        fields(selector, ("sheet",), ("table", "range", "header_rows"))
    else:
        fields(selector, ("table_index",), ("header_rows",))
    return selector


def bounded(result):
    # Count encoded bytes, not Python characters. A response must fit both the
    # Rust pipe limit and the small model's usable context; never split JSON.
    items = result.pop("items")
    selected = []
    for item in items:
        candidate = {**result, "items": selected + [item]}
        if len(json.dumps(candidate, ensure_ascii=True).encode()) > 24000:
            break
        selected.append(item)
    if not selected and items:
        raise ValueError("one inspected entry exceeds the view budget; inspect fewer columns or a smaller text block")
    if len(selected) < len(items):
        result["next_offset"] = result.get("offset", 0) + len(selected)
    result["items"] = selected
    return result


def inspect(document, format, options):
    fields(options, (), ("view", "selector", "offset", "limit"))
    offset = integer(options.get("offset", 0), 0, 1048576, "offset")
    limit = integer(options.get("limit", 20), 1, 100, "limit")
    view = options.get("view", "structure")
    with ooxml.package(document) as archive:
        doc = model(archive, format)
        if view == "structure":
            result = doc.describe(offset, limit)
        elif view == "table":
            table = doc.table(clean_selector(options.get("selector"), format))
            records = table.records[offset:offset + limit]
            result = {**table.info(), "items": [{"row": offset + i + 1, "values": table.values(r, True) if format == "xlsx" else table.values(r)} for i, r in enumerate(records)],
                      "next_offset": offset + len(records) if offset + len(records) < len(table.records) else None}
            result["edit_target"] = options["selector"]
        else:
            raise ValueError("view must be structure or table")
        try:
            if format == "docx":
                doc.guard()
            elif view == "table":
                doc.dependencies(table, table.area)
            result["editable"] = True
        except ValueError as error:
            result.update(editable=False, refusal_reason=str(error))
        result.update(revision=revision(document), format=format, offset=offset, view_only=True,
                      row_indexing="1-based data rows, excluding fixed header/totals rows; offset is zero-based",
                      supported_operations=["append_rows", "insert_rows", "delete_rows", "set_cells", "sort_rows", "import_rows"] + (["set_formula"] if format == "xlsx" else ["paragraph_set", "paragraph_insert", "paragraph_append"]),
                      limits={"operations": 32, "rows_per_insert_or_import": 500, "data_rows_per_table": 5000, "columns": 64, "changed_cells_per_batch": MAX_CHANGED_CELLS})
        return bounded(result)


def imported(operation, sources, stack, destination):
    source = operation["source"]
    fields(source, ("path", "revision", "selector"), ("offset", "limit"))
    if source["path"] not in sources:
        raise ValueError("import source was not authorized by the file broker")
    value = sources[source["path"]]
    raw = base64.b64decode(value["document"], validate=True)
    pin(raw, source["revision"])
    archive = stack.enter_context(ooxml.package(raw))
    doc = model(archive, value["format"])
    table = doc.table(clean_selector(source["selector"], value["format"]))
    offset = integer(source.get("offset", 0), 0, len(table.records), "source offset")
    limit = integer(source.get("limit", 500), 1, 500, "source limit")
    if "limit" not in source and len(table.records) - offset > limit:
        raise ValueError("source has more than 500 rows; select an explicit page instead of silently truncating the import")
    records = table.records[offset:offset + limit]
    if not records:
        raise ValueError("source selection contains no data rows")
    values = [table.values(row) for row in records]
    return mapped_rows(table.column_headers, values, destination.column_headers, operation.get("column_map"))


def paragraph_operation(doc, operation):
    if operation["op"] == "paragraph_append":
        fields(operation, ("op", "text"), ("style",))
        anchor, where = None, "after"
    else:
        fields(operation, ("op", "paragraph_index", "text"), ("where", "style"))
        index = integer(operation["paragraph_index"], 0, len(doc.paragraphs) - 1, "paragraph_index")
        anchor = doc.paragraphs[index]
        where = operation.get("where", "after")
        plain(anchor)
    if where not in ("before", "after") or not isinstance(operation["text"], str) or "\n" in operation["text"]:
        raise ValueError("paragraph text must be one paragraph; where must be before or after")
    fake = etree.Element(WQ("tc"))
    fake.append(deepcopy(anchor) if anchor is not None else etree.Element(WQ("p")))
    paragraph = new_cell(fake, operation["text"]).find(WQ("p"))
    if "style" in operation:
        if not isinstance(operation["style"], str):
            raise ValueError("style must be an existing style name or ID")
        styles = ooxml.xml(doc.archive.read("word/styles.xml"))
        matches = [s.get(WQ("styleId")) for s in styles.findall(WQ("style")) if s.get(WQ("type")) == "paragraph" and operation["style"].casefold() in (s.get(WQ("styleId"), "").casefold(), s.find(WQ("name")).get(WQ("val"), "").casefold() if s.find(WQ("name")) is not None else "")]
        if len(matches) != 1:
            raise ValueError("paragraph style is missing or ambiguous")
        prop = paragraph.find(WQ("pPr"))
        if prop is None:
            prop = etree.Element(WQ("pPr")); paragraph.insert(0, prop)
        for old in prop.findall(WQ("pStyle")):
            prop.remove(old)
        style = etree.Element(WQ("pStyle")); style.set(WQ("val"), matches[0]); prop.insert(0, style)
    if operation["op"] == "paragraph_set":
        # Text replacement retains a section break at that original paragraph;
        # insertion must never duplicate the anchor's section properties.
        old_properties = anchor.find(WQ("pPr"))
        if old_properties is not None:
            current = paragraph.find(WQ("pPr"))
            if current is None:
                current = etree.Element(WQ("pPr")); paragraph.insert(0, current)
            for prop in old_properties:
                if prop.tag in {WQ("sectPr"), WQ("pageBreakBefore")}:
                    current.append(deepcopy(prop))
        tail = getattr(doc, "insertion_tails", {})
        if anchor in tail:
            tail[paragraph] = tail.pop(anchor)
        doc.body.replace(anchor, paragraph)
        doc.paragraphs[index] = paragraph
    elif anchor is None:
        section = doc.body.find(WQ("sectPr"))
        doc.body.insert(doc.body.index(section) if section is not None else len(doc.body), paragraph)
    else:
        if where == "after":
            # Repeated insertions after one revision-bound anchor retain batch order.
            tail = getattr(doc, "insertion_tails", {})
            previous = tail.get(anchor, anchor)
            doc.body.insert(doc.body.index(previous) + 1, paragraph)
            tail[anchor] = paragraph; doc.insertion_tails = tail
        else:
            doc.body.insert(doc.body.index(anchor), paragraph)


def edit(document, format, expected, operations, sources):
    pin(document, expected)
    if not isinstance(operations, list) or not 1 <= len(operations) <= 32:
        raise ValueError("an edit batch needs 1–32 operations")
    if len(json.dumps(operations).encode()) > 256 * 1024:
        raise ValueError("operation arguments exceed 256 KiB")
    if not isinstance(sources, dict) or len(sources) > 4:
        raise ValueError("an edit batch can import at most four authorized documents")
    if len(document) + sum(len(base64.b64decode(value["document"], validate=True)) for value in sources.values()) > ooxml.MAX_DOCUMENT_BYTES:
        raise ValueError("combined input documents exceed the 32 MiB batch limit")
    with ExitStack() as stack:
        archive = stack.enter_context(ooxml.package(document))
        if any(n.lower().startswith("_xmlsignatures/") or n.lower().endswith("vbaproject.bin") for n in archive.namelist()):
            raise ValueError("signed/macro packages cannot be edited")
        doc = model(archive, format)
        if format == "docx":
            doc.guard()
        changes, budget = [], 0
        for operation in operations:
            if not isinstance(operation, dict):
                raise ValueError("each operation must be an object")
            kind = operation.get("op")
            if kind in ("paragraph_set", "paragraph_insert", "paragraph_append") and format == "docx":
                paragraph_operation(doc, operation)
                changes.append({"op": kind, "paragraph_index": operation.get("paragraph_index")})
                continue
            allowed = {
                "append_rows": (("rows",), ()),
                "insert_rows": (("row", "rows"), ()),
                "delete_rows": (("row", "count"), ()),
                "set_cells": (("cells",), ()),
                "set_formula": (("cells",), ()),
                "sort_rows": (("keys",), ()),
                "import_rows": (("source",), ("column_map", "row")),
            }
            if kind not in allowed:
                raise ValueError("unknown document operation")
            required, optional = allowed[kind]
            fields(operation, ("op", "target") + required, optional)
            target = clean_selector(operation["target"], format)
            table = doc.table(target)
            budget += max(1, len(table.records)) * table.width
            if budget > MAX_CHANGED_CELLS:
                raise ValueError("batch exceeds 100000 affected cells; split into intentional smaller edits")
            before = len(table.records)
            if kind in ("append_rows", "insert_rows", "import_rows"):
                values = imported(operation, sources, stack, table) if kind == "import_rows" else matrix(operation["rows"], table.width)
                values = matrix(values, table.width)
                row = integer(operation.get("row", len(table.records) + 1), 1, len(table.records) + 1, "row")
                table.records[row - 1:row - 1] = [table.make(r) for r in values]
                budget += len(values) * table.width
            elif kind == "delete_rows":
                row = integer(operation["row"], 1, len(table.records), "row")
                count = integer(operation["count"], 1, len(table.records) - row + 1, "count")
                del table.records[row - 1:row - 1 + count]
            elif kind in ("set_cells", "set_formula"):
                if kind == "set_formula" and format != "xlsx":
                    raise ValueError("set_formula requires an Excel target")
                cells = operation["cells"]
                if not isinstance(cells, list) or not 1 <= len(cells) <= 1000:
                    raise ValueError("set_cells needs 1–1000 entries")
                seen = set()
                for cell in cells:
                    fields(cell, ("row", "column", "formula" if kind == "set_formula" else "value"))
                    row = integer(cell["row"], 1, len(table.records), "row") - 1
                    col = column(cell["column"], table.column_headers, table.width)
                    if (row, col) in seen:
                        raise ValueError("set_cells repeats a target")
                    seen.add((row, col))
                    if kind == "set_formula":
                        table.set_formula(table.records[row], col, cell["formula"])
                    else:
                        table.set_cell(table.records[row], col, cell["value"])
            elif kind == "sort_rows":
                rows = [table.values(r, True) for r in table.records] if format == "xlsx" else [table.values(r) for r in table.records]
                order = permutation(rows, table.column_headers, operation["keys"])
                table.records = [table.records[i] for i in order]
            if budget > MAX_CHANGED_CELLS:
                raise ValueError("batch exceeds 100000 affected cells")
            table.commit()
            changes.append({"op": kind, "before_rows": before, "after_rows": len(table.records), "target": {k: v for k, v in table.info().items() if k != "headers"}})
        output = doc.finish()
        return {"document": base64.b64encode(output).decode("ascii"), "revision": revision(output), "source_revision": expected,
                "changes": changes, "recalculated": False,
                "warnings": ["Formulas are not calculated here; open Excel to recalculate."] if format == "xlsx" else []}
