#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import contextlib
import importlib.util
import io
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

source=Path(sys.argv[1])/'scripts/hermes'
sys.path.insert(0,str(source))
import autonomy_runtime as runtime
from autonomy_runtime_adapter import adapt,EDITS
spec=importlib.util.spec_from_file_location('installer',source/'install-autonomy-policy.py')
installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)


class RuntimeTest(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory(prefix='hermes-autonomy-runtime-',dir='/tmp')
        self.addCleanup(self.temp.cleanup);self.root=Path(self.temp.name)
        self.base=self.root/'kanban/boards';self.base.mkdir(parents=True)
        for board in ('alpha','beta'):
            p=self.base/board/'kanban.db';p.parent.mkdir()
            with contextlib.closing(sqlite3.connect(p)) as db:
                db.execute('CREATE TABLE tasks(id TEXT)');db.execute('INSERT INTO tasks VALUES(?)',(board,))
                db.commit()
        self.kb=SimpleNamespace(kanban_home=lambda:self.root)
        self.patch=patch.dict(sys.modules,{'hermes_cli':SimpleNamespace(kanban_db=self.kb)})
        self.patch.start();self.addCleanup(self.patch.stop)

    @contextlib.contextmanager
    def original(self,board):
        with contextlib.closing(sqlite3.connect(self.base/'alpha/kanban.db')) as db:
            yield self.kb,db

    def test_coordinator_reads_explicit_board_without_changing_pin_or_writing(self):
        pin=str(self.base/'alpha/kanban.db')
        before=(self.base/'beta/kanban.db').read_bytes()
        with patch.dict(os.environ,{'HERMES_KANBAN_DB':pin,'HERMES_KANBAN_TASK':'t_alpha'}):
            with runtime.evidence_board(self.original,'beta','head-coordinator') as (_,db):
                self.assertEqual('beta',db.execute('SELECT id FROM tasks').fetchone()[0])
                with self.assertRaises(sqlite3.Error):db.execute("INSERT INTO tasks VALUES('bad')")
            self.assertEqual(pin,os.environ['HERMES_KANBAN_DB'])
        self.assertEqual(before,(self.base/'beta/kanban.db').read_bytes())

    def test_other_roles_and_delegates_keep_the_original_native_scope(self):
        for profile in ('standard-implementer','feature-reviewer','project-auditor'):
            with runtime.evidence_board(self.original,'beta',profile) as (_,db):
                self.assertEqual('alpha',db.execute('SELECT id FROM tasks').fetchone()[0])
        with patch.dict(os.environ,{'HERMES_DELEGATED_CHILD_CONTEXT':'fixture'}):
            with runtime.evidence_board(self.original,'beta','head-coordinator') as (_,db):
                self.assertEqual('alpha',db.execute('SELECT id FROM tasks').fetchone()[0])

    def test_missing_and_escaping_boards_never_create_state(self):
        for board in ('../escape','missing'):
            with self.assertRaises((ValueError,sqlite3.Error)):
                with runtime.evidence_board(self.original,board,'head-coordinator'):pass
        self.assertFalse((self.base/'missing').exists())
        (self.base/'alias').symlink_to(self.root)
        with self.assertRaises(ValueError):
            with runtime.evidence_board(self.original,'alias','head-coordinator'):pass

    def test_only_declared_fallbacks_are_used_and_credential_lane_never_cloud(self):
        chain=[{'provider':'openai-codex','model':'fixture'}]
        self.assertIs(chain,runtime.allowed_fallbacks(chain,'head-coordinator'))
        self.assertIs(chain,runtime.allowed_fallbacks(chain,'standard-implementer'))
        self.assertEqual([],runtime.allowed_fallbacks(chain,'local-implementer'))
        self.assertEqual([{'provider':'openai-codex','model':'fixture'}],chain)

    def fixtures(self):
        return {
            'tools/kanban_tools.py':'def fixture(args):\n'+EDITS['tools/kanban_tools.py'][0][0]+'"ok":True})\n',
            'hermes_cli/fallback_config.py':'def fixture():\n'+EDITS['hermes_cli/fallback_config.py'][0][0]+'arg):\n    pass\n',
            'agent/agent_init.py':'def fixture():\n'+EDITS['agent/agent_init.py'][0][0],
        }

    def test_adapter_is_idempotent_and_refuses_source_drift(self):
        for name,text in self.fixtures().items():
            updated=adapt(name,text);self.assertEqual(updated,adapt(name,updated))
            with self.assertRaises(ValueError):adapt(name,'pass\n')

    def test_install_preflights_all_targets_preserves_settings_and_converges(self):
        for name,text in self.fixtures().items():
            path=self.root/'hermes-agent'/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)
        config=self.root/'config.yaml';config.write_text('model: unchanged\n')
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(1,installer.install(self.root,check=True))
            self.assertFalse((self.root/'scripts').exists())
            self.assertEqual(0,installer.install(self.root))
            self.assertEqual(0,installer.install(self.root,check=True))
        self.assertEqual('model: unchanged\n',config.read_text())
        self.assertTrue((self.root/'backups/autonomy-policy').is_dir())
        (self.root/'hermes-agent/tools/kanban_tools.py').write_text('pass\n')
        receipt=self.root/'scripts/autonomy-policy.py';before=receipt.read_bytes()
        with self.assertRaises(ValueError):installer.install(self.root)
        self.assertEqual(before,receipt.read_bytes())


unittest.main(argv=[sys.argv[0]],verbosity=2)
PY
