"""Table-local Word edits. Move existing rows; build new rows from properties."""
from __future__ import annotations

from copy import deepcopy
from lxml import etree
from . import ooxml
from .edit_common import MAX_ROWS, MAX_COLUMNS, text, integer, scalar

W = ooxml.W
Q = lambda tag: f"{{{W}}}{tag}"


def plain(node):
    allowed = {Q(t) for t in ("tc", "p", "r", "t")}
    properties = {Q(t) for t in ("tcPr", "pPr", "rPr")}
    for child in node.iter():
        if child.tag in properties or any(p.tag in properties for p in child.iterancestors() if p is not node):
            continue
        if child.tag not in allowed:
            raise ValueError("Word table contains annotations, fields, nested tables or non-text content; refusing a lossy edit/import")


def cell_text(cell):
    plain(cell)
    return "\n".join("".join(t.text or "" for t in p.iter(Q("t"))) for p in cell.findall(Q("p")))


def new_cell(template, value, *, replacement=False):
    value = text(scalar(value))
    if "\t" in value:
        raise ValueError("Word cell tabs need explicit rich-text handling; use separate cells instead")
    if len(value) > 8192:
        raise ValueError("Word cell exceeds the 8192-character edit limit")
    result = etree.Element(Q("tc"))
    prop = template.find(Q("tcPr"))
    if prop is not None:
        prop = deepcopy(prop)
        if not replacement:
            for old in prop.findall(Q("cnfStyle")):
                prop.remove(old)
        result.append(prop)
    old_p = template.find(Q("p"))
    old_paragraphs = template.findall(Q("p"))
    for index, line in enumerate(value.split("\n")):
        p = etree.SubElement(result, Q("p"))
        source_p = old_paragraphs[min(index, len(old_paragraphs) - 1)] if replacement and old_paragraphs else old_p
        pprop = source_p.find(Q("pPr")) if source_p is not None else None
        if pprop is not None:
            pprop = deepcopy(pprop)
            for old in list(pprop):
                insertion_only = not replacement and old.tag in {Q("cnfStyle"), Q("pageBreakBefore")}
                extra_page_break = replacement and index >= len(old_paragraphs) and old.tag == Q("pageBreakBefore")
                if old.tag == Q("sectPr") or insertion_only or extra_page_break:
                    pprop.remove(old)
            p.append(pprop)
        run = etree.SubElement(p, Q("r"))
        rprop = source_p.find(f"{Q('r')}/{Q('rPr')}") if source_p is not None else None
        if rprop is not None:
            run.append(deepcopy(rprop))
        content = etree.SubElement(run, Q("t"))
        content.set("{http://www.w3.org/XML/1998/namespace}space", "preserve")
        content.text = line
    return result


class WordTable:
    def __init__(self, node, header_rows=None):
        self.node = node
        for child in node.iter():
            if child.tag in {Q(t) for t in ("ins", "del", "moveFrom", "moveTo", "cellIns", "cellDel", "cellMerge", "tblPrChange", "trPrChange", "tcPrChange", "pPrChange", "rPrChange")}:
                raise ValueError("resolve tracked table/property changes before editing or importing")
        if any(child.tag not in {Q("tblPr"), Q("tblGrid"), Q("tr")} for child in node):
            raise ValueError("Word table has spanning annotations or unsupported row wrappers")
        rows = node.findall(Q("tr"))
        if not rows or len(rows) > MAX_ROWS + 10:
            raise ValueError("Word table must have 1–5010 rows")
        repeated = 0
        for row in rows:
            flag = row.find(f"{Q('trPr')}/{Q('tblHeader')}")
            if flag is None or flag.get(Q("val"), "true").lower() in ("0", "false", "off"):
                break
            repeated += 1
        self.header_count = integer(header_rows if header_rows is not None else max(1, repeated), 0, min(10, len(rows)), "header_rows")
        self.width = len(rows[-1].findall(Q("tc")))
        if not 1 <= self.width <= MAX_COLUMNS:
            raise ValueError("Word table has too many columns")
        grid = node.findall(f"{Q('tblGrid')}/{Q('gridCol')}")
        if grid and len(grid) != self.width:
            raise ValueError("Word table is merged/ragged: row width does not match its grid")
        for row in rows:
            for omitted in ("gridBefore", "gridAfter"):
                prop = row.find(f"{Q('trPr')}/{Q(omitted)}")
                if prop is not None and prop.get(Q("val"), "0") != "0":
                    raise ValueError("ragged Word tables with omitted grid cells are not supported")
            if len(row.findall(Q("tc"))) != self.width:
                raise ValueError("merged or ragged Word tables are not supported for structural operations")
            for cell in row.findall(Q("tc")):
                if any(cell.find(f"{Q('tcPr')}/{Q(tag)}") is not None for tag in ("vMerge", "hMerge", "gridSpan")):
                    raise ValueError("merged Word table cells are not supported")
                plain(cell)
            # Row-level markers can span rows; moving/duplicating them is unsafe.
            if any(c.tag not in {Q("trPr"), Q("tc")} for c in row):
                raise ValueError("Word row has unsupported annotation content")
        self.headers = rows[:self.header_count]
        self.records = rows[self.header_count:]
        self.template = rows[-1]
        self.column_headers = [cell_text(c) for c in rows[self.header_count - 1].findall(Q("tc"))] if self.header_count else [str(i + 1) for i in range(self.width)]
        self.totals_count = 0

    def values(self, record):
        return [cell_text(c) for c in record.findall(Q("tc"))]

    def make(self, values):
        result = etree.Element(Q("tr"))
        props = self.template.find(Q("trPr"))
        if props is not None:
            props = deepcopy(props)
            for flag in list(props):
                if flag.tag in {Q("tblHeader"), Q("cnfStyle")}:
                    props.remove(flag)
            result.append(props)
        for old, value in zip(self.template.findall(Q("tc")), values, strict=True):
            result.append(new_cell(old, value))
        return result

    def set_cell(self, record, index, value):
        old = record.findall(Q("tc"))[index]
        record.replace(old, new_cell(old, value, replacement=True))

    def commit(self):
        if len(self.records) > MAX_ROWS:
            raise ValueError("table exceeds 5000 data rows")
        for row in self.node.findall(Q("tr")):
            self.node.remove(row)
        self.node.extend(self.headers + self.records)
        if self.records:
            self.template = self.records[-1]

    def info(self):
        return {"headers": self.column_headers, "header_rows": self.header_count, "data_rows": len(self.records), "columns": self.width}


class WordDocument:
    def __init__(self, archive):
        self.archive = archive
        self.root = ooxml.xml(archive.read("word/document.xml"))
        self.body = self.root.find(Q("body"))
        if self.body is None:
            raise ValueError("document has no body")
        self.tables = self.body.findall(Q("tbl"))
        self.paragraphs = self.body.findall(Q("p"))
        self.cache = {}

    def guard(self):
        for tag in ("ins", "del", "moveFrom", "moveTo", "fldChar", "cellIns", "cellDel", "cellMerge", "tblPrChange", "trPrChange", "tcPrChange", "pPrChange", "rPrChange", "sectPrChange"):
            if self.root.find(f".//{Q(tag)}") is not None:
                raise ValueError("resolve tracked changes/complex body fields before structural edits")
        if "word/settings.xml" in self.archive.namelist():
            settings = ooxml.xml(self.archive.read("word/settings.xml"))
            if settings.find(Q("documentProtection")) is not None:
                raise ValueError("remove document protection before editing")

    def table(self, selector):
        index = integer(selector.get("table_index"), 0, len(self.tables) - 1, "table_index")
        key = (index, selector.get("header_rows"))
        if index in self.cache and self.cache[index][0] != key:
            raise ValueError("use consistent header_rows for each table throughout a batch")
        if index not in self.cache:
            self.cache[index] = (key, WordTable(self.tables[index], selector.get("header_rows")))
        return self.cache[index][1]

    def describe(self, offset, limit):
        items = []
        table_ids = {n: i for i, n in enumerate(self.tables)}
        para_ids = {n: i for i, n in enumerate(self.paragraphs)}
        blocks = [n for n in self.body if n.tag in {Q("p"), Q("tbl")}]
        for node in blocks[offset:offset + limit]:
            if node.tag == Q("p"):
                value = "".join(t.text or "" for t in node.iter(Q("t")))
                items.append({"kind": "paragraph", "paragraph_index": para_ids[node], "text": value[:1000], "text_truncated": len(value) > 1000})
            else:
                item = {"kind": "table", "table_index": table_ids[node], "edit_target": {"table_index": table_ids[node]}, "rows": len(node.findall(Q("tr")))}
                try:
                    item.update(WordTable(node).info(), editable=True)
                except ValueError as error:
                    item.update(editable=False, reason=str(error))
                items.append(item)
        return {"items": items, "block_count": len(blocks), "next_offset": offset + len(items) if offset + len(items) < len(blocks) else None}

    def finish(self):
        return ooxml.rewrite(self.archive, {"word/document.xml": ooxml.encode(self.root)})
