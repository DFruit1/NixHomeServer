"""Round-trip tests for the office helper.

The properties worth proving are the ones the tool surface promises: a write
retains every sheet it was given (Collabora's convert-to exports only the first
sheet, which is the whole reason this helper exists), a read sees every sheet,
and a caller who converts an ods or odt first gets the same result as one who
started from native Office. What is deliberately *not* retained is asserted too,
so a future change that quietly loses more than it already loses is visible.
"""

from __future__ import annotations

import base64
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

# The package sits beside this file rather than on the interpreter's path, so the
# tests run from a checkout the same way the Nix check runs them.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from ai_tools_office import spreadsheet, word  # noqa: E402 - needs the path above

HELPER_ROOT = Path(__file__).resolve().parents[1]


def run_helper(request: dict) -> tuple[int, dict, str]:
    """Invoke the helper as the Rust caller does: JSON in, JSON out."""
    process = subprocess.run(
        [sys.executable, "-m", "ai_tools_office"],
        input=json.dumps(request),
        capture_output=True,
        text=True,
        cwd=HELPER_ROOT,
        check=False,
    )
    stdout = process.stdout.strip()
    stderr = process.stderr.strip()
    payload = {}
    if stdout:
        payload = json.loads(stdout)
    elif stderr:
        payload = json.loads(stderr)
    return process.returncode, payload, stderr


class ScratchDir:
    def __init__(self, label: str) -> None:
        self.path = Path(tempfile.mkdtemp(prefix=f"ai-office-{label}-"))

    def __enter__(self) -> Path:
        return self.path

    def __exit__(self, *_: object) -> None:
        shutil.rmtree(self.path, ignore_errors=True)


class SpreadsheetTests(unittest.TestCase):
    def test_write_retains_every_sheet(self) -> None:
        """The retention property convert-to cannot provide."""
        with ScratchDir("multi") as directory:
            path = directory / "book.xlsx"
            spec = {
                "sheets": [
                    {"name": "Alpha", "rows": [["a", 1], [None, 2.5]]},
                    {"name": "Beta", "rows": [["only in beta"]]},
                    {"name": "Gamma", "rows": []},
                ]
            }
            written = spreadsheet.write(spec, str(path))

            self.assertEqual(written["sheets"], ["Alpha", "Beta", "Gamma"])
            self.assertEqual(written["sheet_count"], 3)

            read_back = spreadsheet.read(path.read_bytes())
            self.assertEqual(read_back["sheet_count"], 3)
            self.assertEqual(read_back["declared_sheet_count"], 3)
            names = [sheet["name"] for sheet in read_back["sheets"]]
            self.assertEqual(names, ["Alpha", "Beta", "Gamma"])

            alpha, beta, gamma = read_back["sheets"]
            self.assertEqual(alpha["rows"], [["a", 1], [None, 2.5]])
            self.assertEqual(beta["rows"], [["only in beta"]])
            self.assertEqual(gamma["rows"], [])

    def test_formula_text_survives_rather_than_becoming_none(self) -> None:
        """data_only=True would report None for every formula we wrote."""
        with ScratchDir("formula") as directory:
            path = directory / "calc.xlsx"
            spreadsheet.write(
                {"sheets": [{"name": "S", "rows": [["=1+1", "=SUM(A1:A2)"]]}]}, str(path)
            )
            read_back = spreadsheet.read(path.read_bytes())
            self.assertEqual(read_back["sheets"][0]["rows"][0], ["=1+1", "=SUM(A1:A2)"])

    def test_a_value_xlsx_cannot_store_is_refused_not_silently_dropped(self) -> None:
        """openpyxl writes NaN and Infinity as empty cells, losing them."""
        import math

        with ScratchDir("nan") as directory:
            path = directory / "never.xlsx"
            spec = {
                "sheets": [
                    {"name": "Fine", "rows": [["a"]]},
                    {"name": "Later", "rows": [["ok"], [math.nan]]},
                ]
            }
            with self.assertRaises(ValueError) as caught:
                spreadsheet.write(spec, str(path))
            # The message has to name the sheet, or a caller cannot tell which
            # of twenty sheets carried the offending value.
            self.assertIn("Later", str(caught.exception))
            self.assertIn("empty cell", str(caught.exception))
            self.assertFalse(path.exists())

    def test_every_cell_type_is_representable_in_json(self) -> None:
        import datetime

        with ScratchDir("types") as directory:
            path = directory / "types.xlsx"
            rows = [
                [
                    True,
                    7,
                    1.25,
                    "nan",
                    "inf",
                    datetime.date(2026, 10, 5),
                    datetime.datetime(2026, 10, 5, 12, 30),
                    datetime.timedelta(hours=3),
                    "text",
                    None,
                ]
            ]
            spreadsheet.write({"sheets": [{"name": "T", "rows": rows}]}, str(path))
            values = spreadsheet.read(path.read_bytes())["sheets"][0]["rows"][0]

            self.assertIs(values[0], True)
            self.assertEqual(values[1], 7)
            self.assertEqual(values[2], 1.25)
            # A date written by openpyxl comes back as midnight of that day, so
            # the date/datetime distinction is not retained; both are ISO text.
            self.assertEqual(values[3], "nan")
            self.assertEqual(values[4], "inf")
            self.assertEqual(values[5], "2026-10-05T00:00:00")
            self.assertEqual(values[6], "2026-10-05T12:30:00")
            self.assertIn("3", values[7])
            self.assertEqual(values[8], "text")
            # A trailing None was padding to the sheet's widest row, not data, so
            # it is dropped rather than returned as an empty final cell.
            self.assertEqual(len(values), 9)

    def test_a_bad_sheet_name_is_refused_before_anything_is_written(self) -> None:
        with ScratchDir("badname") as directory:
            path = directory / "never.xlsx"
            spec = {
                "sheets": [
                    {"name": "Fine", "rows": [["a"]]},
                    {"name": "bad/name", "rows": [["b"]]},
                ]
            }
            with self.assertRaises(ValueError):
                spreadsheet.write(spec, str(path))
            # Validation runs over every name before the workbook is built, so a
            # late rejection cannot leave a partial file behind.
            self.assertFalse(path.exists())

    def test_rows_and_columns_are_clamped_and_reported(self) -> None:
        """A row wider than the ceiling is clamped, and the loss is declared.

        `truncated_columns` reports loss on *read*, so it can only be true for a
        workbook that is genuinely wider than the ceiling. A write is clamped
        first, which is what makes that flag meaningful: the written file is
        exactly at the ceiling, so the round-trip reports nothing lost. Both
        halves are asserted, because a read-only ceiling would report a loss the
        caller can never avoid.
        """
        with ScratchDir("clamp") as directory:
            path = directory / "wide.xlsx"
            wide = list(range(spreadsheet.MAX_COLUMNS + 10))
            written = spreadsheet.write(
                {"sheets": [{"name": "W", "rows": [wide, wide]}]}, str(path)
            )
            self.assertEqual(len(written["sheets"]), 1)

            read_back = spreadsheet.read(path.read_bytes())
            sheet = read_back["sheets"][0]
            self.assertFalse(read_back["truncated_columns"])
            self.assertEqual(len(sheet["rows"][0]), spreadsheet.MAX_COLUMNS)

            # A workbook built outside the helper, wider than the ceiling, is
            # the case the flag exists for.
            native = directory / "native.xlsx"
            book = spreadsheet.openpyxl.Workbook()
            book.active.append(list(range(spreadsheet.MAX_COLUMNS + 25)))
            book.save(native)
            book.close()
            native_read = spreadsheet.read(native.read_bytes())
            self.assertTrue(native_read["truncated_columns"])
            self.assertEqual(
                len(native_read["sheets"][0]["rows"][0]), spreadsheet.MAX_COLUMNS
            )

    def test_declares_what_a_read_does_not_retain(self) -> None:
        with ScratchDir("notretained") as directory:
            path = directory / "plain.xlsx"
            spreadsheet.write({"sheets": [{"name": "S", "rows": [["a"]]}]}, str(path))
            read_back = spreadsheet.read(path.read_bytes())
            self.assertTrue(read_back["not_retained"])
            joined = " ".join(read_back["not_retained"]).lower()
            for expected in ("formatting", "merged cell", "chart", "formula"):
                self.assertIn(expected, joined)


class WordTests(unittest.TestCase):
    def test_paragraphs_and_tables_round_trip_in_document_order(self) -> None:
        with ScratchDir("docx") as directory:
            path = directory / "doc.docx"
            spec = {
                "blocks": [
                    {"kind": "paragraph", "text": "before the table"},
                    {
                        "kind": "table",
                        "rows": [["h1", "h2"], ["a", "b"], ["c", "d"]],
                    },
                    {"kind": "paragraph", "text": "after the table"},
                ]
            }
            written = word.write(spec, str(path))
            self.assertEqual(written["block_count"], 3)

            read_back = word.read(path.read_bytes())
            kinds = [block["kind"] for block in read_back["blocks"]]
            # Order is the property: python-docx exposes paragraphs and tables as
            # two separate collections, so all-paragraphs-then-all-tables would
            # reorder the document without any error.
            self.assertEqual(kinds, ["paragraph", "table", "paragraph"])
            self.assertEqual(read_back["blocks"][0]["text"], "before the table")
            self.assertEqual(read_back["blocks"][2]["text"], "after the table")
            self.assertEqual(
                read_back["blocks"][1]["rows"], [["h1", "h2"], ["a", "b"], ["c", "d"]]
            )

    def test_run_formatting_survives(self) -> None:
        with ScratchDir("runs") as directory:
            path = directory / "runs.docx"
            word.write(
                {
                    "blocks": [
                        {
                            "kind": "paragraph",
                            "runs": [
                                {"text": "plain "},
                                {"text": "bold", "bold": True},
                                {"text": "italic", "italic": True},
                            ],
                        }
                    ]
                },
                str(path),
            )
            block = word.read(path.read_bytes())["blocks"][0]
            self.assertEqual(block["text"], "plain bolditalic")
            self.assertEqual(block["run_count"], 3)
            flags = [(run["text"], run["bold"], run["italic"]) for run in block["runs"]]
            self.assertEqual(
                flags,
                [("plain ", None, None), ("bold", True, None), ("italic", None, True)],
            )

    def test_declares_what_a_read_does_not_retain(self) -> None:
        with ScratchDir("docx-notretained") as directory:
            path = directory / "plain.docx"
            word.write({"blocks": [{"kind": "paragraph", "text": "x"}]}, str(path))
            read_back = word.read(path.read_bytes())
            joined = " ".join(read_back["not_retained"]).lower()
            for expected in ("tracked changes", "comment", "header", "embedded"):
                self.assertIn(expected, joined)


class HelperProtocolTests(unittest.TestCase):
    def test_rejects_a_format_it_does_not_carry(self) -> None:
        """ODS and ODT are Collabora's job; the helper has no native reader."""
        code, payload, _ = run_helper(
            {"op": "read", "format": "ods", "document": base64.b64encode(b"x").decode()}
        )
        self.assertEqual(code, 1)
        self.assertIn("not one of", payload["error"])

    def test_rejects_an_unknown_operation(self) -> None:
        code, payload, _ = run_helper({"op": "delete", "format": "xlsx"})
        self.assertEqual(code, 1)
        self.assertIn("unknown operation", payload["error"])

    def test_a_helper_failure_is_json_not_a_traceback(self) -> None:
        code, payload, stderr = run_helper(
            {"op": "write", "format": "xlsx", "path": "/tmp/x.xlsx", "spec": {"sheets": []}}
        )
        self.assertEqual(code, 1)
        self.assertIn("sheets", payload["error"])
        self.assertNotIn("Traceback", stderr)

    def test_malformed_stdin_is_json_not_a_traceback(self) -> None:
        """The installed wrapper imports main(); a __main__ guard would miss it."""
        process = subprocess.run(
            [sys.executable, "-m", "ai_tools_office"],
            input="this is not json",
            capture_output=True,
            text=True,
            cwd=HELPER_ROOT,
            check=False,
        )
        self.assertEqual(process.returncode, 1)
        self.assertNotIn("Traceback", process.stderr)
        self.assertIn("error", json.loads(process.stderr))

    def test_a_full_write_read_cycle_over_the_protocol(self) -> None:
        with ScratchDir("protocol") as directory:
            path = directory / "cycle.xlsx"
            code, payload, _ = run_helper(
                {
                    "op": "write",
                    "format": "xlsx",
                    "path": str(path),
                    "spec": {
                        "sheets": [
                            {"name": "One", "rows": [["a", "b"]]},
                            {"name": "Two", "rows": [["c"]]},
                        ]
                    },
                }
            )
            self.assertEqual(code, 0, payload)
            self.assertEqual(payload["sheets"], ["One", "Two"])

            code, payload, _ = run_helper(
                {
                    "op": "read",
                    "format": "xlsx",
                    "document": base64.b64encode(path.read_bytes()).decode(),
                }
            )
            self.assertEqual(code, 0, payload)
            self.assertEqual(payload["sheet_count"], 2)
            self.assertEqual(
                [sheet["name"] for sheet in payload["sheets"]], ["One", "Two"]
            )


if __name__ == "__main__":
    unittest.main()