import importlib.util
import json
import os
import sys
import tempfile
import time
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).parents[1] / "helpers" / "homepage-admin-dashboard-logs.py"
SPEC = importlib.util.spec_from_file_location("homepage_admin_dashboard_logs", SCRIPT)
assert SPEC and SPEC.loader
collector = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(collector)


class CollectorProjectionTests(unittest.TestCase):
    def test_projection_discards_message_and_keeps_only_valid_fixed_metadata(self):
        raw = json.dumps({
            "__REALTIME_TIMESTAMP": "1800000000000000",
            "PRIORITY": "3",
            "_SYSTEMD_UNIT": "homepage.service",
            "MESSAGE": "token=must-never-escape",
            "_PID": "42",
        })
        record = collector.parse_record(raw, "homepage.service")
        self.assertEqual(record, {
            "timestamp": "2027-01-15T08:00:00.000000Z",
            "priority": 3,
            "message": collector.SAFE_MESSAGE,
        })
        self.assertNotIn("must-never-escape", json.dumps(record))

    def test_wrong_unit_and_missing_metadata_invalidate_the_observation(self):
        with self.assertRaises(collector.InvalidRecord):
            collector.parse_record(json.dumps({
                "__REALTIME_TIMESTAMP": "1800000000000000",
                "PRIORITY": "3",
                "_SYSTEMD_UNIT": "other.service",
            }), "homepage.service")
        with self.assertRaises(collector.InvalidRecord):
            collector.parse_record(json.dumps({
                "__REALTIME_TIMESTAMP": "1800000000000000",
                "_SYSTEMD_UNIT": "homepage.service",
            }), "homepage.service")

    def test_collection_uses_fixed_literal_argv_and_publishes_normalized_schema(self):
        manifest = {"schemaVersion": 1, "units": [
            {"id": "homepage", "label": "Homepage", "unit": "homepage.service"},
            {"id": "service-access-canary", "label": "Service access canary", "unit": "homepage-canary.service"},
        ]}
        record = json.dumps({
            "__REALTIME_TIMESTAMP": "1800000000000000",
            "PRIORITY": "3",
            "_SYSTEMD_UNIT": "homepage.service",
            "MESSAGE": "private text",
        }) + "\n"
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "logs.json"
            with patch.object(collector, "_read_child", return_value=record.encode()) as read_child:
                collector.collect(manifest, "/nix/store/journalctl", output, now_us=1800000000000000)
                calls = [call.args[0] for call in read_child.call_args_list]
                self.assertEqual(len(calls), 2)
                self.assertEqual(calls[0][:2], ["/nix/store/journalctl", "--since=@1799913600"])
                self.assertIn("--until=@1800000000", calls[0])
                self.assertIn("--priority=0..3", calls[0])
                self.assertIn("--reverse", calls[0])
                self.assertIn("--lines=101", calls[0])
                self.assertIn("--no-pager", calls[0])
                self.assertIn("--output=json", calls[0])
                self.assertIn("--output-fields=__REALTIME_TIMESTAMP,PRIORITY,_SYSTEMD_UNIT", calls[0])
                self.assertIn("_SYSTEMD_UNIT=homepage.service", calls[0])
                self.assertIn("_SYSTEMD_UNIT=homepage-canary.service", calls[1])
                self.assertNotIn("MESSAGE", calls[0])
            report = json.loads(output.read_text())
            self.assertEqual(report["units"][0]["entries"][0]["message"], collector.SAFE_MESSAGE)
            self.assertEqual(output.stat().st_mode & 0o777, 0o640)
            self.assertNotIn("private text", output.read_text())

    def test_collection_runs_a_real_child_and_never_publishes_its_stderr(self):
        manifest = {"schemaVersion": 1, "units": [
            {"id": "homepage", "label": "Homepage", "unit": "homepage.service"},
            {"id": "service-access-canary", "label": "Service access canary", "unit": "homepage-canary.service"},
        ]}
        now_us = time.time_ns() // 1000
        record = {
            "__REALTIME_TIMESTAMP": str(now_us - 1_000_000),
            "PRIORITY": "2",
            "_SYSTEMD_UNIT": "homepage.service",
            "MESSAGE": "raw-password=fixture-only",
        }
        with tempfile.TemporaryDirectory() as directory:
            command = Path(directory) / "journalctl-fixture"
            command.write_text(
                f"#!{sys.executable}\nimport json,sys\nprint('fixture stderr password=hidden', file=sys.stderr)\nprint(json.dumps({record!r}))\n",
                encoding="utf-8",
            )
            command.chmod(0o755)
            output = Path(directory) / "status.json"
            collector.collect(manifest, str(command), output, now_us=now_us)
            serialized = output.read_text(encoding="utf-8")
            self.assertIn(collector.SAFE_MESSAGE, serialized)
            self.assertNotIn("raw-password", serialized)
            self.assertNotIn("fixture stderr", serialized)

    def test_failed_journal_collection_is_published_as_an_unavailable_unit(self):
        manifest = {"schemaVersion": 1, "units": [
            {"id": "homepage", "label": "Homepage", "unit": "homepage.service"},
            {"id": "service-access-canary", "label": "Service access canary", "unit": "homepage-canary.service"},
        ]}
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "status.json"
            with patch.object(collector, "_read_child", side_effect=collector.CollectionError("private failure path")):
                report = collector.collect(manifest, "/nix/store/journalctl", output, now_us=1800000000000000)
            self.assertEqual(report["units"][0]["state"], "unavailable")
            self.assertNotIn("private failure path", output.read_text())


if __name__ == "__main__":
    unittest.main()
