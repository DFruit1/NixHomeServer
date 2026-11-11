"""OOXML table-local record editing without a lossy workbook round trip."""
from __future__ import annotations

from copy import deepcopy
from decimal import Decimal
import posixpath
import re
from lxml import etree
from openpyxl.formula.tokenizer import Tokenizer
from openpyxl.formula.translate import Translator
from openpyxl.utils.cell import range_boundaries, get_column_letter, coordinate_from_string, column_index_from_string
from . import ooxml
from .edit_common import MAX_ROWS, MAX_COLUMNS, scalar

S, R = ooxml.S, ooxml.R
Q = lambda tag: f"{{{S}}}{tag}"


def bounds(value):
    if not isinstance(value, str) or not re.fullmatch(r"[A-Z]{1,3}[1-9][0-9]*:[A-Z]{1,3}[1-9][0-9]*", value):
        raise ValueError("range must be a bounded A1 rectangle such as A1:D20")
    left, top, right, bottom = range_boundaries(value)
    if not 1 <= left <= right <= 16384 or not 1 <= top <= bottom <= 1048576:
        raise ValueError("range is outside Excel worksheet bounds")
    if right - left + 1 > MAX_COLUMNS or bottom - top + 1 > MAX_ROWS + 10:
        raise ValueError("table exceeds 64 columns or 5010 total rows")
    return left, top, right, bottom


def intersects(a, b):
    return a[0] <= b[2] and b[0] <= a[2] and a[1] <= b[3] and b[1] <= a[3]


def rectangle(left, top, right, bottom):
    return f"{get_column_letter(left)}{top}:{get_column_letter(right)}{bottom}"


def relationship_details(archive, path):
    name = posixpath.join(posixpath.dirname(path), "_rels", posixpath.basename(path) + ".rels")
    if name not in archive.namelist():
        return {}
    result = {}
    for rel in ooxml.xml(archive.read(name)):
        if rel.get("TargetMode") == "External":
            continue
        target = rel.get("Target", "")
        target = target.lstrip("/") if target.startswith("/") else posixpath.normpath(posixpath.join(posixpath.dirname(path), target))
        if not target or target.startswith("../") or "\\" in target or target not in archive.namelist():
            raise ValueError("invalid package relationship")
        identity = rel.get("Id")
        if not identity or identity in result:
            raise ValueError("ambiguous package relationship IDs")
        result[identity] = (target, rel.get("Type", ""))
    return result


def relations(archive, path):
    return {key: value[0] for key, value in relationship_details(archive, path).items()}


def reference(value, default_sheet):
    if "!" in value:
        sheet, value = value.rsplit("!", 1)
        if sheet.startswith("'") and sheet.endswith("'"):
            sheet = sheet[1:-1].replace("''", "'")
    else:
        sheet = default_sheet
    sheet = sheet.casefold()
    if any(c in sheet for c in ":[]") or not re.fullmatch(r"\$?[A-Z]{1,3}\$?[1-9][0-9]*(?::\$?[A-Z]{1,3}\$?[1-9][0-9]*)?", value):
        return sheet, None
    clean = value.replace("$", "")
    return sheet, range_boundaries(clean)


def local_formula(formula, origin_row, area, sheet, known_sheets):
    sheet = sheet.casefold()
    known_sheets = {n.casefold() for n in known_sheets}
    if re.search(r"\b(INDIRECT|OFFSET)\s*\(", formula, re.I):
        raise ValueError("dynamic formula references cannot be preserved safely")
    for token in Tokenizer("=" + formula).items:
        if token.type == "FUNC" and token.subtype == "OPEN" and token.value.upper() not in {f + "(" for f in ("SUM", "AVERAGE", "MIN", "MAX", "COUNT", "COUNTA", "IF", "IFERROR", "ROUND", "ROUNDUP", "ROUNDDOWN", "ABS", "AND", "OR", "NOT", "LEN", "LOWER", "UPPER", "TRIM", "CONCAT", "CONCATENATE", "TEXT")}:
            raise ValueError("formula function is outside the supported non-external calculation subset")
        if token.subtype != "RANGE":
            continue
        # Native table current-row references do not change when records move.
        if re.fullmatch(r"\[@(?:[^\[\]]+|\[[^\[\]]+\])\]", token.value):
            continue
        target_sheet, ref = reference(token.value, sheet)
        if ref is None or target_sheet not in known_sheets:
            raise ValueError("formula uses unsupported names, structured ranges or spill references")
        if target_sheet == sheet and ref[1] == ref[3] == origin_row and area[0] <= ref[0] <= ref[2] <= area[2]:
            if re.search(r"\$[0-9]", token.value.rsplit("!", 1)[-1]):
                raise ValueError("row-locked references inside table records cannot follow record movement")
            continue
        # A fully absolute input outside the changing table is a fixed constant.
        coordinate = token.value.rsplit("!", 1)[-1]
        if all(re.fullmatch(r"\$[A-Z]{1,3}\$[1-9][0-9]*", p) for p in coordinate.split(":")) and (target_sheet != sheet or not intersects(ref, area)):
            continue
        raise ValueError("table formulas must be row-local or use fully absolute inputs outside the table")


def total_formula(formula, table):
    if not table.named:
        raise ValueError("totals formulas require a native named table")
    name = table.named[1].get("displayName", "")
    for token in Tokenizer("=" + formula).items:
        if token.subtype == "RANGE":
            value = token.value.removeprefix(name)
            if not re.fullmatch(r"\[[^\[\]]+\]", value) or value[1:-1] not in table.column_headers:
                raise ValueError("totals formulas must use this table's structured column references")
        if token.type == "FUNC" and token.subtype == "OPEN" and token.value.upper() not in {f + "(" for f in ("SUBTOTAL", "SUM", "COUNT", "COUNTA", "AVERAGE", "MIN", "MAX")}:
            raise ValueError("totals formula uses an unsupported function")


class ExcelDocument:
    def __init__(self, archive):
        self.archive = archive
        self.workbook = ooxml.xml(archive.read("xl/workbook.xml"))
        links = relations(archive, "xl/workbook.xml")
        self.sheets = {}
        for sheet in self.workbook.findall(f"{Q('sheets')}/{Q('sheet')}"):
            path = links.get(sheet.get(f"{{{R}}}id"))
            if path is None:
                raise ValueError("worksheet relationship is missing")
            self.sheets[sheet.get("name")] = (path, ooxml.xml(archive.read(path)), sheet.get("state", "visible"))
        if len({name.casefold() for name in self.sheets}) != len(self.sheets):
            raise ValueError("worksheet names are ambiguous ignoring case")
        self.part_types = {n.get("PartName", "").lstrip("/"): n.get("ContentType", "") for n in ooxml.xml(archive.read("[Content_Types].xml"))}
        self.relationship_types = {}
        for part in archive.namelist():
            if not part.endswith(".rels"):
                continue
            owner = posixpath.join(posixpath.dirname(posixpath.dirname(part)), posixpath.basename(part)[:-5])
            for target, kind in relationship_details(archive, owner).values():
                self.relationship_types.setdefault(target, set()).add(kind.rsplit("/", 1)[-1].casefold())
        self.strings = []
        if "xl/sharedStrings.xml" in archive.namelist():
            self.strings = [self.rich_text(n) for n in ooxml.xml(archive.read("xl/sharedStrings.xml"))]
        self.updates, self.cache, self.dirty = {}, {}, set()

    @staticmethod
    def rich_text(node):
        return "".join(n.text or "" for n in node.iter(Q("t")) if not any(p.tag == Q("rPh") for p in n.iterancestors()))

    def sheet(self, name):
        if name not in self.sheets:
            raise ValueError("sheet name must exactly match office_inspect")
        return self.sheets[name]

    def value(self, cell, allow_formula=False):
        if cell is None:
            return None
        if cell.find(Q("f")) is not None:
            if allow_formula:
                return {"formula": "=" + (cell.find(Q("f")).text or ""), "calculated": False}
            raise ValueError("formula cells cannot be imported as values or used as sort keys; cached results may be stale")
        kind, value = cell.get("t"), cell.findtext(Q("v"))
        if kind == "inlineStr":
            inline = cell.find(Q("is"))
            return self.rich_text(inline) if inline is not None else ""
        if kind == "s":
            return self.strings[int(value)]
        if kind in ("str", "d"):
            return value or ""
        if kind == "e":
            if allow_formula:
                return {"error": value}
            raise ValueError("Excel error cells cannot be edited/imported/sorted as ordinary values")
        if kind == "b":
            return value == "1"
        if value is None:
            return None
        exact = Decimal(value)
        if not exact.is_finite() or abs(exact) > 2**53:
            raise ValueError("numeric cell loses precision; retain exact identifiers as text")
        result = int(exact) if exact == exact.to_integral_value() else float(exact)
        if Decimal(str(result)) != exact:
            raise ValueError("numeric cell cannot be represented without precision loss")
        return scalar(result)

    def tables(self, sheet_name):
        path, tree, _ = self.sheet(sheet_name)
        links = relations(self.archive, path)
        result = []
        for part in tree.findall(f"{Q('tableParts')}/{Q('tablePart')}"):
            name = links.get(part.get(f"{{{R}}}id"))
            if name is None:
                raise ValueError("table relationship is missing")
            node = self.updates.get(name)
            node = ooxml.xml(node if node is not None else self.archive.read(name))
            result.append((name, node))
        return result

    def table(self, selector):
        sheet_name = selector.get("sheet")
        self.sheet(sheet_name)
        table_name, selected = selector.get("table"), selector.get("range")
        if (table_name is None) == (selected is None):
            raise ValueError("select exactly one named table or explicit range")
        key = (sheet_name, table_name, selected)
        header = selector.get("header_rows")
        if key not in self.cache:
            named = None
            if table_name is not None:
                matches = [(p, n) for p, n in self.tables(sheet_name) if table_name in (n.get("name"), n.get("displayName"))]
                if len(matches) != 1:
                    raise ValueError("named table is missing or ambiguous")
                named = matches[0]
                selected = named[1].get("ref")
            table = ExcelTable(self, sheet_name, selected, named, header)
            for other in self.cache.values():
                if other.sheet_name == sheet_name and intersects(other.area, table.area):
                    raise ValueError("batch contains overlapping table/range selectors")
            self.cache[key] = table
        result = self.cache[key]
        if header is not None and header != result.header_count:
            raise ValueError("use consistent header_rows for each target")
        return result

    def describe(self, offset, limit):
        entries = []
        for name, (_, tree, state) in self.sheets.items():
            item = {"sheet": name, "state": state, "tables": []}
            used = [range_boundaries(c.get("r")) for c in tree.iter(Q("c")) if c.get("r") and any(c.find(Q(t)) is not None for t in ("v", "f", "is"))]
            if used:
                item["used_range"] = rectangle(min(r[0] for r in used), min(r[1] for r in used), max(r[2] for r in used), max(r[3] for r in used))
            filt = tree.find(Q("autoFilter"))
            if filt is not None:
                item["filter_range"] = filt.get("ref")
            candidate = item.get("filter_range", item.get("used_range"))
            if candidate:
                item["range_candidate"] = {"sheet": name, "range": candidate}
            for _, node in self.tables(name):
                item["tables"].append({"table": node.get("displayName"), "range": node.get("ref"), "edit_target": {"sheet": name, "table": node.get("displayName")}, "header_rows": int(node.get("headerRowCount", "1")), "totals_rows": int(node.get("totalsRowCount", "0"))})
            entries.append(item)
        return {"items": entries[offset:offset + limit], "sheet_count": len(entries), "next_offset": offset + limit if offset + limit < len(entries) else None}

    def dependencies(self, target, proposed):
        name, area = target.sheet_name, proposed
        _, tree, _ = self.sheet(name)
        for other in self.cache.values():
            if other is not target and other.sheet_name == name and intersects(other.area, area):
                raise ValueError("table expansion overlaps another selected target")
        if tree.find(Q("sheetProtection")) is not None:
            raise ValueError("remove worksheet protection before editing")
        for tag, attr in (("mergeCell", "ref"), ("dataValidation", "sqref"), ("conditionalFormatting", "sqref"), ("hyperlink", "ref")):
            for item in tree.iter(Q(tag)):
                for ref in item.get(attr, "").split():
                    _, region = reference(ref, name)
                    if region is None or intersects(region, area):
                        raise ValueError(f"target intersects unsupported {tag} metadata")
        for filt in [tree.find(Q("autoFilter")), target.named[1].find(Q("autoFilter")) if target.named else None]:
            if filt is not None and filt.find(Q("filterColumn")) is not None:
                raise ValueError("active filters cannot be preserved safely during record edits; clear the filter and inspect again")
        sheet_filter = tree.find(Q("autoFilter"))
        if sheet_filter is not None:
            _, filter_area = reference(sheet_filter.get("ref", ""), name)
            expected = (target.area[0], target.area[1], target.area[2], target.area[3] - target.totals_count)
            if filter_area is None or (intersects(filter_area, area) and filter_area != expected):
                raise ValueError("target partially overlaps a worksheet filter; select its complete record range")
        for other_path, other in self.tables(name):
            if target.named and target.named[0] == other_path:
                continue
            if intersects(bounds(other.get("ref")), area):
                raise ValueError("table expansion collides with another table")
        for defined in self.workbook.findall(f"{Q('definedNames')}/{Q('definedName')}"):
            if defined.get("name") == "_xlnm.Print_Titles":
                continue
            if defined.get("name") == "_xlnm._FilterDatabase" and defined.text:
                filter_sheet, filter_ref = reference(defined.text, name)
                expected = (target.area[0], target.area[1], target.area[2], target.area[3] - target.totals_count)
                if filter_sheet == name.casefold() and filter_ref == expected:
                    continue
            if defined.text:
                for value in defined.text.split(","):
                    sheet, region = reference(value, name)
                    if region is None or (sheet == name.casefold() and intersects(region, area)):
                        raise ValueError("target has unsupported defined-name dependencies")
        for sheet, (_, root, _) in self.sheets.items():
            for cell in root.iter(Q("c")):
                formula = cell.find(Q("f"))
                if formula is None:
                    continue
                if formula.get("t") == "shared":
                    raise ValueError("shared formula dependencies are unsupported; refusing an unproven record move")
                address = cell.get("r", "")
                _, own = reference(address, sheet)
                inside = sheet == name and own is not None and intersects(own, area)
                if formula.get("ref"):
                    _, spanning = reference(formula.get("ref"), sheet)
                    if sheet == name and spanning is not None and intersects(spanning, area) and formula.get("t") not in (None, "normal"):
                        raise ValueError("target intersects a shared/array/spill formula range")
                if inside:
                    if formula.get("t") not in (None, "normal"):
                        raise ValueError("shared/array/spill formula ranges are unsupported")
                    if target.totals_count and own[1] == target.area[3]:
                        total_formula(formula.text or "", target)
                    else:
                        local_formula(formula.text or "", own[1], area, name, self.sheets)
                    continue
                body = formula.text or ""
                if re.search(r"\b(INDIRECT|OFFSET)\s*\(", body, re.I):
                    raise ValueError("workbook contains dynamic formula dependencies")
                for token in Tokenizer("=" + body).items:
                    if token.subtype != "RANGE":
                        continue
                    if target.named and token.value.startswith(target.named[1].get("displayName", "") + "["):
                        continue  # structured table references follow the resized table
                    referred_sheet, region = reference(token.value, sheet)
                    if region is None or (referred_sheet == name.casefold() and intersects(region, area)):
                        raise ValueError("target has unsupported incoming formula dependencies")
        # Chart/pivot/comment caches and anchors need explicit maintenance. Do
        # not move records underneath them and silently leave stale associations.
        links = relationship_details(self.archive, self.sheet(name)[0])
        for part, relationship_type in links.values():
            kind = relationship_type.rsplit("/", 1)[-1].casefold()
            if kind in ("comments", "threadedcomment", "threadedcomments"):
                root = ooxml.xml(self.archive.read(part))
                for comment in root.iter():
                    if not isinstance(comment.tag, str) or etree.QName(comment).localname not in ("comment", "threadedComment"):
                        continue
                    _, region = reference(comment.get("ref", ""), name)
                    if region is None or intersects(region, area):
                        raise ValueError("target contains cell comments that cannot move safely")
            elif kind in ("drawing", "vmldrawing", "pivottable", "querytable", "slicer", "timeline"):
                raise ValueError("structural edits on sheets containing drawings/pivots are not supported")
        for part in self.archive.namelist():
            kinds = self.relationship_types.get(part, set())
            content = self.part_types.get(part, "").casefold()
            if not (kinds & {"chart", "pivotcachedefinition", "pivottable"} or "chart" in content or "pivotcachedefinition" in content):
                continue
            for node in ooxml.xml(self.archive.read(part)).iter():
                if not isinstance(node.tag, str):
                    continue
                if etree.QName(node).localname == "f" and node.text:
                    referred_sheet, region = reference(node.text, name)
                    if region is None or (referred_sheet == name.casefold() and intersects(region, area)):
                        raise ValueError("target has chart/pivot dependencies")
                if etree.QName(node).localname == "worksheetSource":
                    if node.get("sheet", "").casefold() == name.casefold() or (target.named and node.get("name", "").casefold() == target.named[1].get("displayName", "").casefold()):
                        raise ValueError("target supplies a pivot cache")

    def finish(self):
        for name, (path, tree, _) in self.sheets.items():
            changed = name in self.dirty
            for cell in tree.iter(Q("c")):
                if cell.find(Q("f")) is not None:
                    for cached in cell.findall(Q("v")):
                        cell.remove(cached)
                        changed = True
            if changed:
                self.updates[path] = ooxml.encode(tree)
        calc = self.workbook.find(Q("calcPr"))
        if calc is None:
            calc = etree.SubElement(self.workbook, Q("calcPr"))
        calc.attrib.update({"fullCalcOnLoad": "1", "forceFullCalc": "1", "calcMode": "auto"})
        self.updates["xl/workbook.xml"] = ooxml.encode(self.workbook)
        rels = ooxml.xml(self.archive.read("xl/_rels/workbook.xml.rels"))
        remove = set()
        for rel in list(rels):
            if rel.get("Type", "").endswith("/calcChain"):
                remove.add(rel.get("Target", "").lstrip("/") if rel.get("Target", "").startswith("/") else "xl/" + rel.get("Target", ""))
                rels.remove(rel)
        content = ooxml.xml(self.archive.read("[Content_Types].xml"))
        for node in list(content):
            if node.get("PartName", "").lstrip("/") in remove:
                content.remove(node)
        self.updates["xl/_rels/workbook.xml.rels"] = ooxml.encode(rels)
        self.updates["[Content_Types].xml"] = ooxml.encode(content)
        return ooxml.rewrite(self.archive, self.updates, remove)


class ExcelTable:
    def __init__(self, document, sheet, selected, named, header_rows):
        self.document, self.sheet_name, self.named = document, sheet, named
        self.area = bounds(selected)
        self.original = self.area
        self.header_count = int(named[1].get("headerRowCount", "1")) if named else (1 if header_rows is None else header_rows)
        self.totals_count = int(named[1].get("totalsRowCount", "0")) if named else 0
        if type(self.header_count) is not int or self.header_count not in (0, 1) or self.totals_count not in (0, 1):
            raise ValueError("Excel tables support zero/one header row and zero/one totals row")
        if header_rows is not None and header_rows != self.header_count:
            raise ValueError("header_rows conflicts with the named table")
        left, top, right, bottom = self.area
        self.width = right - left + 1
        self.tree = document.sheet(sheet)[1]
        self.data = self.tree.find(Q("sheetData"))
        if self.data is None:
            raise ValueError("target is not an ordinary worksheet")
        self.cells = {cell.get("r"): cell for cell in self.data.iter(Q("c"))}
        def record(row):
            return {"origin": row, "cells": [deepcopy(self.cells.get(f"{get_column_letter(c)}{row}")) for c in range(left, right + 1)]}
        rows = [record(r) for r in range(top, bottom + 1)]
        if self.header_count + self.totals_count > len(rows):
            raise ValueError("table has no data area")
        self.headers = rows[:self.header_count]
        self.totals = rows[-self.totals_count:] if self.totals_count else []
        self.records = rows[self.header_count:len(rows) - self.totals_count if self.totals_count else len(rows)]
        self.template = self.records[-1] if self.records else {"origin": top + self.header_count, "cells": [None] * self.width}
        self.column_headers = [document.value(c) for c in self.headers[-1]["cells"]] if self.headers else [str(i + 1) for i in range(self.width)]

    def values(self, record, allow_formula=False):
        return [self.document.value(c, allow_formula) for c in record["cells"]]

    def make(self, values):
        row = {"origin": self.template["origin"], "cells": []}
        for template, value in zip(self.template["cells"], values, strict=True):
            if value is None and template is not None and template.find(Q("f")) is not None:
                row["cells"].append(deepcopy(template))
            else:
                row["cells"].append(self.cell(template, value))
        return row

    def cell(self, template, value):
        result = etree.Element(Q("c"))
        if template is not None and template.get("s") is not None:
            result.set("s", template.get("s"))
        value = scalar(value)
        if isinstance(value, str):
            result.set("t", "inlineStr")
            content = etree.SubElement(etree.SubElement(result, Q("is")), Q("t"))
            content.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
            content.text = value
        elif value is not None:
            result.set("t", "b" if type(value) is bool else "n")
            etree.SubElement(result, Q("v")).text = str(int(value)) if type(value) is bool else str(value)
        return result

    def set_cell(self, record, index, value):
        record["cells"][index] = self.cell(record["cells"][index], value)

    def set_formula(self, record, index, formula):
        if not isinstance(formula, str) or not formula.startswith("=") or not 1 < len(formula) <= 8192:
            raise ValueError("formula must explicitly begin with '=' and fit 8192 characters")
        cell = self.cell(record["cells"][index], None)
        etree.SubElement(cell, Q("f")).text = formula[1:]
        record["cells"][index] = cell

    def commit(self):
        left, top, right, old_bottom = self.area
        bottom = top + self.header_count + len(self.records) + self.totals_count - 1
        if (not self.records and not self.header_count and not self.totals_count) or len(self.records) > MAX_ROWS or bottom > 1048576:
            raise ValueError("Excel table must retain headers/totals or a data row, within the 5000-row limit")
        proposed = (left, top, right, max(bottom, old_bottom))
        self.document.dependencies(self, proposed)
        self.document.dirty.add(self.sheet_name)
        # Never shift cells outside the table or overwrite occupied cells below.
        for row in range(old_bottom + 1, bottom + 1):
            for col in range(left, right + 1):
                cell = self.cells.get(f"{get_column_letter(col)}{row}")
                if cell is not None and (cell.find(Q("v")) is not None or cell.find(Q("f")) is not None or cell.find(Q("is")) is not None):
                    raise ValueError("table expansion collides with occupied cells; no worksheet rows were shifted")
        by_row = {int(r.get("r")): r for r in self.data.findall(Q("row"))}
        for number in range(top, max(bottom, old_bottom) + 1):
            row = by_row.get(number)
            if row is not None:
                for cell in list(row):
                    if cell.tag != Q("c"):
                        continue
                    col = column_index_from_string(coordinate_from_string(cell.get("r"))[0])
                    if left <= col <= right:
                        row.remove(cell)
        for number, record in enumerate(self.headers + self.records + self.totals, top):
            row = by_row.get(number)
            if row is None:
                row = etree.Element(Q("row"), r=str(number))
                self.data.append(row)
                by_row[number] = row
            for col, cell in enumerate(record["cells"], left):
                if cell is None:
                    continue
                cell = deepcopy(cell)
                address = f"{get_column_letter(col)}{number}"
                formula = cell.find(Q("f"))
                if formula is not None:
                    if any(record is total for total in self.totals):
                        total_formula(formula.text or "", self)
                    else:
                        local_formula(formula.text or "", record["origin"], proposed, self.sheet_name, self.document.sheets)
                        formula.text = Translator("=" + (formula.text or ""), origin=f"{get_column_letter(col)}{record['origin']}").translate_formula(address)[1:]
                    for cached in cell.findall(Q("v")):
                        cell.remove(cached)
                cell.set("r", address)
                row.append(cell)
                record["cells"][col - left] = deepcopy(cell)
            record["origin"] = number
            ordered = sorted(row.findall(Q("c")), key=lambda c: column_index_from_string(coordinate_from_string(c.get("r"))[0]))
            for cell in row.findall(Q("c")):
                row.remove(cell)
            for index, cell in enumerate(ordered):
                row.insert(index, cell)
        rows = self.data.findall(Q("row"))
        for row in rows:
            self.data.remove(row)
        self.data.extend(sorted(rows, key=lambda r: int(r.get("r"))))
        self.area = (left, top, right, bottom)
        if self.records:
            self.template = self.records[-1]
        self.cells = {c.get("r"): c for c in self.data.iter(Q("c"))}
        sheet_filter = self.tree.find(Q("autoFilter"))
        if sheet_filter is not None:
            _, filter_area = reference(sheet_filter.get("ref", ""), self.sheet_name)
            if filter_area == (left, top, right, old_bottom - self.totals_count):
                sheet_filter.set("ref", rectangle(left, top, right, bottom - self.totals_count))
                for sort in sheet_filter.findall(Q("sortState")):
                    sheet_filter.remove(sort)
                for defined in self.document.workbook.findall(f"{Q('definedNames')}/{Q('definedName')}"):
                    if defined.get("name") != "_xlnm._FilterDatabase" or not defined.text:
                        continue
                    sheet, region = reference(defined.text, self.sheet_name)
                    if sheet == self.sheet_name.casefold() and region == filter_area:
                        from openpyxl.utils.cell import absolute_coordinate
                        prefix = defined.text.rsplit("!", 1)[0]
                        defined.text = prefix + "!" + absolute_coordinate(rectangle(left, top, right, bottom - self.totals_count))
        if self.named:
            path, node = self.named
            node.set("ref", rectangle(*self.area))
            filt = node.find(Q("autoFilter"))
            if filt is not None:
                filt.set("ref", rectangle(left, top, right, bottom - self.totals_count))
                for sort in filt.findall(Q("sortState")):
                    filt.remove(sort)
            for sort in node.findall(Q("sortState")):
                node.remove(sort)
            self.document.updates[path] = ooxml.encode(node)
        dimension = self.tree.find(Q("dimension"))
        if dimension is not None:
            self.tree.remove(dimension)

    def info(self):
        return {"sheet": self.sheet_name, "table": self.named[1].get("displayName") if self.named else None, "range": rectangle(*self.area), "headers": self.column_headers, "header_rows": self.header_count, "totals_rows": self.totals_count, "data_rows": len(self.records), "columns": self.width}
