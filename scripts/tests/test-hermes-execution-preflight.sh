#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import execution_preflight as preflight


class PreflightTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='execution-preflight-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / 'source'; self.work.mkdir()
        for name in ('nixhomeserver_resume_recovered.py', 'nixhomeserver_coordinator_repair.py'):
            path=self.root/'hermes-agent/hermes_cli'/name
            path.parent.mkdir(parents=True,exist_ok=True);path.touch()
        self.db=sqlite3.connect(':memory:');self.db.row_factory=sqlite3.Row;self.addCleanup(self.db.close)
        self.db.executescript('''CREATE TABLE tasks(id TEXT,workspace_path TEXT,workspace_kind TEXT,status TEXT);
          CREATE TABLE task_events(id INTEGER PRIMARY KEY,task_id TEXT,kind TEXT,payload TEXT,run_id INTEGER);
          CREATE TABLE task_runs(id INTEGER,task_id TEXT,profile TEXT,status TEXT,outcome TEXT,metadata TEXT);''')
        self.db.execute('INSERT INTO tasks VALUES(?,?,?,?)',('t_test',str(self.work),'dir','ready'))

    def contract(self, **fields):
        self.db.execute('DELETE FROM task_events')
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES('t_test','created',?)",
                        (json.dumps({'workflow':{'version':1,**fields}}),))

    def git(self, *args):
        return subprocess.check_output(['git','-C',str(self.work),*args],stderr=subprocess.DEVNULL,text=True).strip()

    def test_missing_workspace_prevents_spawn_but_unprepared_worktree_defers(self):
        self.contract()
        self.db.execute("UPDATE tasks SET workspace_path='/no/such/fixture/workspace'")
        self.assertIn('missing assigned workspace',preflight.reason(self.db,'t_test',self.root,'standard-implementer'))
        self.db.execute("UPDATE tasks SET workspace_kind='worktree'")
        self.assertIsNone(preflight.reason(self.db,'t_test',self.root,'standard-implementer'))
        self.db.execute("UPDATE tasks SET status='running'")
        self.assertIn('missing assigned workspace',preflight.reason(self.db,'t_test',self.root,'standard-implementer'))

    def test_missing_tools_and_modules_report_technical_gap_without_grant(self):
        self.contract(requirements={'tools':['terminal'],'imports':['json']})
        with patch.object(preflight,'capabilities',return_value={'tools':[],'imports':{'json':False}}):
            reason=preflight.reason(self.db,'t_test',self.root,'feature-reviewer')
        self.assertIn('tools=terminal modules=json',reason)
        self.assertIn('Input supplier: agent',reason)

    def test_implementation_can_advance_from_baseline_but_wrong_source_refuses(self):
        self.git('init'); self.git('config','user.name','Fixture');self.git('config','user.email','fixture@example.invalid')
        self.git('commit','--allow-empty','-m','baseline'); baseline=self.git('rev-parse','HEAD')
        self.git('commit','--allow-empty','-m','implementation')
        self.contract(requirements={'source_revision':baseline})
        self.assertIsNone(preflight.reason(self.db,'t_test',self.root,'standard-implementer'))
        self.contract(requirements={'source_revision':'a'*40})
        self.assertIn('does not match',preflight.reason(self.db,'t_test',self.root,'standard-implementer'))

    def test_broken_capability_helper_is_a_technical_refusal(self):
        self.contract(requirements={'imports':['json']})
        with patch.object(preflight,'capabilities',side_effect=ModuleNotFoundError('missing helper')):
            self.assertIn('Input supplier: agent',preflight.reason(self.db,'t_test',self.root,'standard-implementer'))


unittest.main(argv=[sys.argv[0]])
PY
