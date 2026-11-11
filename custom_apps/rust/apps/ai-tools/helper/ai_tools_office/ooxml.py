"""Bounded OOXML package edits that retain every untouched ZIP member.

Rebuilding a workbook/document from its read projection drops user data. These
operations instead edit only explicitly selected cells or text, return a new
package, and never open a filesystem path. Signatures/macros/tracked changes
are refused where an edit could misrepresent their meaning.
"""
from __future__ import annotations

import io
import math
import re
import zipfile
from typing import Any
from lxml import etree

MAX_DOCUMENT_BYTES = 32 * 1024 * 1024
MAX_EXPANDED_BYTES = 64 * 1024 * 1024
MAX_MEMBER_BYTES = 16 * 1024 * 1024
MAX_MEMBERS = 4096
S = "http://schemas.openxmlformats.org/spreadsheetml/2006/main"
W = "http://schemas.openxmlformats.org/wordprocessingml/2006/main"
R = "http://schemas.openxmlformats.org/officeDocument/2006/relationships"
P = "http://schemas.openxmlformats.org/package/2006/relationships"


def package(document: bytes) -> zipfile.ZipFile:
    if len(document) > MAX_DOCUMENT_BYTES:
        raise ValueError("document exceeds the 32 MiB input limit")
    archive = zipfile.ZipFile(io.BytesIO(document))
    infos = archive.infolist()
    names = [i.filename for i in infos]
    if len(infos) > MAX_MEMBERS or len(names) != len(set(names)):
        raise ValueError("document has too many or duplicate package members")
    if sum(i.file_size for i in infos) > MAX_EXPANDED_BYTES:
        raise ValueError("expanded document exceeds the 64 MiB limit")
    for entry in infos:
        if entry.file_size > MAX_MEMBER_BYTES or entry.flag_bits & 1:
            raise ValueError("document contains an oversized or encrypted package member")
        if entry.filename.startswith("/") or "\\" in entry.filename or any(p == ".." for p in entry.filename.split("/")):
            raise ValueError("document contains an unsafe package member")
    return archive


def xml(data: bytes) -> Any:
    root = etree.fromstring(data, etree.XMLParser(resolve_entities=False, no_network=True))
    if root.getroottree().docinfo.doctype:
        raise ValueError("document type declarations are not supported")
    return root


def encode(root: Any) -> bytes:
    return etree.tostring(root, xml_declaration=True, encoding="UTF-8", standalone=True)


def rewrite(archive: zipfile.ZipFile, updates: dict[str, bytes], remove: set[str] | None = None) -> bytes:
    output = io.BytesIO()
    remove = remove or set()
    with zipfile.ZipFile(output, "w") as result:
        for entry in archive.infolist():
            if entry.filename not in remove:
                result.writestr(entry, updates.get(entry.filename, archive.read(entry)))
    data = output.getvalue()
    if len(data) > MAX_DOCUMENT_BYTES:
        raise ValueError("edited document exceeds the 32 MiB output limit")
    return data


def edit(document: bytes, format: str, spec: dict[str, Any]) -> bytes:
    with package(document) as archive:
        if any(n.lower().startswith("_xmlsignatures/") or n.lower().endswith("vbaproject.bin") for n in archive.namelist()):
            raise ValueError("editing signed or macro-enabled documents is not supported")
        if format == "xlsx":
            return edit_spreadsheet(archive, spec)
        if format == "docx":
            return edit_word(archive, spec)
        raise ValueError("only native xlsx/docx documents support targeted edits")


def edit_spreadsheet(archive: zipfile.ZipFile, spec: dict[str, Any]) -> bytes:
    edits = spec.get("cells")
    if not isinstance(edits, list) or not 1 <= len(edits) <= 256:
        raise ValueError("edits need 1–256 cells: sheet, cell, value")
    workbook = xml(archive.read("xl/workbook.xml"))
    relationships = xml(archive.read("xl/_rels/workbook.xml.rels"))
    targets = {r.get("Id"): r.get("Target") for r in relationships}
    sheets = {}
    for sheet in workbook.findall(f"{{{S}}}sheets/{{{S}}}sheet"):
        target = targets.get(sheet.get(f"{{{R}}}id"), "")
        path = target.lstrip("/") if target.startswith("/") else "xl/" + target
        if not path.startswith("xl/") or ".." in path.split("/"):
            raise ValueError("unsupported worksheet relationship")
        sheets[sheet.get("name")] = path
    trees = {}
    seen = set()
    for entry in edits:
        if not isinstance(entry, dict) or set(entry) != {"sheet", "cell", "value"}:
            raise ValueError("each cell edit needs exactly sheet, cell and value")
        name, address, value = entry["sheet"], entry["cell"], entry["value"]
        if name not in sheets or not isinstance(address, str) or not re.fullmatch(r"[A-Z]{1,3}[1-9][0-9]{0,6}", address):
            raise ValueError("unknown sheet or invalid cell reference")
        from openpyxl.utils.cell import coordinate_from_string, column_index_from_string
        column, number = coordinate_from_string(address)
        if number > 1048576 or column_index_from_string(column) > 16384 or (name, address) in seen:
            raise ValueError("duplicate or out-of-range cell edit")
        seen.add((name, address))
        if value is not None and type(value) not in (str, bool, int, float):
            raise ValueError("cell values must be text, numbers, booleans or null")
        if isinstance(value, str) and len(value) > 32767:
            raise ValueError("cell text exceeds Excel's 32767-character limit")
        if isinstance(value, (int, float)) and not isinstance(value, bool) and (not math.isfinite(value) or abs(value) > 2**53):
            raise ValueError("number cannot be represented safely; use text")
        path = sheets[name]
        if path not in trees:
            trees[path] = xml(archive.read(path))
        tree = trees[path]
        from openpyxl.utils.cell import range_boundaries
        col_number = column_index_from_string(column)
        for merged in tree.findall(f"{{{S}}}mergeCells/{{{S}}}mergeCell"):
            left, top, right, bottom = range_boundaries(merged.get("ref", ""))
            if left <= col_number <= right and top <= number <= bottom and (col_number, number) != (left, top):
                raise ValueError("edit the anchor cell of a merged range")
        for special in tree.findall(f".//{{{S}}}f"):
            if special.get("t") not in (None, "normal"):
                reference = special.get("ref")
                if reference is None:
                    raise ValueError("worksheet contains a shared/array formula without a bounded range")
                left, top, right, bottom = range_boundaries(reference)
                if left <= col_number <= right and top <= number <= bottom:
                    raise ValueError("editing shared/array/data-table formula ranges is not supported")
        if tree.find(f"{{{S}}}sheetProtection") is not None:
            raise ValueError("remove worksheet protection before editing")
        cells = tree.find(f"{{{S}}}sheetData")
        if cells is None:
            raise ValueError("worksheet has no cell data")
        row = cells.find(f"{{{S}}}row[@r='{number}']")
        if row is None:
            row = etree.Element(f"{{{S}}}row", r=str(number))
            index = next((i for i, r in enumerate(cells) if int(r.get("r", "0")) > number), len(cells))
            cells.insert(index, row)
        cell = row.find(f"{{{S}}}c[@r='{address}']")
        if cell is None:
            cell = etree.Element(f"{{{S}}}c", r=address)
            col = column_index_from_string(column)
            index = next((i for i, c in enumerate(row) if column_index_from_string(coordinate_from_string(c.get("r"))[0]) > col), len(row))
            row.insert(index, cell)
        formula = cell.find(f"{{{S}}}f")
        if formula is not None and formula.get("t") not in (None, "normal"):
            raise ValueError("editing shared/array/data-table formulas is not supported")
        for child in list(cell):
            if child.tag not in {f"{{{S}}}f", f"{{{S}}}v", f"{{{S}}}is"}:
                raise ValueError("cell has unsupported extension content")
            cell.remove(child)
        cell.attrib.pop("t", None)
        if isinstance(value, str) and value.startswith("="):
            etree.SubElement(cell, f"{{{S}}}f").text = value[1:]
        elif isinstance(value, str):
            cell.set("t", "inlineStr")
            text = etree.SubElement(etree.SubElement(cell, f"{{{S}}}is"), f"{{{S}}}t")
            text.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
            text.text = value
        elif value is not None:
            cell.set("t", "b" if isinstance(value, bool) else "n")
            etree.SubElement(cell, f"{{{S}}}v").text = str(int(value)) if isinstance(value, bool) else str(value)
        dimension = tree.find(f"{{{S}}}dimension")
        if dimension is not None:
            tree.remove(dimension) # consumers derive dimensions from actual cells
    # Cached formula results are stale after an edit, including other sheets.
    for path in sheets.values():
        tree = trees.get(path)
        if tree is None:
            tree = xml(archive.read(path))
        for cell in tree.findall(f".//{{{S}}}c[{{{S}}}f]"):
            cached = cell.find(f"{{{S}}}v")
            if cached is not None:
                cell.remove(cached)
        trees[path] = tree
    calc = workbook.find(f"{{{S}}}calcPr")
    if calc is None:
        calc = etree.SubElement(workbook, f"{{{S}}}calcPr")
    calc.attrib.update({"fullCalcOnLoad": "1", "forceFullCalc": "1", "calcMode": "auto"})
    remove = set()
    for rel in list(relationships):
        if rel.get("Type", "").endswith("/calcChain"):
            target = rel.get("Target", "")
            remove.add(target.lstrip("/") if target.startswith("/") else "xl/" + target)
            relationships.remove(rel)
    content = xml(archive.read("[Content_Types].xml"))
    for item in list(content):
        if item.get("PartName", "").lstrip("/") in remove:
            content.remove(item)
    updates = {p: encode(t) for p, t in trees.items()}
    updates.update({"xl/workbook.xml": encode(workbook), "xl/_rels/workbook.xml.rels": encode(relationships), "[Content_Types].xml": encode(content)})
    return rewrite(archive, updates, remove)


def edit_word(archive: zipfile.ZipFile, spec: dict[str, Any]) -> bytes:
    edits = spec.get("replacements")
    if not isinstance(edits, list) or not 1 <= len(edits) <= 64:
        raise ValueError("edits need 1–64 exact text replacements: find and replace")
    root = xml(archive.read("word/document.xml"))
    if any(root.find(f".//{{{W}}}{tag}") is not None for tag in ("ins", "del", "moveFrom", "moveTo")):
        raise ValueError("resolve tracked changes before editing this document")
    if root.find(f".//{{{W}}}fldChar") is not None:
        raise ValueError("editing documents containing complex body fields is not supported")
    for entry in edits:
        if not isinstance(entry, dict) or set(entry) != {"find", "replace"} or not isinstance(entry["find"], str) or not isinstance(entry["replace"], str) or not entry["find"] or max(len(entry["find"]), len(entry["replace"])) > 8192:
            raise ValueError("each replacement needs nonempty find and replacement text up to 8192 characters")
        if any(c in entry["find"] + entry["replace"] for c in "\r\n\t"):
            raise ValueError("replacements must be single-line paragraph text without tabs")
        matches = []
        for paragraph in root.iter(f"{{{W}}}p"):
            nodes = [node for node in paragraph.iter(f"{{{W}}}t")
                     if next(node.iterancestors(f"{{{W}}}p"), None) is paragraph]
            text = "".join(n.text or "" for n in nodes)
            start = text.find(entry["find"])
            if start >= 0:
                matches.append((paragraph, nodes, start))
                if text.find(entry["find"], start + 1) >= 0:
                    raise ValueError("replacement text is ambiguous; provide a unique phrase")
        if len(matches) != 1:
            raise ValueError("replacement text must match exactly once")
        paragraph, nodes, start = matches[0]
        # Preserve text-only semantics: w:t concatenation omits visible symbols,
        # field results and references. Do not match across such constructs.
        allowed = {f"{{{W}}}{tag}" for tag in ("p", "r", "t", "hyperlink", "bookmarkStart", "bookmarkEnd", "proofErr")}
        properties = {f"{{{W}}}pPr", f"{{{W}}}rPr"}
        for node in paragraph.iter():
            if node.tag in properties or any(parent.tag in properties for parent in node.iterancestors()):
                continue
            if node.tag not in allowed:
                raise ValueError("editing paragraphs with non-text constructs or fields is not supported")
        if any(parent.tag in {f"{{{W}}}drawing", f"{{{W}}}pict", f"{{{W}}}object"} for parent in paragraph.iterancestors()):
            raise ValueError("editing text embedded in a drawing/object is not supported")
        end = start + len(entry["find"])
        offset = 0
        inserted = False
        for node in nodes:
            text = node.text or ""
            left, right = max(0, start - offset), min(len(text), end - offset)
            if left < right:
                node.text = text[:left] + (entry["replace"] if not inserted else "") + text[right:]
                node.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
                inserted = True
            offset += len(text)
    return rewrite(archive, {"word/document.xml": encode(root)})
