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
    def test_memory_health_detects_pressure_duplicates_and_old_proposals_without_content(self):
        import os,time
        with tempfile.TemporaryDirectory(prefix='hermes-learning-health-') as directory:
            home=Path(directory);(home/'memories').mkdir()
            (home/'config.yaml').write_text('memory:\n  memory_char_limit: 80\n  user_char_limit: 1375\n  memory_enabled: true\n  user_profile_enabled: false\n')
            fact='Workstation: PRIVATE FACT on the workstation.'
            (home/'memories/MEMORY.md').write_text(fact+'\n§\n'+fact.lower())
            pending=home/'pending/memory';pending.mkdir(parents=True)
            proposal=pending/'1234abcd.json';proposal.write_text('{"PRIVATE PAYLOAD":"do not emit"}')
            old=time.time()-9*86400;os.utime(proposal,(old,old))
            before={p:p.read_bytes() for p in home.rglob('*') if p.is_file()}
            health=performance.memory_health(home)
            self.assertEqual('attention',health['status'])
            self.assertEqual(1,health['stores']['memory']['normalized_duplicates'])
            self.assertTrue(health['stores']['memory']['capacity_pressure'])
            self.assertFalse(health['stores']['user']['enabled'])
            self.assertEqual(1,health['pending']['older_than_seven_days'])
            self.assertEqual(before,{p:p.read_bytes() for p in before})
            self.assertNotIn('PRIVATE',json.dumps(health))
            (home/'config.yaml').write_text('memory: [incompatible]')
            self.assertEqual('unknown',performance.memory_health(home)['status'])

    def test_memory_health_notices_guard_and_nudge_configuration_drift(self):
        with tempfile.TemporaryDirectory(prefix='hermes-learning-drift-') as directory:
            home=Path(directory);(home/'scripts').mkdir()
            guard=home/'scripts/memory-policy.py';guard.write_text('Fixture guard')
            config={'memory':{'nudge_interval':0},'skills':{'creation_nudge_interval':0},
                'hooks':{'pre_tool_call':[{'command':performance.shlex.join(['python3',str(guard)]),
                    'matcher':'^(memory|skill_manage)$','fail_closed':True}]}}
            (home/'config.yaml').write_text(json.dumps(config))
            self.assertEqual('ok',performance.memory_health(home)['status'])
            config['hooks']['pre_tool_call'][0]['fail_closed']=False
            config['skills']['creation_nudge_interval']=15
            (home/'config.yaml').write_text(json.dumps(config))
            result=performance.memory_health(home)
            self.assertEqual('attention',result['status'])
            self.assertFalse(result['guard_present']);self.assertFalse(result['event_driven'])

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

    def test_failure_taxonomy_counts_unknowns_without_leaking_metadata(self):
        with closing(sqlite3.connect(self.board)) as db:
            db.execute("INSERT INTO task_runs VALUES ('private-failure','head-coordinator',180,190,'failed','failed',?)",
                       (json.dumps({'failure_category':'provider_unavailable'}),))
            db.execute("INSERT INTO task_runs VALUES ('private-unknown','head-coordinator',181,191,'failed','failed',?)",
                       (json.dumps({'failure_category':'SECRET failure payload'}),))
            db.commit()
        result=performance.report(self.root,100,200)
        runs=result['profiles']['head-coordinator']['runs']
        self.assertEqual({'worker_crash':1,'provider_unavailable':1,'unknown':1},runs['failure_causes'])
        self.assertEqual(1,runs['reported_failure_category_runs'])
        self.assertEqual(1,runs['repeat_attempts'])
        self.assertNotIn('SECRET',json.dumps(result))

    def test_model_accounting_and_worker_join_coverage_are_explicit(self):
        with closing(sqlite3.connect(self.state)) as db:
            db.executescript('''ALTER TABLE sessions ADD COLUMN id TEXT;
                UPDATE sessions SET id='SECRET-ID' WHERE started_at=150;
                CREATE TABLE session_model_usage(session_id TEXT,model TEXT,billing_provider TEXT,task TEXT,
                  api_call_count INTEGER,input_tokens INTEGER,output_tokens INTEGER,
                  cache_read_tokens INTEGER,cache_write_tokens INTEGER,reasoning_tokens INTEGER,
                  estimated_cost_usd REAL,actual_cost_usd REAL,cost_status TEXT);
                INSERT INTO session_model_usage VALUES
                  ('SECRET-ID','model-a','provider-a','',2,100,20,60,0,10,.01,0,'estimated'),
                  ('SECRET-ID','model-b','provider-b','vision',1,50,10,0,0,0,0,0,'unknown'),
                  ('SECRET-ID','https://private.example.invalid/path','https://private.example.invalid',
                   'title_generation',1,5,1,0,0,0,0,0,'included');''')
            db.commit()
        result=performance.report(self.root,100,200)
        profile=result['profiles']['head-coordinator']
        self.assertEqual(1,profile['runs']['worker_session_id_matched'])
        usage=profile['sessions']['model_usage']
        self.assertEqual(4,usage['api_call_count'])
        self.assertEqual(3,len(usage['by_model']))
        self.assertEqual({'main','vision','title_generation'},{r['task'] for r in usage['by_model']})
        self.assertEqual(1,usage['estimated_cost_rows'])
        self.assertEqual(0,usage['actual_cost_rows'])
        self.assertIsNone(usage['actual_cost_usd'])
        self.assertEqual({'estimated':1,'unknown':1,'included':1},usage['cost_status_rows'])
        self.assertNotIn('SECRET-ID',json.dumps(result))
        self.assertNotIn('private.example.invalid',json.dumps(result))
        with patch.object(performance,'MAX_MODEL_ROWS',2):
            self.assertIsNone(performance.report(self.root,100,200)['profiles']['head-coordinator']['sessions']['model_usage'])

    def test_terminal_provider_exit_is_not_reported_as_worker_crash(self):
        with closing(sqlite3.connect(self.board)) as db:
            db.execute("UPDATE task_runs SET metadata=? WHERE status='crashed'",
                       (json.dumps({'exit_kind': 'terminal_provider', 'terminal_provider': True,
                                    'worker_output': 'SECRET provider diagnostics'}),))
            db.commit()
        result = performance.report(self.root,100,200)
        runs = result['profiles']['head-coordinator']['runs']
        self.assertEqual({'provider_terminal': 1}, runs['failure_causes'])
        self.assertEqual(1, runs['terminal_provider_runs'])
        self.assertEqual(0, runs['reported_failure_category_runs'])
        self.assertNotIn('SECRET',json.dumps(result))

    def test_untrusted_terminal_marker_does_not_classify_a_crash(self):
        with closing(sqlite3.connect(self.board)) as db:
            db.execute("UPDATE task_runs SET metadata=? WHERE status='crashed'",
                       (json.dumps({'terminal_provider': 'true', 'exit_kind': 'terminal_provider'}),))
            db.commit()
        runs = performance.report(self.root,100,200)['profiles']['head-coordinator']['runs']
        self.assertEqual({'worker_crash': 1}, runs['failure_causes'])
        self.assertEqual(0, runs['terminal_provider_runs'])

    def test_daily_collector_does_not_parse_its_callers_arguments(self):
        with patch.dict(performance.os.environ, {'HERMES_ROOT': str(self.root)}):
            with patch.object(sys, 'argv', ['daily-steward-window.py', '--scheduler-context']):
                with contextlib.redirect_stdout(io.StringIO()) as output:
                    performance.main()
        self.assertIn('HERMES PERFORMANCE',output.getvalue())


unittest.main(argv=['performance'],verbosity=2)
PY
