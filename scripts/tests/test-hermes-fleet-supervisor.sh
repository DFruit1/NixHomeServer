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
import deadlock_recovery as recovery


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

    def test_token_hold_blocks_optional_intake_but_preserves_recovery(self):
        directory=self.root/'state/agent-usage';directory.mkdir(parents=True)
        path=directory/'guard.json'
        path.write_text(json.dumps({'generated_at':100000,'hold_intake':True}))
        supervisor.tick(self.root,now=100000,runner=self.runner)
        self.assertFalse(any('review-taskforce-tick.sh' in str(c) for c in self.calls))
        self.assertTrue(any('deadlock_recovery.py' in str(c) for c in self.calls))
        self.calls.clear()
        path.write_text(json.dumps({'generated_at':100301,'hold_intake':False}))
        supervisor.tick(self.root,now=100301,runner=self.runner)
        self.assertTrue(any('review-taskforce-tick.sh' in str(c) for c in self.calls))

    def test_fresh_guard_created_during_tick_uses_actual_decision_time(self):
        def run(command,**kwargs):
            if command[-1].endswith('agent_usage_guard.py'):
                directory=self.root/'state/agent-usage';directory.mkdir(parents=True)
                (directory/'guard.json').write_text(json.dumps({'generated_at':100010,'hold_intake':False}))
            return self.runner(command,**kwargs)
        supervisor.tick(self.root,now=100000,runner=run,clock=lambda:100020)
        self.assertTrue(any('review-taskforce-tick.sh' in str(c) for c in self.calls))

    def test_usage_alert_wakes_coordinator_with_stable_incident_and_runbook(self):
        import sqlite3
        db=self.root/'kanban/boards/test/kanban.db'
        with sqlite3.connect(db) as con:
            con.execute('CREATE TABLE tasks(id TEXT,status TEXT,created_by TEXT)')
        line='TOKEN_GUARD token_spike:example incident=123 hold=proactive-intake'
        with patch.object(supervisor.subprocess,'run') as run:
            supervisor.wake_coordinator(self.root,'test','usage-guard',line)
        self.assertEqual(1,run.call_count)
        command=run.call_args.args[0]
        self.assertIn('TOKEN_GUARD',command[command.index('--body')+1])
        self.assertIn('langfuse.md#token-guards-and-alerts',command[command.index('--body')+1])
        self.assertIn('usage-guard:test:',command[command.index('--idempotency-key')+1])

    def test_token_alert_attaches_once_to_existing_recovery_instead_of_being_lost(self):
        import sqlite3
        path=self.root/'kanban/boards/test/kanban.db'
        with sqlite3.connect(path) as db:
            db.executescript('CREATE TABLE tasks(id TEXT,status TEXT,created_by TEXT);'
                             'CREATE TABLE task_comments(task_id TEXT,author TEXT,body TEXT);')
            db.execute('INSERT INTO tasks VALUES (?,?,?)',('t_owner','running','deadlock-recovery-monitor'))
        def native(command,**kwargs):
            self.assertIn('comment',command)
            at=command.index('comment')
            with sqlite3.connect(path) as db:
                db.execute('INSERT INTO task_comments VALUES (?,?,?)',(command[at+1],'fleet-supervisor',command[at+2]))
        line='TOKEN_GUARD coverage:codex incident=123 hold=proactive-intake'
        with patch.object(supervisor.subprocess,'run',side_effect=native) as run:
            supervisor.wake_coordinator(self.root,'test','usage-guard',line)
            supervisor.wake_coordinator(self.root,'test','usage-guard',line)
        self.assertEqual(1,run.call_count)

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


class OutcomeCadenceTest(unittest.TestCase):
    def test_installed_analytics_refreshes_once_per_day_before_board_reads(self):
        with tempfile.TemporaryDirectory(prefix='fleet-outcomes-') as directory:
            root=Path(directory)
            (root/'scripts').mkdir()
            (root/'scripts/kanban-analytics.py').write_text(
                'from contextlib import contextmanager\n'
                '@contextmanager\n'
                'def readonly(path):\n'
                '    yield str(path)\n'
                'def maintenance_outcomes(db,since,until):\n'
                '    return {"fixture_db":db,"since":since,"until":until}\n')
            first=supervisor.outcome_report(root,['test'],100000)
            self.assertEqual(100000,first['boards']['test']['until'])
            state=root/'state/fleet/report.json'
            state.parent.mkdir(parents=True)
            state.write_text(json.dumps({'outcomes':first}))
            (root/'scripts/kanban-analytics.py').unlink()
            self.assertEqual(first,supervisor.outcome_report(root,['test'],100001))
            self.assertEqual('unavailable',supervisor.outcome_report(root,['test'],186400)['status'])


class RecoveryWorkspaceTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix='recovery-workspace-')
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.work = self.root / 'work'
        self.work.mkdir()
        self.calls = []
        self.observed = []

    def board(self, name, metadata):
        directory = self.root / 'kanban/boards' / name
        directory.mkdir(parents=True, exist_ok=True)
        (directory / 'board.json').write_text(json.dumps(metadata))

    def observe(self, root, board, now):
        self.observed.append(board)
        return [dict(key=board+':t_broken:technical-hold', version='fixture',
                     task_id='t_broken', kind='technical-hold', priority=0)]

    def create(self, board, *args):
        self.calls.append((board, args))
        return {'id': 't_recovery_'+board}

    def test_unconfigured_boards_do_not_starve_configured_board_or_spend_attempts(self):
        invalid = [None, {}, {'default_workdir': None}, {'default_workdir': ''},
                   {'default_workdir': 17}, {'default_workdir': []},
                   {'default_workdir': 'relative'},
                   {'default_workdir': str(self.root/'missing')},
                   {'default_workdir': 'bad\x00path'}]
        regular = self.root/'regular-file'
        regular.write_text('not a workspace')
        invalid.append({'default_workdir': str(regular)})
        for index, metadata in enumerate(invalid):
            self.board('a_invalid_'+str(index), metadata)
        self.board('z_configured', {'default_workdir': str(self.work)})
        with patch.object(recovery, 'observe', side_effect=self.observe):
            actions = recovery.tick(self.root, now=100000, create=self.create)
        self.assertEqual(['z_configured'], self.observed)
        self.assertEqual(['z_configured'], [c[0] for c in self.calls])
        self.assertIn('dir:'+str(self.work), self.calls[0][1])
        skipped = [a for a in actions if a.get('status') == 'ineligible']
        self.assertEqual(len(invalid), len(skipped))
        self.assertTrue(all('workspace' in a['reason'] for a in skipped))
        state = json.loads((self.root/'runtime/deadlock-intake/state.json').read_text())
        self.assertEqual({'z_configured:t_broken:technical-hold', '_fairness'}, set(state))
        self.assertEqual(1, state['z_configured:t_broken:technical-hold']['versions']['fixture']['attempts'])

    def test_preview_uses_same_eligibility_and_remains_read_only(self):
        self.board('invalid', {'default_workdir': None})
        self.board('valid', {'default_workdir': str(self.work)})
        with patch.object(recovery, 'observe', side_effect=self.observe):
            actions = recovery.tick(self.root, now=100000, dry_run=True, create=self.create)
        self.assertEqual(['valid'], self.observed)
        self.assertEqual([], self.calls)
        self.assertEqual(['invalid', 'valid'], [a['board'] for a in actions])
        self.assertEqual('ineligible', actions[0]['status'])
        self.assertFalse((self.root/'runtime').exists())

    def test_malformed_metadata_is_visible_and_can_be_repaired(self):
        self.board('repairable', {})
        info = self.root/'kanban/boards/repairable/board.json'
        info.write_text('{')
        with patch.object(recovery, 'observe', side_effect=self.observe):
            result = recovery.tick(self.root, now=100000, create=self.create)
            self.assertEqual('ineligible', result[0]['status'])
            self.assertEqual([], self.calls)
            self.board('repairable', {'default_workdir': str(self.work)})
            result = recovery.tick(self.root, now=100001, create=self.create)
        self.assertEqual('repairable', result[0]['board'])
        self.assertEqual(1, len(self.calls))

    def test_configured_board_observation_errors_still_fail(self):
        self.board('configured', {'default_workdir': str(self.work)})
        with patch.object(recovery, 'observe', side_effect=RuntimeError('unreadable native state')):
            with self.assertRaisesRegex(RuntimeError, 'unreadable native state'):
                recovery.tick(self.root, now=100000, create=self.create)
        self.assertEqual([], self.calls)


unittest.main(argv=[sys.argv[0]])
PY
