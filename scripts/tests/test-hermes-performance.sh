#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
from contextlib import closing
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('performance', Path(sys.argv[1])/'scripts/hermes/kanban-performance.py')
performance = importlib.util.module_from_spec(spec)
spec.loader.exec_module(performance)


class PerformanceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='nixhomeserver-hermes-performance-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.home = self.root/'profiles/head-coordinator'
        self.home.mkdir(parents=True)
        (self.home/'SOUL.md').write_text('Short standing rules.\n')
        self.state = self.home/'state.db'
        with closing(sqlite3.connect(self.state)) as db:
            db.executescript('''CREATE TABLE sessions (
                started_at REAL, input_tokens INTEGER, output_tokens INTEGER,
                cache_read_tokens INTEGER, cache_write_tokens INTEGER,
                api_call_count INTEGER, tool_call_count INTEGER, system_prompt TEXT);
                INSERT INTO sessions VALUES (150,100,20,60,0,2,3,'PRIVATE PROMPT');
                INSERT INTO sessions VALUES (160,0,0,0,0,0,0,NULL);
                INSERT INTO sessions VALUES (50,9999,9999,0,0,99,99,'OLD');
                INSERT INTO sessions VALUES (200,9999,9999,0,0,99,99,'LATER');''')
            db.commit()
        self.board = self.root/'kanban/boards/one/kanban.db'
        self.board.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.board)) as db:
            db.executescript('''CREATE TABLE task_runs (
                task_id TEXT, profile TEXT, started_at REAL, ended_at REAL,
                status TEXT, outcome TEXT, metadata TEXT);
                CREATE TABLE task_events(task_id TEXT,kind TEXT,created_at REAL);
                INSERT INTO task_runs VALUES ('PRIVATE-ID','head-coordinator',110,120,'crashed','crashed','{}');
                INSERT INTO task_runs VALUES ('PRIVATE-ID','head-coordinator',130,160,'completed','done',
                    '{"worker_session_id":"SECRET-ID","verdict":"accept"}');
                INSERT INTO task_runs VALUES ('other','head-coordinator',170,NULL,'running',NULL,'broken json');
                INSERT INTO task_events VALUES ('PRIVATE-ID','completed',180);
                INSERT INTO task_events VALUES ('PRIVATE-ID','completed',190);
                INSERT INTO task_events VALUES ('PRIVATE-ID','changes_requested',195);
                INSERT INTO task_events VALUES ('old','completed',50);''')
            db.commit()

    def test_report_is_readonly_has_correct_cohorts_and_no_private_payload(self):
        before = {p:p.read_bytes() for p in (self.state,self.board)}
        report = performance.report(self.root,100,200)
        profile = report['profiles']['head-coordinator']
        sessions = profile['sessions']
        self.assertEqual(2,sessions['count'])
        self.assertEqual(1,sessions['usage_reported_sessions'])
        self.assertEqual(100,sessions['input_tokens'])
        self.assertEqual(60,sessions['cache_read_tokens'])
        self.assertEqual(4,sessions['all_stored_sessions']['count'])
        self.assertEqual(20098,sessions['all_stored_sessions']['input_tokens'])
        runs = profile['runs']
        self.assertEqual(3,runs['count'])
        self.assertEqual(1,runs['failures'])
        self.assertEqual(1,runs['repeat_attempt_tasks'])
        self.assertEqual({'n':2,'p50':10,'p95':30},runs['elapsed_seconds'])
        self.assertEqual(1,runs['worker_session_id_present'])
        self.assertEqual(1,report['boards']['one']['completed_cards'])
        self.assertEqual({'accept':1},runs['reported_verdicts'])
        self.assertEqual(before,{p:p.read_bytes() for p in before})
        for private in ('PRIVATE-ID','SECRET-ID','PRIVATE PROMPT'):
            self.assertNotIn(private,json.dumps(report))

    def test_missing_and_corrupt_sources_are_unknown_not_zero(self):
        self.state.write_bytes(b'not a database')
        report = performance.report(self.root,100,200)
        self.assertIsNone(report['profiles']['head-coordinator']['sessions'])
        self.assertTrue(report['warnings'])
        self.assertEqual(3,report['profiles']['head-coordinator']['runs']['count'])
        with self.assertRaises(ValueError):
            performance.report(self.root,200,100)

    def test_missing_board_database_is_not_created_or_reported_as_zero(self):
        self.board.unlink()
        (self.board.parent/'board.json').write_text('{}')
        report = performance.report(self.root,100,200)
        self.assertFalse(self.board.exists())
        self.assertIsNone(report['profiles']['head-coordinator']['runs'])
        self.assertIn('unknown',performance.render(report))

    def test_shared_databases_are_not_double_counted(self):
        other = self.root/'profiles/other'
        other.mkdir()
        (other/'SOUL.md').write_text('Other role')
        (other/'state.db').symlink_to(self.state)
        report = performance.report(self.root,100,200)
        self.assertIsNone(report['profiles']['other']['sessions'])
        self.assertTrue(any(w['reason']=='shared_database' for w in report['warnings']))

    def test_daily_collector_does_not_parse_its_callers_arguments(self):
        with patch.dict(performance.os.environ, {'HERMES_ROOT': str(self.root)}):
            with patch.object(sys, 'argv', ['daily-steward-window.py', '--scheduler-context']):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    performance.main()
        self.assertIn('HERMES PERFORMANCE',output.getvalue())


unittest.main(argv=['performance'],verbosity=2)
PY
