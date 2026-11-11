"""Data-loss regressions: supported edits must retain original package parts.

The investigation reproduced silent truncation, hidden-sheet exposure and a
failed custom-style round trip. Tests cover those concrete preservation risks.
"""
import base64
import io
import sys
import unittest
import zipfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
import docx
import openpyxl
from ai_tools_office import ooxml, spreadsheet, word
from ai_tools_office.__main__ import _dispatch


class SafeEdits(unittest.TestCase):
    def test_word_replacement_cannot_cross_nontext_or_multiparagraph_fields(self):
        for tag in ("noBreakHyphen", "footnoteReference"):
            document = docx.Document()
            paragraph = document.add_paragraph()
            paragraph.add_run("Annual")._r.append(docx.oxml.OxmlElement("w:" + tag))
            paragraph.add_run("report")
            output = io.BytesIO()
            document.save(output)
            with self.assertRaises(ValueError):
                ooxml.edit(output.getvalue(), "docx", {"replacements": [{"find": "Annualreport", "replace": "Updated"}]})
        document = docx.Document()
        begin = docx.oxml.OxmlElement("w:fldChar")
        begin.set(docx.oxml.ns.qn("w:fldCharType"), "begin")
        document.add_paragraph().add_run()._r.append(begin)
        document.add_paragraph("Chapter One")
        end = docx.oxml.OxmlElement("w:fldChar")
        end.set(docx.oxml.ns.qn("w:fldCharType"), "end")
        document.add_paragraph().add_run()._r.append(end)
        output = io.BytesIO()
        document.save(output)
        with self.assertRaises(ValueError):
            ooxml.edit(output.getvalue(), "docx", {"replacements": [{"find": "Chapter One", "replace": "Updated"}]})

    def test_merged_nonanchor_and_word_field_edits_are_refused(self):
        with self.assertRaises(ValueError):
            ooxml.edit(self.workbook(), "xlsx", {"cells": [{"sheet": "Budget", "cell": "E1", "value": "lost"}]})
        document = docx.Document()
        paragraph = document.add_paragraph("Pending")
        paragraph._p.append(docx.oxml.OxmlElement("w:fldSimple"))
        output = io.BytesIO()
        document.save(output)
        with self.assertRaises(ValueError):
            ooxml.edit(output.getvalue(), "docx", {"replacements": [{"find": "Pending", "replace": "Approved"}]})

    def test_read_pages_are_explicit_views_with_a_continuation(self):
        output = io.BytesIO()
        spreadsheet.write({"sheets": [{"name": "A", "rows": [["x" * 500] for _ in range(100)]}]}, output)
        result = _dispatch({"op": "read", "format": "xlsx", "document": base64.b64encode(output.getvalue()).decode(), "offset": 0})
        self.assertTrue(result["view_only"])
        self.assertIsNotNone(result["next_offset"])
        self.assertEqual(result["items"][0]["row"], 1)
        self.assertLess(len(__import__("json").dumps(result)), 26000)

    def workbook(self):
        book = openpyxl.Workbook()
        book.active.title = "Budget"
        book.active.append([120, 80, "=SUM(A1:B1)"])
        book.active["A1"].number_format = "$0.00"
        book.active.merge_cells("D1:E1")
        hidden = book.create_sheet("Hidden")
        hidden.sheet_state = "hidden"
        hidden.append(["retained"])
        buffer = io.BytesIO()
        book.save(buffer)
        book.close()
        return buffer.getvalue()

    def test_targeted_workbook_edit_preserves_formatting_hidden_sheets_and_formulas(self):
        original = self.workbook()
        edited = ooxml.edit(original, "xlsx", {"cells": [{"sheet": "Budget", "cell": "A1", "value": 150}]})
        book = openpyxl.load_workbook(io.BytesIO(edited))
        self.assertEqual(book.active["A1"].value, 150)
        self.assertEqual(book.active["A1"].number_format, "$0.00")
        self.assertEqual(book.active["C1"].value, "=SUM(A1:B1)")
        self.assertEqual(book["Hidden"].sheet_state, "hidden")
        self.assertIn("D1:E1", book.active.merged_cells)
        self.assertTrue(book.calculation.fullCalcOnLoad)
        book.close()
        with zipfile.ZipFile(io.BytesIO(original)) as before, zipfile.ZipFile(io.BytesIO(edited)) as after:
            for name in ["xl/styles.xml", "docProps/core.xml"]:
                self.assertEqual(before.read(name), after.read(name))

    def test_word_edit_preserves_custom_style_header_and_other_package_parts(self):
        document = docx.Document()
        document.styles.add_style("CustomReview", 1)
        p = document.add_paragraph(style="CustomReview")
        p.add_run("Status: ").bold = True
        p.add_run("Pen")
        p.add_run("ding")
        document.sections[0].header.paragraphs[0].text = "Original header"
        buffer = io.BytesIO()
        document.save(buffer)
        original = buffer.getvalue()
        edited = ooxml.edit(original, "docx", {"replacements": [{"find": "Pending", "replace": "Approved"}]})
        result = docx.Document(io.BytesIO(edited))
        self.assertEqual(result.paragraphs[0].text, "Status: Approved")
        self.assertEqual(result.paragraphs[0].style.name, "CustomReview")
        self.assertTrue(result.paragraphs[0].runs[0].bold)
        with zipfile.ZipFile(io.BytesIO(original)) as before, zipfile.ZipFile(io.BytesIO(edited)) as after:
            self.assertEqual(before.namelist(), after.namelist())
            for name in before.namelist():
                if name != "word/document.xml":
                    self.assertEqual(before.read(name), after.read(name), name)

    def test_creation_rejects_silent_text_loss_or_sheet_renaming(self):
        for spec in [
            {"sheets": [{"name": "A", "rows": [["x" * 32768]]}]},
            {"sheets": [{"name": "A", "rows": []}, {"name": "a", "rows": []}]},
        ]:
            with self.assertRaises(ValueError):
                spreadsheet.write(spec, io.BytesIO())
        with self.assertRaises(ValueError):
            word.write({"blocks": [{"text": "x" * 8193}]}, io.BytesIO())

    def test_hidden_state_survives_creation_from_a_read_projection(self):
        projection = spreadsheet.read(self.workbook())
        output = io.BytesIO()
        spreadsheet.write(projection, output)
        self.assertEqual(spreadsheet.read(output.getvalue())["sheets"][1]["state"], "hidden")

    def test_render_and_edit_protocol_returns_bytes_without_a_filesystem_path(self):
        result = _dispatch({"op": "render", "format": "xlsx", "spec": {"sheets": [{"name": "A", "rows": [[1]]}]}})
        edited = _dispatch({"op": "edit", "format": "xlsx", "document": result["document"], "spec": {"cells": [{"sheet": "A", "cell": "A1", "value": 2}]}})
        self.assertNotIn("path", edited)
        self.assertFalse(edited["recalculated"])
        self.assertEqual(spreadsheet.read(base64.b64decode(edited["document"]))["sheets"][0]["rows"], [[2]])

    def test_bad_archive_or_ambiguous_edit_is_refused(self):
        buffer = io.BytesIO()
        with zipfile.ZipFile(buffer, "w") as archive:
            archive.writestr("../outside", "bad")
        with self.assertRaises(ValueError):
            ooxml.package(buffer.getvalue())
        document = docx.Document()
        document.add_paragraph("repeat repeat")
        buffer = io.BytesIO()
        document.save(buffer)
        with self.assertRaises(ValueError):
            ooxml.edit(buffer.getvalue(), "docx", {"replacements": [{"find": "repeat", "replace": "changed"}]})


if __name__ == "__main__":
    unittest.main()
