#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
spec = importlib.util.spec_from_file_location('supervisor', Path(sys.argv[1]) / 'scripts/hermes/fleet-supervisor.py')
supervisor = importlib.util.module_from_spec(spec)
spec.loader.exec_module(supervisor)


class SupervisorTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='fleet-supervisor-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        board = self.root / 'kanban/boards/test'
        board.mkdir(parents=True)
        (board / 'board.json').write_text('{}')
        self.calls = []

    def runner(self, command, **kwargs):
        self.calls.append(command)
        return {'exit_code': 0, 'output': 'BUSY' if 'idle-recovery-monitor.py' in command[-1] else 'ok'}

    def test_one_tick_runs_due_detectors_without_global_busy_starvation(self):
        self.assertEqual(0, supervisor.tick(self.root, now=100000, runner=self.runner))
        self.assertTrue(any('deadlock_recovery.py' in ' '.join(c) for c in self.calls))
        self.assertTrue(any('fleet-evidence.py' in ' '.join(c) for c in self.calls))
        count = len(self.calls)
        supervisor.tick(self.root, now=100001, runner=self.runner)
        self.assertEqual(count, len(self.calls))
        self.assertTrue((self.root / 'state/fleet/report.json').exists())

    def test_failed_handler_does_not_suppress_other_detectors_and_retries_are_bounded(self):
        def fail(command, **kwargs):
            self.calls.append(command)
            return {'exit_code': 2 if 'deadlock_recovery.py' in ' '.join(command) else 0, 'output': 'fixture'}
        for at in (100000, 100301, 101202, 110000):
            supervisor.tick(self.root, now=at, runner=fail)
        self.assertEqual(3, sum('deadlock_recovery.py' in ' '.join(c) for c in self.calls))
        report = json.loads((self.root / 'state/fleet/report.json').read_text())
        self.assertEqual(3, report['handlers']['technical-recovery']['failures'])

    def test_dry_run_is_read_only(self):
        supervisor.tick(self.root, now=100000, runner=self.runner, dry_run=True)
        self.assertEqual([], self.calls)
        self.assertFalse((self.root / 'state').exists())

    def test_timeout_and_interruption_never_replay_unchanged(self):
        def timeout(command, **kwargs):
            self.calls.append(command)
            return {'exit_code':124,'output':'interrupted'}
        supervisor.tick(self.root,now=100000,runner=timeout)
        count=len(self.calls)
        supervisor.tick(self.root,now=110000,runner=timeout)
        self.assertEqual(count,len(self.calls))

    def test_deliberately_paused_handlers_stay_paused(self):
        directory=self.root/'state/fleet';directory.mkdir(parents=True)
        (directory/'handlers.json').write_text(json.dumps({'evidence':{'enabled':True,'interval':300}}))
        supervisor.tick(self.root,now=100000,runner=self.runner)
        self.assertEqual(1,len(self.calls))
        self.assertIn('fleet-evidence.py',' '.join(self.calls[0]))

    def test_wake_failure_retains_successful_detector_and_other_maintenance(self):
        def health(command,**kwargs):
            self.calls.append(command)
            return {'exit_code':0,'output':'READY_NO_WORKER t_example head-coordinator hard=yes'
                    if 'kanban-board-health.sh' in command[-1] else 'ok'}
        with patch.object(supervisor,'wake_coordinator',side_effect=OSError('native unavailable')):
            self.assertEqual(1,supervisor.tick(self.root,now=100000,runner=health))
        state=json.loads((self.root/'state/fleet/supervisor.json').read_text())
        self.assertEqual(0,state['handlers']['board-health:test']['exit_code'])
        self.assertNotIn('in_flight',state['handlers']['board-health:test'])
        self.assertTrue(any('fleet-evidence.py' in ' '.join(c) for c in self.calls))

    def test_requalification_preserves_attempt_receipt_and_never_touches_boards(self):
        def timeout(*args,**kwargs):return {'exit_code':124,'output':'interrupted'}
        supervisor.tick(self.root,now=100000,runner=timeout)
        evidence=self.root/'state/fleet/evidence/test/t_repair/1.json'
        evidence.parent.mkdir(parents=True)
        evidence.write_text(json.dumps({'schema_version':1,'task_id':'t_repair','id':1,'outcome':'completed'}))
        supervisor.requalify(self.root,'technical-recovery',evidence,'Actual repair verified and interrupted effects reconciled')
        state=json.loads((self.root/'state/fleet/supervisor.json').read_text())
        self.assertFalse(state['handlers']['technical-recovery']['interrupted'])
        self.assertEqual(1,len(list((self.root/'state/fleet/requalifications').glob('*.json'))))
        with self.assertRaises(ValueError):
            supervisor.requalify(self.root,'technical-recovery',evidence,'Unchanged receipt cannot authorize repeated requalification')


unittest.main(argv=[sys.argv[0]])
PY
