#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  echo 'Use the authorised fixture-runner for isolated policy loader tests' >&2
  exit 2
fi
python3 -B - "$repo" <<'PY'
from contextlib import closing
import hashlib
import importlib.util
import os
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest

repo = Path(sys.argv[1])
native = Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2]
sys.path.insert(0, str(native))
spec = importlib.util.spec_from_file_location('coordinator_policy_loader',
                                           repo / 'scripts/hermes/coordinator_tools.py')
manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manager)


class PolicyLoaderTest(unittest.TestCase):
    def setUp(self):
        self.root = task / self._testMethodName
        self.scripts = self.root / 'scripts'
        self.scripts.mkdir(parents=True)
        self.path = self.root / 'kanban/boards/fixture/kanban.db'
        self.path.parent.mkdir(parents=True)
        with closing(sqlite3.connect(self.path)) as db, db:
            db.executescript('''
                CREATE TABLE tasks (id TEXT, body TEXT, tenant TEXT, assignee TEXT, status TEXT);
                CREATE TABLE task_events (id INTEGER, task_id TEXT, kind TEXT, payload TEXT, run_id INTEGER);
                CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
                CREATE TABLE task_runs (id INTEGER, task_id TEXT, started_at INTEGER);
                INSERT INTO tasks VALUES ('t_route', 'Existing handoff', 'technical-recovery',
                                          'head-coordinator', 'blocked');
            ''')
        # Each public import must start cold, without another test's cached root.
        names = ('fleet_contract', 'fleet_workflow', 'board_progress', 'policy_lazy_probe')
        saved = {name: sys.modules.pop(name) for name in names if name in sys.modules}
        def restore_modules():
            for name in names:
                sys.modules.pop(name, None)
            sys.modules.update(saved)
        self.addCleanup(restore_modules)
        previous = sys.path[:]
        self.addCleanup(lambda: sys.path.__setitem__(slice(None), previous))

    def public_policies(self):
        # The installed native mirrors contain the actual public script bytes.
        # Load them under their public names to exercise the affected lazy import,
        # rather than the package-relative branch used by native fleet_contract.
        (self.scripts / 'review-verdict-guard.py').write_bytes(
            (repo / 'scripts/hermes/review-verdict-guard.py').read_bytes())
        for name in ('fleet_contract', 'fleet_workflow', 'board_progress'):
            (self.scripts / (name + '.py')).write_bytes(
                (native / ('hermes_cli/nixhomeserver_' + name + '.py')).read_bytes())
        self.assertIn('from board_progress import require_completion',
                      (self.scripts / 'fleet_contract.py').read_text())

    def policy(self, action='complete', fields=None):
        previous, path_object = sys.path[:], sys.path
        before = hashlib.sha256(self.path.read_bytes()).hexdigest()
        try:
            return manager._policy(self.root, 'fixture', 't_route', action,
                                   fields or {}, 'Input supplier: agent. Fixture evidence only.')
        finally:
            self.assertIs(path_object, sys.path)
            self.assertEqual(previous, sys.path)
            self.assertEqual(before, hashlib.sha256(self.path.read_bytes()).hexdigest())

    def test_real_completion_resolves_lazy_public_board_progress(self):
        self.public_policies()
        self.assertNotIn(str(self.scripts), sys.path)
        self.assertIsNone(self.policy(fields={'metadata': {}}))
        for name in ('fleet_contract', 'fleet_workflow', 'board_progress'):
            self.assertEqual(self.scripts / (name + '.py'), Path(sys.modules[name].__file__))

    def test_real_supervision_guard_still_refuses_unproven_dispatch(self):
        self.public_policies()
        with closing(sqlite3.connect(self.path)) as db, db:
            db.execute("UPDATE tasks SET tenant='board-progress', body='Dispatch policy: parallel-v1'")
        with self.assertRaisesRegex(ValueError, 'Delegation is queued, not proven started'):
            self.policy(fields={'metadata': {}})

    def test_trusted_scripts_precede_ambient_foreign_modules(self):
        self.public_policies()
        foreign = self.root / 'foreign'
        foreign.mkdir()
        for name in ('fleet_contract', 'fleet_workflow', 'board_progress'):
            (foreign / (name + '.py')).write_text("raise RuntimeError('foreign policy executed')\n")
        sys.path.insert(0, str(foreign))
        self.assertIsNone(self.policy(fields={'metadata': {}}))
        self.assertEqual(self.scripts / 'board_progress.py',
                         Path(sys.modules['board_progress'].__file__))

    def lazy_guard(self, filename, outcome, alerts=False):
        arguments = 'payload, root, alerts' if alerts else 'payload, root'
        (self.scripts / filename).write_text(
            'def guard(' + arguments + '):\n'
            '    from policy_lazy_probe import check\n'
            '    return check(root)\n')
        (self.scripts / 'policy_lazy_probe.py').write_text(
            'import sys\nfrom pathlib import Path\n'
            'def check(root):\n'
            "    assert Path(__file__).parent == root / 'scripts'\n"
            "    sys.path.append('callback-path-change')\n" + outcome)

    def test_callback_path_changes_are_restored_after_success(self):
        self.lazy_guard('review-verdict-guard.py', '    return {}\n')
        self.assertIsNone(self.policy())

    def test_callback_import_error_propagates_and_restores_path(self):
        self.lazy_guard('review-verdict-guard.py',
                        "    raise ImportError('lazy dependency failed')\n")
        with self.assertRaisesRegex(ImportError, '^lazy dependency failed$'):
            self.policy()

    def test_guard_load_exception_restores_path(self):
        (self.scripts / 'review-verdict-guard.py').write_text(
            "import sys\nsys.path.append('load-path-change')\nraise RuntimeError('guard load failed')\n")
        with self.assertRaisesRegex(RuntimeError, '^guard load failed$'):
            self.policy()

    def test_block_and_reclaim_callbacks_keep_trusted_import_scope(self):
        (self.scripts / 'kanban-owner-alerts.py').write_text('FIXTURE = True\n')
        self.lazy_guard('owner-blocker-authoring-guard.py', '    return {}\n', alerts=True)
        for action in ('block', 'reclaim'):
            with self.subTest(action=action):
                self.assertIsNone(self.policy(action=action, fields={'kind': 'capability'}))

    def test_block_callback_exception_restores_nested_scope(self):
        (self.scripts / 'kanban-owner-alerts.py').write_text('FIXTURE = True\n')
        self.lazy_guard('owner-blocker-authoring-guard.py',
                        "    raise RuntimeError('block callback failed')\n", alerts=True)
        with self.assertRaisesRegex(RuntimeError, '^block callback failed$'):
            self.policy(action='block', fields={'kind': 'capability'})

    def test_missing_and_symlinked_guard_are_still_refused(self):
        with self.assertRaisesRegex(ValueError, 'Required installed policy is unavailable'):
            self.policy()
        outside = self.root / 'foreign-guard.py'
        outside.write_text("raise RuntimeError('symlink guard executed')\n")
        (self.scripts / 'review-verdict-guard.py').symlink_to(outside)
        with self.assertRaisesRegex(ValueError, 'Required installed policy is unavailable'):
            self.policy()


with tempfile.TemporaryDirectory(prefix='coordinator-policy-loader-') as directory:
    task = Path(directory)
    unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
