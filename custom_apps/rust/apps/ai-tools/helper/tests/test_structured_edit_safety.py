"""Data-preservation regressions for structural edits and untrusted imports.

The prior projection/rebuild path demonstrably lost rows/styles/hidden state.
Record permutation, formula references and literal imports add the same risk;
verify observable documents rather than implementation-shaped mocks.
"""
import base64
import io
import sys
import unittest
import zipfile
from lxml import etree
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import docx
import openpyxl
from openpyxl.worksheet.table import Table
from ai_tools_office import structured, ooxml
from ai_tools_office.edit_common import revision, permutation


def word(rows):
    doc = docx.Document()
    doc.add_paragraph("Retain this introduction")
    table = doc.add_table(rows=len(rows), cols=len(rows[0]))
    for row, values in zip(table.rows, rows):
        for cell, value in zip(row.cells, values):
            cell.text = str(value)
    doc.sections[0].header.paragraphs[0].text = "Retain this header"
    out = io.BytesIO(); doc.save(out)
    return out.getvalue()


def excel(rows=None, start=1):
    book = openpyxl.Workbook()
    sheet = book.active; sheet.title = "Sales"
    rows = rows or [["Name", "Amount", "Double"], ["Zed", 9, "=B2*2"]]
    for i, values in enumerate(rows, start):
        for j, value in enumerate(values, 1):
            sheet.cell(i, j, value)
    sheet.add_table(Table(displayName="SalesData", ref=f"A{start}:C{start + len(rows) - 1}"))
    sheet.cell(start + 1, 1).font = openpyxl.styles.Font(bold=True)
    other = book.create_sheet("PrivateNotes"); other.sheet_state = "hidden"; other["A1"] = "retain"
    out = io.BytesIO(); book.save(out); book.close()
    return out.getvalue()


def run(raw, format, operations, sources=None):
    result = structured.edit(raw, format, revision(raw), operations, sources or {})
    return base64.b64decode(result["document"]), result


TARGET = {"sheet": "Sales", "table": "SalesData"}


class StructuralSafety(unittest.TestCase):
    def rewrite(self, raw, callback):
        output = io.BytesIO()
        with zipfile.ZipFile(io.BytesIO(raw)) as source, zipfile.ZipFile(output, "w") as target:
            for entry in source.infolist():
                name, content = callback(entry.filename, source.read(entry.filename))
                target.writestr(name, content)
        return output.getvalue()

    def test_locked_row_formulas_and_case_insensitive_incoming_references_refuse(self):
        book = openpyxl.load_workbook(io.BytesIO(excel()))
        book.active["C2"] = "=B$2*2"
        out = io.BytesIO(); book.save(out)
        with self.assertRaisesRegex(ValueError, "row-locked"):
            run(out.getvalue(), "xlsx", [{"op": "append_rows", "target": TARGET, "rows": [["new", 1, None]]}])
        book.active["C2"] = "=B2*2"
        book.create_sheet("Report")["A1"] = "=sales!B2"
        out = io.BytesIO(); book.save(out)
        with self.assertRaisesRegex(ValueError, "incoming formula"):
            run(out.getvalue(), "xlsx", [{"op": "sort_rows", "target": TARGET, "keys": [{"column": "Name"}]}])

    def test_shared_formula_followers_and_original_numeric_precision_refuse(self):
        raw = excel()
        def shared(name, content):
            if name == "xl/worksheets/sheet1.xml":
                root = ooxml.xml(content)
                for row in root.findall(f"{{{ooxml.S}}}sheetData/{{{ooxml.S}}}row"):
                    cell = etree.SubElement(row, f"{{{ooxml.S}}}c", r="E" + row.get("r"))
                    formula = etree.SubElement(cell, f"{{{ooxml.S}}}f", t="shared", si="0")
                    if row.get("r") == "1":
                        formula.set("ref", "E1:E2"); formula.text = "A1"
                content = ooxml.encode(root)
            return name, content
        with self.assertRaisesRegex(ValueError, "shared formula"):
            run(self.rewrite(raw, shared), "xlsx", [{"op": "sort_rows", "target": TARGET, "keys": [{"column": "Name"}]}])
        def number(name, content):
            if name == "xl/worksheets/sheet1.xml":
                root = ooxml.xml(content)
                root.find(f".//{{{ooxml.S}}}c[@r='B2']/{{{ooxml.S}}}v").text = "9007199254740993.0"
                content = ooxml.encode(root)
            return name, content
        with self.assertRaisesRegex(ValueError, "precision"):
            structured.inspect(self.rewrite(raw, number), "xlsx", {"view": "table", "selector": TARGET})

    def test_comments_are_classified_by_relationship_not_part_filename(self):
        book = openpyxl.load_workbook(io.BytesIO(excel()))
        book.active["A2"].comment = openpyxl.comments.Comment("belongs to Zed", "Owner")
        out = io.BytesIO(); book.save(out)
        def rename(name, content):
            changed = name.replace("/comments/", "/notes/").replace("/drawings/", "/shapes/")
            if name.endswith((".xml", ".rels")):
                content = content.replace(b"/comments/", b"/notes/").replace(b"/drawings/", b"/shapes/")
            return changed, content
        raw = self.rewrite(out.getvalue(), rename)
        self.assertEqual(openpyxl.load_workbook(io.BytesIO(raw)).active["A2"].comment.text, "belongs to Zed")
        with self.assertRaisesRegex(ValueError, "comments"):
            run(raw, "xlsx", [{"op": "sort_rows", "target": TARGET, "keys": [{"column": "Name"}]}])

    def test_word_layout_and_insertion_order_survive_replacing_an_anchor(self):
        doc = docx.Document()
        doc.add_paragraph("start").paragraph_format.page_break_before = True
        doc.add_paragraph("end")
        out = io.BytesIO(); doc.save(out)
        output, _ = run(out.getvalue(), "docx", [
            {"op": "paragraph_insert", "paragraph_index": 0, "text": "first"},
            {"op": "paragraph_set", "paragraph_index": 0, "text": "renamed"},
            {"op": "paragraph_insert", "paragraph_index": 0, "text": "second"},
        ])
        result = docx.Document(io.BytesIO(output))
        self.assertEqual([p.text for p in result.paragraphs], ["renamed", "first", "second", "end"])
        self.assertTrue(result.paragraphs[0].paragraph_format.page_break_before)
        self.assertIsNone(result.paragraphs[1].paragraph_format.page_break_before)

    def test_legacy_merges_omitted_grid_cells_and_xml_whitespace_are_handled(self):
        for tag in ("hMerge", "gridBefore", "gridAfter"):
            doc = docx.Document(io.BytesIO(word([["Name", "Amount"], ["Alice", "1"]])))
            row = doc.tables[0].rows[1]
            if tag == "hMerge":
                prop = row.cells[0]._tc.get_or_add_tcPr()
            else:
                prop = row._tr.get_or_add_trPr()
            marker = docx.oxml.OxmlElement("w:" + tag)
            marker.set(docx.oxml.ns.qn("w:val"), "restart" if tag == "hMerge" else "1")
            prop.append(marker); out = io.BytesIO(); doc.save(out)
            with self.assertRaises(ValueError):
                run(out.getvalue(), "docx", [{"op": "append_rows", "target": {"table_index": 0}, "rows": [["new", "2"]]}])
        def pretty(name, content):
            if name == "word/document.xml":
                content = etree.tostring(ooxml.xml(content), pretty_print=True)
            return name, content
        raw = self.rewrite(word([["Name", "Amount"], ["Alice", "1"]]), pretty)
        result = structured.inspect(raw, "docx", {"view": "table", "selector": {"table_index": 0}})
        self.assertEqual(result["items"][0]["values"], ["Alice", "1"])

    def test_cross_document_import_then_sort_preserves_formulas_styles_and_parts(self):
        source = word([["Name", "Amount"], ["Alice", "2.50"], ["Bob", "10"]])
        raw = excel()
        output, report = run(raw, "xlsx", [
            {"op": "import_rows", "target": TARGET, "source": {"path": "input.docx", "revision": revision(source), "selector": {"table_index": 0}},
             "column_map": [{"source": "Name", "target": "Name"}, {"source": "Amount", "target": "Amount", "kind": "number"}]},
            {"op": "sort_rows", "target": TARGET, "keys": [{"column": "Amount"}]},
        ], {"input.docx": {"format": "docx", "document": base64.b64encode(source).decode()}})
        book = openpyxl.load_workbook(io.BytesIO(output))
        self.assertEqual([book.active.cell(r, 1).value for r in range(2, 5)], ["Alice", "Zed", "Bob"])
        self.assertEqual(book.active["B2"].value, 2.5)
        self.assertEqual(book.active["C2"].value, "=B2*2")
        self.assertEqual(book.active["C4"].value, "=B4*2")
        self.assertTrue(book.active["A2"].font.bold)
        self.assertEqual(book.active.tables["SalesData"].ref, "A1:C4")
        self.assertEqual(book["PrivateNotes"].sheet_state, "hidden")
        self.assertFalse(report["recalculated"])
        with zipfile.ZipFile(io.BytesIO(raw)) as before, zipfile.ZipFile(io.BytesIO(output)) as after:
            self.assertEqual(before.read("xl/styles.xml"), after.read("xl/styles.xml"))
            self.assertEqual(before.read("docProps/core.xml"), after.read("docProps/core.xml"))

    def test_word_rows_move_with_formatting_and_surrounding_content_is_retained(self):
        raw = word([["Name", "Amount"], ["Zed", "9"]])
        output, _ = run(raw, "docx", [
            {"op": "append_rows", "target": {"table_index": 0}, "rows": [["Alice", "2"], ["Bob", "10"]]},
            {"op": "sort_rows", "target": {"table_index": 0}, "keys": [{"column": "Amount", "kind": "number"}]},
        ])
        doc = docx.Document(io.BytesIO(output))
        self.assertEqual([r.cells[0].text for r in doc.tables[0].rows], ["Name", "Alice", "Zed", "Bob"])
        self.assertEqual(doc.paragraphs[0].text, "Retain this introduction")
        self.assertEqual(doc.sections[0].header.paragraphs[0].text, "Retain this header")
        with zipfile.ZipFile(io.BytesIO(raw)) as before, zipfile.ZipFile(io.BytesIO(output)) as after:
            for name in before.namelist():
                if name != "word/document.xml":
                    self.assertEqual(before.read(name), after.read(name))

    def test_import_and_literal_cell_edits_never_create_formulas(self):
        raw = excel([["Name", "Amount", "Double"], ["first", 1, 2]])
        output, _ = run(raw, "xlsx", [{"op": "append_rows", "target": TARGET, "rows": [["=HYPERLINK(\"https://example.test\")", "00123", "12345678901234567890"]]}])
        book = openpyxl.load_workbook(io.BytesIO(output))
        self.assertEqual(book.active["A3"].data_type, "s")
        self.assertEqual(book.active["B3"].value, "00123")
        self.assertEqual(book.active["C3"].value, "12345678901234567890")

    def test_stable_sort_keeps_duplicates_and_blanks_last_both_directions(self):
        rows = [["a", 2], ["b", None], ["c", 2], ["d", 1], ["e", ""]]
        self.assertEqual(permutation(rows, ["Name", "Amount"], [{"column": "Amount"}]), [3, 0, 2, 1, 4])
        self.assertEqual(permutation(rows, ["Name", "Amount"], [{"column": "Amount", "direction": "descending"}]), [0, 2, 3, 1, 4])

    def test_revision_pin_and_failure_of_last_operation_abort_the_batch(self):
        raw = excel()
        with self.assertRaisesRegex(ValueError, "source changed"):
            structured.edit(raw, "xlsx", "0" * 64, [], {})
        with self.assertRaises(ValueError):
            run(raw, "xlsx", [{"op": "append_rows", "target": TARGET, "rows": [["new", 1, None]]}, {"op": "delete_rows", "target": TARGET, "row": 999, "count": 1}])
        self.assertEqual(openpyxl.load_workbook(io.BytesIO(raw)).active.tables["SalesData"].ref, "A1:C2")

    def test_source_revision_is_pinned_independently(self):
        source = word([["Name", "Amount", "Double"], ["new", "1", "2"]])
        with self.assertRaisesRegex(ValueError, "source changed"):
            run(excel(), "xlsx", [{"op": "import_rows", "target": TARGET, "source": {"path": "x.docx", "revision": "0" * 64, "selector": {"table_index": 0}}}], {"x.docx": {"format": "docx", "document": base64.b64encode(source).decode()}})

    def test_targeted_inspection_reaches_rows_beyond_old_projection_limits(self):
        raw = excel([["Name", "Amount", "Double"], ["deep", 1, 2]], start=3000)
        result = structured.inspect(raw, "xlsx", {"view": "table", "selector": TARGET})
        self.assertEqual(result["items"][0]["values"], ["deep", 1, 2])
        self.assertEqual(result["revision"], revision(raw))

    def test_formula_sort_keys_and_incoming_a1_dependencies_are_refused(self):
        raw = excel()
        with self.assertRaisesRegex(ValueError, "formula cells"):
            run(raw, "xlsx", [{"op": "sort_rows", "target": TARGET, "keys": [{"column": "Double", "kind": "text"}]}])
        book = openpyxl.load_workbook(io.BytesIO(raw)); book.active["G1"] = "=SUM(B2:B3)"
        out = io.BytesIO(); book.save(out)
        with self.assertRaisesRegex(ValueError, "incoming formula"):
            run(out.getvalue(), "xlsx", [{"op": "append_rows", "target": TARGET, "rows": [["new", 1, None]]}])

    def test_occupied_growth_and_merged_word_tables_are_refused(self):
        book = openpyxl.load_workbook(io.BytesIO(excel())); book.active["A3"] = "do not overwrite"
        out = io.BytesIO(); book.save(out)
        with self.assertRaisesRegex(ValueError, "occupied"):
            run(out.getvalue(), "xlsx", [{"op": "append_rows", "target": TARGET, "rows": [["new", 1, None]]}])
        doc = docx.Document(io.BytesIO(word([["Name", "Amount"], ["old", "1"]])))
        doc.tables[0].cell(1, 0).merge(doc.tables[0].cell(1, 1)); out = io.BytesIO(); doc.save(out)
        with self.assertRaisesRegex(ValueError, "merged"):
            run(out.getvalue(), "docx", [{"op": "append_rows", "target": {"table_index": 0}, "rows": [["new", "1"]]}])


if __name__ == "__main__":
    unittest.main()
