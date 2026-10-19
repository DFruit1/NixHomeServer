#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# A fenced worker must not launder its own identity pins. This suite asserts
# environment-gated policy that refuses pinned workers, so instead of clearing
# HERMES_KANBAN_*/DELEGATED in-process it delegates to the approved confined
# executor. That runner keeps the origin pins in a readonly receipt and starts
# the suite with fresh synthetic bindings. Never unset pins here and never retry
# outside the sandbox: the runner fails closed without bubblewrap.
if [[ -n "${HERMES_KANBAN_TASK:-}${HERMES_KANBAN_RUN_ID:-}${HERMES_KANBAN_CLAIM_LOCK:-}${HERMES_DELEGATED_CHILD_CONTEXT:-}" ]]; then
  exec python3 -B "$repo/scripts/hermes/fixture-runner.py" \
    --repo "$repo" --suite "${BASH_SOURCE[0]}"
fi
# Reaching this line with a pin set would mean the routing above did not happen,
# so the assertions below would be made against an unconfined synthetic identity.
for pin in HERMES_KANBAN_TASK HERMES_KANBAN_RUN_ID HERMES_KANBAN_CLAIM_LOCK \
  HERMES_DELEGATED_CHILD_CONTEXT; do
  [[ -z "${!pin:-}" ]] || {
    echo "❌ $pin is set; run this suite through scripts/hermes/fixture-runner.py" >&2
    exit 1
  }
done
task_tmp="$(mktemp -d /tmp/nixhomeserver-hermes-autonomy-test.XXXXXX)"
trap 'rm -rf -- "$task_tmp"' EXIT
python3 -B - "$repo" "$task_tmp" <<'PY'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import sqlite3
import sys
import unittest
import subprocess
import signal
import time
from unittest.mock import patch

source = Path(sys.argv[1]) / 'scripts/hermes/autonomy-policy.py'
if not source.is_file():
    raise SystemExit('RED: missing scripts/hermes/autonomy-policy.py; owner-approved execution is not implemented')
sys.path.insert(0, str(source.parent))
spec = importlib.util.spec_from_file_location('autonomy_policy', source)
policy = importlib.util.module_from_spec(spec)
sys.modules[spec.name] = policy
spec.loader.exec_module(policy)
scratch = Path(sys.argv[2])


class ApprovedExecutionTest(unittest.TestCase):
    def setUp(self):
        self.root = scratch / self.id().split('.')[-1]
        self.root.mkdir()
        self.cwd = self.root / 'work'
        self.cwd.mkdir()
        self.input = self.cwd / 'input.txt'
        self.input.write_text('reviewed input\n')
        # Copy an inert executable so drift tests never modify a shared binary.
        self.executable = self.cwd / 'true'
        shutil.copy2(shutil.which('true'), self.executable)
        self.db_path = self.root / 'kanban/boards/fixture/kanban.db'
        self.db_path.parent.mkdir(parents=True)
        self.db = sqlite3.connect(self.db_path)
        self.addCleanup(self.db.close)
        self.db.executescript('''
            CREATE TABLE tasks(id TEXT PRIMARY KEY, status TEXT);
            CREATE TABLE task_comments(id INTEGER PRIMARY KEY AUTOINCREMENT,
                task_id TEXT, author TEXT, body TEXT, created_at REAL);
            INSERT INTO tasks VALUES('t_fixture', 'blocked');
        ''')
        self.db.commit()
        # A separately pinned fixture board must never be read or modified.
        self.pin = self.root / 'pinned-production-sentinel/kanban.db'
        self.pin.parent.mkdir()
        self.pin.write_bytes(b'NOT A DATABASE: must not be opened')
        # The confined shell prologue owns this process's caller identity:
        # autonomy-policy refuses delegated children and worker pins that do not
        # match the gate, and these cases assert the coordinator/owner path. The
        # laundering cases below set the pin they need explicitly.
        self.environ = patch.dict(os.environ, {'HERMES_KANBAN_DB': str(self.pin)})
        self.environ.start()
        self.addCleanup(self.environ.stop)
        self.addCleanup(self.assert_pin_preserved)

    def assert_pin_preserved(self):
        self.assertEqual(str(self.pin), os.environ['HERMES_KANBAN_DB'])
        self.assertEqual(b'NOT A DATABASE: must not be opened', self.pin.read_bytes())

    def prepare(self, **overrides):
        args = dict(root=self.root, board='fixture', task_id='t_fixture',
                    argv=[str(self.executable)], cwd=self.cwd,
                    effects='Run an inert fixture command; no operational changes.',
                    recovery='No recovery necessary for an inert fixture command.',
                    executor='head-coordinator', timeout=30, inputs=[self.input])
        args.update(overrides)
        return policy.prepare(**args)

    def comment(self, body, author='head-coordinator'):
        if not isinstance(body, str):
            body = json.dumps(body)
        self.db.execute('INSERT INTO task_comments(task_id,author,body,created_at) VALUES(?,?,?,?)',
                        ('t_fixture', author, body, self.db.execute(
                            'SELECT COUNT(*) + 100 FROM task_comments').fetchone()[0]))
        self.db.commit()

    def approve(self, manifest, **overrides):
        decision = dict(request_sha256=manifest['sha256'], approved=True,
                        executor='head-coordinator',
                        owner_reply='D1 approve ' + manifest['sha256'])
        decision.update(overrides)
        self.comment({'owner_execution_decision': decision})

    def test_prepare_persists_exact_reviewable_manifest(self):
        before = self.db_path.read_bytes()
        manifest = self.prepare()
        digest = manifest['sha256']
        self.assertRegex(digest, r'^[0-9a-f]{64}$')
        path = self.root / 'kanban/approved-operations' / digest / 'request.json'
        self.assertEqual(manifest, json.loads(path.read_text()))
        self.assertEqual(socket.gethostname(), manifest['hostname'])
        self.assertEqual([str(self.executable)], manifest['argv'])
        self.assertEqual(str(self.cwd), manifest['cwd'])
        self.assertEqual('head-coordinator', manifest['executor'])
        self.assertEqual(30, manifest['timeout'])
        self.assertEqual(hashlib.sha256(self.executable.read_bytes()).hexdigest(),
                         manifest['executable']['sha256'])
        self.assertEqual(str(self.input), manifest['inputs'][0]['path'])
        self.assertEqual(hashlib.sha256(self.input.read_bytes()).hexdigest(),
                         manifest['inputs'][0]['sha256'])
        self.assertTrue(manifest['effects'])
        self.assertTrue(manifest['recovery'])
        self.assertEqual(before, self.db_path.read_bytes())

    def test_prepare_rejects_invalid_requests_without_writing_outside_root(self):
        for overrides in ({'board': '../escape'}, {'board': ''},
                          {'task_id': '../escape'}, {'task_id': ''},
                          {'argv': []}, {'argv': ['']},
                          {'argv': ['/missing/autonomy-test-executable']},
                          {'cwd': self.root / 'missing'},
                          {'inputs': [self.root / 'missing']},
                          {'timeout': 0}, {'timeout': -1}, {'timeout': 1000000000}):
            with self.subTest(overrides=overrides), self.assertRaises((ValueError, OSError)):
                self.prepare(**overrides)
        self.assertFalse((self.root.parent / 'escape').exists())

    def test_check_requires_approval_and_never_writes_board(self):
        manifest = self.prepare()
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')
        self.approve(manifest)
        before = self.db_path.read_bytes()
        self.assertEqual(manifest, policy.check(self.root, manifest['sha256'], profile='head-coordinator'))
        self.assertEqual(before, self.db_path.read_bytes())

    def test_only_coordinator_decisions_with_exact_owner_reply_authorize(self):
        manifest = self.prepare()
        decision = dict(request_sha256=manifest['sha256'], approved=True,
                        executor='head-coordinator', owner_reply='D1 approve ' + manifest['sha256'])
        self.comment({'owner_execution_decision': decision}, author='standard-implementer')
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')
        for changes in ({'approved': False}, {'approved': 'true'},
                        {'owner_reply': 'D1 approve a different command'},
                        {'executor': 'standard-implementer'}):
            with self.subTest(changes=changes):
                self.approve(manifest, **changes)
                with self.assertRaises(ValueError):
                    policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_later_deny_or_superseding_decision_revokes_old_approval(self):
        manifest = self.prepare()
        self.approve(manifest)
        self.approve(manifest, approved=False, owner_reply='D1 deny ' + manifest['sha256'])
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')
        self.approve(manifest)
        self.approve(manifest, request_sha256='a' * 64, owner_reply='D1 approve ' + 'a' * 64)
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_later_owner_comment_requires_reconciliation(self):
        manifest = self.prepare()
        self.approve(manifest)
        self.comment('Stop; I need to change the target.', author='user')
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_malformed_later_decision_fails_closed(self):
        manifest = self.prepare()
        for malformed in ('{"owner_execution_decision":',
                          {'owner_execution_decision': None},
                          {'owner_execution_decision': {'approved': True}}):
            with self.subTest(malformed=malformed):
                self.approve(manifest)
                self.comment(malformed)
                with self.assertRaises(ValueError):
                    policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_changed_declared_input_invalidates_approval(self):
        manifest = self.prepare()
        self.approve(manifest)
        # Real content must always invalidate.
        with self.subTest('content change'):
            self.input.write_text('changed after owner review\n')
            with self.assertRaises(ValueError):
                policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_prepare_and_check_tolerate_first_read_atime_bump(self):
        # On relatime mounts (the confined fixture uses one), the first read of
        # a freshly created input bumps st_atime. prepare() hashes that input
        # immediately, so this is the exact sequence that previously failed with
        # 'Input changed while hashing' when stat comparison included atime:
        # fresh input without any prior read, hashed twice in one process.
        self.prepare()  # hashes self.input and the fresh executable copy
        self.prepare()  # re-hashes the same, never-mutated, now-atime-bumped files

    def test_metadata_generation_change_invalidates_while_hashing(self):
        # st_ctime moves on chmod/chown/link changes even when the bytes are
        # identical, so a metadata-only rewrite between the before/after stat is
        # real contamination of the reviewed input. Restoring atime and mtime to
        # their pre-mutation values leaves ctime as the only field that differs,
        # which makes this fail again if the drift comparison drops ctime.
        original = self.input.stat()
        real_open = Path.open
        mutated = []

        def mutating_open(path, *args, **kwargs):
            stream = real_open(path, *args, **kwargs)
            if not mutated and path == self.input:
                mutated.append(True)
                os.utime(path, ns=(original.st_atime_ns, original.st_mtime_ns))
            return stream

        with patch.object(Path, 'open', mutating_open):
            with self.assertRaisesRegex(ValueError, 'Input changed while hashing'):
                self.prepare()
        self.assertTrue(mutated)
        self.assertEqual(original.st_mtime_ns, self.input.stat().st_mtime_ns)

    def test_changed_executable_invalidates_approval(self):
        manifest = self.prepare()
        self.approve(manifest)
        self.executable.write_bytes(self.executable.read_bytes() + b'changed')
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_missing_working_directory_invalidates_approval(self):
        manifest = self.prepare(argv=[sys.executable, '-c', 'pass'], inputs=[])
        self.approve(manifest)
        self.executable.unlink()
        self.input.unlink()
        self.cwd.rmdir()
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_different_hostname_invalidates_approval(self):
        manifest = self.prepare()
        self.approve(manifest)
        with patch('socket.gethostname', return_value='different-fixture-host'):
            with self.assertRaises(ValueError):
                policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_wrong_executor_and_terminal_gate_reject_execution(self):
        manifest = self.prepare()
        self.approve(manifest)
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='standard-implementer')
        for status in ('done', 'archived'):
            self.db.execute('UPDATE tasks SET status=?', (status,))
            self.db.commit()
            with self.subTest(status=status), self.assertRaises(ValueError):
                policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_manifest_tampering_is_detected(self):
        manifest = self.prepare()
        self.approve(manifest)
        path = self.root / 'kanban/approved-operations' / manifest['sha256'] / 'request.json'
        changed = dict(manifest, argv=[str(self.executable), 'unreviewed argument'])
        path.write_text(json.dumps(changed))
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')

    def test_execute_records_output_preserves_pin_and_cannot_run_twice(self):
        sentinel = self.cwd / 'launched'
        script = ('import os, pathlib, sys; '
                  'assert pathlib.Path(sys.argv[2]).resolve().is_file(), "missing durable running marker"; '
                  'pathlib.Path(sys.argv[1]).write_text(os.environ["HERMES_KANBAN_DB"]); '
                  'print("fixture stdout"); print("fixture stderr", file=sys.stderr); sys.exit(7)')
        # The command can inspect its own operation directory without embedding
        # the content-addressed digest inside the command being hashed.
        marker = self.cwd / 'expected-running-marker'
        manifest = self.prepare(argv=[sys.executable, '-c', script, str(sentinel), str(marker)])
        operation = self.root / 'kanban/approved-operations' / manifest['sha256']
        marker.symlink_to(operation / 'running.json')
        self.approve(manifest)
        before = self.db_path.read_bytes()
        receipt = policy.execute(self.root, manifest['sha256'], profile='head-coordinator')
        self.assertEqual(7, receipt['exit_code'])
        self.assertIn('fixture stdout', receipt['stdout'])
        self.assertIn('fixture stderr', receipt['stderr'])
        self.assertEqual(receipt, json.loads((operation / 'receipt.json').read_text()))
        self.assertEqual(str(self.pin), sentinel.read_text())
        self.assertEqual(before, self.db_path.read_bytes())
        sentinel.write_text('must not run again')
        with self.assertRaises(ValueError):
            policy.execute(self.root, manifest['sha256'], profile='head-coordinator')
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')
        self.assertEqual('must not run again', sentinel.read_text())

    def test_crashed_started_operation_is_never_reexecuted(self):
        manifest = self.prepare()
        self.approve(manifest)
        operation = self.root / 'kanban/approved-operations' / manifest['sha256']
        (operation / 'running.json').write_text('{"status":"running"}\n')
        with self.assertRaises(ValueError):
            policy.check(self.root, manifest['sha256'], profile='head-coordinator')
        with self.assertRaises(ValueError):
            policy.execute(self.root, manifest['sha256'], profile='head-coordinator')

    def test_pinned_worker_context_cannot_be_laundered_into_owner_execution(self):
        manifest = self.prepare()
        self.approve(manifest)
        with patch.dict(os.environ, {'HERMES_KANBAN_TASK': 't_pinned_worker'}):
            with self.assertRaises(ValueError):
                policy.execute(self.root, manifest['sha256'], profile='head-coordinator')
            self.assertEqual('t_pinned_worker', os.environ['HERMES_KANBAN_TASK'])

    def test_delegated_context_cannot_be_laundered_into_owner_execution(self):
        manifest = self.prepare()
        self.approve(manifest)
        marker = '{"parent_task_id":"t_fixture_parent"}'
        with patch.dict(os.environ, {'HERMES_DELEGATED_CHILD_CONTEXT': marker}):
            with self.assertRaises(ValueError):
                policy.execute(self.root, manifest['sha256'], profile='head-coordinator')
            self.assertEqual(marker, os.environ['HERMES_DELEGATED_CHILD_CONTEXT'])

    def test_capture_is_bounded_and_timeout_still_has_a_terminal_receipt(self):
        manifest = self.prepare(argv=[sys.executable, '-c',
                                'import os; os.write(1,b"x"*8000000)'])
        self.approve(manifest)
        receipt = policy.execute(self.root, manifest['sha256'], profile='head-coordinator')
        self.assertEqual('output_limit', receipt['status'])
        operation = self.root / 'kanban/approved-operations' / manifest['sha256']
        self.assertLessEqual((operation / 'stdout.txt').stat().st_size, policy.CAPTURE_LIMIT)
        self.assertLessEqual(len(receipt['stdout']), 65536)
        timeout = self.prepare(argv=[sys.executable, '-c', 'import time; time.sleep(3)'],timeout=1)
        self.approve(timeout)
        self.assertEqual('timed_out', policy.execute(self.root,timeout['sha256'],profile='head-coordinator')['status'])

    def test_controlled_environment_cannot_drift_targets_or_inherit_credentials(self):
        manifest = self.prepare(argv=[sys.executable,'-c',
            'import os; print(os.environ.get("PGHOST")); print("FAKE_API_KEY" in os.environ)'],
            environment={'PGHOST':'reviewed-fixture-target'})
        self.approve(manifest)
        with patch.dict(os.environ,{'PGHOST':'different-target','FAKE_API_KEY':'synthetic-fixture'}):
            receipt=policy.execute(self.root,manifest['sha256'],profile='head-coordinator')
        self.assertEqual('reviewed-fixture-target\nFalse\n',receipt['stdout'])
        with self.assertRaises(ValueError):self.prepare(environment={'BASH_ENV':'unreviewed-loader'})

    def test_timeout_finishes_even_when_detached_child_retains_output_pipes(self):
        pidfile=self.cwd/'detached.pid'
        script=('import subprocess,sys,time; from pathlib import Path; '
                'child=subprocess.Popen([sys.executable,"-c","import time;time.sleep(60)"],start_new_session=True); '
                'Path(sys.argv[1]).write_text(str(child.pid)); time.sleep(60)')
        manifest=self.prepare(argv=[sys.executable,'-c',script,str(pidfile)],timeout=1)
        self.approve(manifest)
        started=time.monotonic()
        try:
            result=subprocess.run([sys.executable,'-B',str(source),'execute',manifest['sha256']],
                env={**os.environ,'HERMES_ROOT':str(self.root),'HERMES_PROFILE_NAME':'head-coordinator'},
                capture_output=True,text=True,timeout=4)
            self.assertLess(time.monotonic()-started,3.5)
            self.assertNotEqual(0,result.returncode)
            self.assertEqual('timed_out',json.loads(result.stdout)['status'])
        finally:
            if pidfile.exists():
                try:os.kill(int(pidfile.read_text()),signal.SIGKILL)
                except ProcessLookupError:pass

    def test_default_board_and_native_profile_name_are_supported(self):
        shutil.copy2(self.db_path,self.root/'kanban.db')
        manifest=self.prepare(board='default')
        self.assertEqual('default',manifest['board'])
        with patch.dict(os.environ,{'HERMES_PROFILE':'standard-implementer',
                                   'HERMES_PROFILE_NAME':'head-coordinator'}):
            self.assertEqual('head-coordinator',policy._profile())

    def test_cli_failure_exit_does_not_report_a_successful_operation(self):
        manifest=self.prepare(argv=[sys.executable,'-c','raise SystemExit(7)'])
        self.approve(manifest)
        result=subprocess.run([sys.executable,'-B',str(source),'execute',manifest['sha256']],
            env={**os.environ,'HERMES_ROOT':str(self.root),'HERMES_PROFILE_NAME':'head-coordinator'},
            capture_output=True,text=True)
        self.assertEqual(7,result.returncode,result.stderr)
        self.assertEqual('failed',json.loads(result.stdout)['status'])


unittest.main(argv=[sys.argv[0]], verbosity=2)
PY
