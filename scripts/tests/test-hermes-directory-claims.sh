#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
from types import SimpleNamespace
import unittest
from unittest.mock import patch

source = Path(sys.argv[1]) / 'scripts/hermes'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('directory_claims', source / 'directory_claims.py')
claims = importlib.util.module_from_spec(spec)
spec.loader.exec_module(claims)


class DirectoryClaimsTest(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory(prefix='hermes-directory-claims-')
        self.addCleanup(self.scratch.cleanup)
        self.root = Path(self.scratch.name) / 'repo'
        self.root.mkdir()
        for name in ('modules/photos/frontend', 'modules/photos/backend', 'modules/books'):
            directory = self.root / name
            directory.mkdir(parents=True)
            (directory / 'source.txt').write_text('original\n')
        (self.root / 'configuration.nix').write_text('original\n')
        self.git('init', '-q')
        self.git('add', '.')
        self.git('-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid',
                 'commit', '-qm', 'fixture')
        self.project = claims.Project(self.root)

    def git(self, *args):
        return subprocess.check_output(['git', '-C', str(self.root), *args], text=True).strip()

    def test_disjoint_directories_can_have_four_writers(self):
        for owner, scope in [('one', 'modules/photos/frontend'), ('two', 'modules/photos/backend'),
                             ('three', 'modules/books'), ('four', 'scripts/feature')]:
            worktree = Path(self.scratch.name) / owner
            self.git('worktree', 'add', '-q', '--detach', str(worktree))
            claims.Project(worktree).claim(owner, [scope])
        self.assertEqual(4, len(self.project.status()['claims']))
        self.assertTrue((self.project.directory / 'state.json').is_file())

    @unittest.skipUnless(shutil.which('bwrap'), 'bubblewrap integration requires Linux user namespaces')
    def test_four_writers_can_execute_at_the_same_time(self):
        workers = []
        try:
            for number in range(4):
                worktree = Path(self.scratch.name) / ('parallel-' + str(number))
                self.git('worktree', 'add', '-q', '--detach', str(worktree))
                scope = 'features/writer-' + str(number)
                claims.Project(worktree).claim(str(number), [scope])
                script = ('from pathlib import Path; import sys; print("ready", flush=True); '
                          'sys.stdin.readline(); Path(' + repr(scope + '/source.txt') + ').write_text("owned")')
                worker = subprocess.Popen([sys.executable, '-B', str(source / 'directory_claims.py'),
                    '--repo', str(worktree), '--owner', str(number), 'run', '--cwd', str(worktree),
                    '--', sys.executable, '-c', script], stdin=subprocess.PIPE,
                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
                workers.append(worker)
            for worker in workers:
                self.assertEqual('ready\n', worker.stdout.readline())
            for worker in workers:
                worker.stdin.write('continue\n')
                worker.stdin.flush()
            for worker in workers:
                worker.communicate(timeout=10)
                self.assertEqual(0, worker.returncode)
        finally:
            for worker in workers:
                if worker.poll() is None:
                    worker.terminate()
                    worker.communicate(timeout=5)

    def test_overlap_and_partial_multi_claim_acquisition_are_refused(self):
        self.project.claim('one', ['modules/photos/frontend'])
        for paths in (['modules/photos'], ['modules/photos/frontend'],
                      ['modules/books', 'modules/photos/frontend/subdir']):
            with self.assertRaises(ValueError):
                self.project.claim('two', paths)
        self.assertEqual(['one'], [c['owner'] for c in self.project.status()['claims']])

    def test_shared_git_worktrees_have_the_same_ownership(self):
        worktree = Path(self.scratch.name) / 'other'
        self.git('worktree', 'add', '-q', '--detach', str(worktree))
        other = claims.Project(worktree)
        self.assertEqual(self.project.directory, other.directory)
        self.project.claim('one', ['modules/books'])
        with self.assertRaises(ValueError):
            other.claim('two', ['modules/books'])
        with self.assertRaises(ValueError):
            other.claim('one', ['modules/books'])

    def test_broad_unsafe_and_alias_claims_are_refused(self):
        (self.root / 'modules/alias').symlink_to(self.root / 'modules/books', target_is_directory=True)
        for path in ('.', 'modules', 'custom_apps', '../outside', '/tmp', '.git/objects',
                     'modules/alias', 'modules/books/source.txt', 'modules/../modules/books'):
            with self.subTest(path=path), self.assertRaises(ValueError):
                self.project.claim('one', [path])

    def test_requests_are_filesystem_records_and_never_transfer_ownership(self):
        self.project.claim('one', ['modules/books'])
        request = self.project.request('two', ['modules/books'], 'Please update the shared option.')
        status = self.project.status()
        self.assertEqual('one', status['claims'][0]['owner'])
        self.assertEqual('two', status['requests'][0]['requester'])
        self.assertEqual(status['claims'][0]['generation'], request['holders'][0])
        with self.assertRaises(ValueError):
            self.project.release('two')
        self.project.release('one')
        self.project.claim('two', ['modules/books'])
        self.assertEqual('two', self.project.status()['claims'][0]['owner'])

    def test_live_operations_prevent_release_and_unowned_writes(self):
        self.project.claim('one', ['modules/books'])
        with self.project.writing('one', [self.root / 'modules/books/source.txt']):
            with self.assertRaises(ValueError):
                self.project.release('one')
        for path in ('modules/photos/frontend/source.txt', 'configuration.nix'):
            with self.assertRaises(ValueError):
                with self.project.writing('one', [self.root / path]):
                    self.fail('Unowned write was permitted')
        self.project.release('one')

    def test_release_preserves_uncommitted_owned_changes(self):
        self.project.claim('one', ['modules/books'])
        path = self.root / 'modules/books/source.txt'
        path.write_text('unfinished\n')
        with self.assertRaisesRegex(ValueError, 'Commit owned source'):
            self.project.release('one')
        self.assertEqual('unfinished\n', path.read_text())
        self.assertEqual('one', self.project.status()['claims'][0]['owner'])

    def test_scoped_release_preserves_dirty_work_and_other_holder_requests(self):
        # A real dependency handoff deadlocked when dirty backend work and a
        # clean imported engine shared a claim. Preserve both custody boundaries.
        original = self.project.claim('one', ['modules/books', 'modules/photos/frontend'])
        path = self.root / 'modules/books/source.txt'
        path.write_text('unfinished\n')
        self.project.request('two', ['modules/photos/frontend'], 'Dependency handoff')
        self.project.request('three', ['modules/books'], 'Later handoff')
        other_tree = Path(self.scratch.name) / 'other-holder'
        self.git('worktree', 'add', '-q', '--detach', str(other_tree))
        other = claims.Project(other_tree).claim('other', ['modules/photos/backend'])
        self.project.request('four', ['modules/photos'], 'Parent waits for all children')
        receipt = self.project.release('one', ['modules/photos/frontend'])
        self.assertEqual(['modules/books'], receipt['remainingPaths'])
        status = self.project.status()
        self.assertEqual(['modules/books'], status['claims'][0]['paths'])
        self.assertEqual(original['generation'], status['claims'][0]['generation'])
        self.assertEqual(['three', 'four'], [r['requester'] for r in status['requests']])
        self.assertEqual([other['generation']], status['requests'][1]['holders'])
        self.assertEqual('unfinished\n', path.read_text())
        worktree = Path(self.scratch.name) / 'consumer'
        self.git('worktree', 'add', '-q', '--detach', str(worktree))
        claims.Project(worktree).claim('two', ['modules/photos/frontend'])
        with self.assertRaises(ValueError):
            claims.Project(worktree).claim('two', ['modules/books'])

    def test_scoped_release_rejects_dirty_or_unheld_scopes_atomically(self):
        self.project.claim('one', ['modules/books', 'modules/photos/frontend'])
        (self.root / 'modules/books/source.txt').write_text('unfinished\n')
        before = self.project.status()
        for paths in (['modules/books'], ['modules/photos'],
                      ['modules/photos/frontend', 'modules/books'],
                      ['modules/books/nested']):
            with self.subTest(paths=paths), self.assertRaises(ValueError):
                self.project.release('one', paths)
            self.assertEqual(before, self.project.status())
        with self.project.writing('one', [self.root / 'modules/books/source.txt']):
            with self.assertRaises(ValueError):
                self.project.release('one', ['modules/photos/frontend'])
        self.assertEqual(before, self.project.status())

    def test_recovery_requires_stopped_writer_and_preserves_unfinished_checkout(self):
        worker = subprocess.Popen([sys.executable, '-c', 'import time; time.sleep(20)'])
        try:
            claim = self.project.claim('one', ['modules/books'], writer_pid=worker.pid)
            with self.assertRaisesRegex(ValueError, 'still alive'):
                self.project.recover('two', claim['generation'])
        finally:
            worker.terminate()
            worker.wait(timeout=5)
        path = self.root / 'modules/books/source.txt'
        path.write_text('unfinished\n')
        receipt = self.project.recover('two', claim['generation'])
        self.assertIn('modules/books/source.txt', receipt['preserved_changes'])
        self.assertEqual('unfinished\n', path.read_text())
        self.assertEqual([], self.project.status()['claims'])

    def test_corrupt_state_fails_closed_and_old_claims_never_expire(self):
        self.project.claim('one', ['modules/books'])
        path = self.project.directory / 'state.json'
        state = json.loads(path.read_text())
        state['claims'][0]['created_at'] = 1
        path.write_text(json.dumps(state))
        with self.assertRaises(ValueError):
            self.project.claim('two', ['modules/books'])
        path.write_text('{}')
        with self.assertRaises(ValueError):
            self.project.claim('two', ['modules/books'])

    def test_racing_processes_have_one_winner(self):
        command = [sys.executable, '-B', str(source / 'directory_claims.py'),
                   '--repo', str(self.root)]
        workers = [subprocess.Popen(command + ['--owner', str(i), 'claim', 'modules/books'],
                   stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) for i in range(4)]
        for worker in workers:
            worker.communicate(timeout=10)
        self.assertEqual(1, sum(w.returncode == 0 for w in workers))

    def test_native_writes_refuse_aliases_and_ownership_is_held_through_the_write(self):
        self.project.claim('one', ['modules/books'])
        alias = self.root / 'modules/books/link'
        alias.symlink_to(self.root / 'modules/photos/frontend/source.txt')
        hardlink = self.root / 'modules/books/hardlink'
        os.link(self.root / 'modules/photos/frontend/source.txt', hardlink)
        for path in (alias, hardlink):
            with self.assertRaises(ValueError):
                with self.project.writing('one', [path]):
                    self.fail('Aliases cannot cross claim boundaries')

    def test_runtime_binds_ownership_to_session_and_keeps_scope_after_cd(self):
        import directory_claims_runtime as runtime
        runtime.BOUND.clear()
        command = runtime.terminal_command('echo inspect', cwd=self.root,
                     workdir='/tmp', task_id='worker', session_id='session', profile='fixture')
        self.assertIn('fixture:session', command)
        self.assertIn('run', command)
        again = runtime.terminal_command('echo inspect', cwd='/tmp',
                     task_id='worker', session_id='session', profile='fixture')
        self.assertIn(str(self.root), again)
        management = runtime.terminal_command(
            f'python3 {source / "directory_claims.py"} claim modules/books', cwd=self.root,
            task_id='worker', session_id='session', profile='fixture')
        self.assertIn('--owner fixture:session claim modules/books', management)
        injection = runtime.terminal_command(
            f'python3 {source / "directory_claims.py"} list; touch forbidden', cwd=self.root,
            task_id='worker', session_id='session', profile='fixture')
        self.assertIn(' run ', injection)

    def test_plain_directory_workspaces_use_filesystem_claims_without_git(self):
        import directory_claims_runtime as runtime
        runtime.BOUND.clear()
        directory = Path(self.scratch.name) / 'plain'
        (directory / 'features/one').mkdir(parents=True)
        project = claims.Project(directory)
        self.assertFalse(project.is_git)
        project.claim('one', ['features/one'])
        with project.writing('one', [directory / 'features/one/file.txt']):
            (directory / 'features/one/file.txt').write_text('preserved')
        project.release('one')
        command = runtime.terminal_command('pwd', cwd=directory,
                     task_id='plain', session_id='plain-session', profile='fixture')
        self.assertIn(' run ', command)
        self.assertTrue((directory / '.directory-claims/state.json').is_file())

    def test_native_adapter_holds_ownership_for_actual_write_and_patch(self):
        import directory_claims_adapter
        import directory_claims_runtime as runtime
        runtime.BOUND.clear()
        self.project.claim('fixture:session', ['modules/books'])
        tools = SimpleNamespace(_resolve_or_none=lambda p, tid, **kw: str(Path(p).absolute()))
        terminal = SimpleNamespace(_get_env_config=lambda: {'env_type': 'local', 'cwd': str(self.root)},
                                   resolve_task_overrides=lambda tid: {})
        profiles = SimpleNamespace(get_active_profile_name=lambda: 'fixture')
        with patch.dict(sys.modules, {'tools.file_tools': tools, 'tools.terminal_tool': terminal,
                'hermes_cli.profiles': profiles}):
            for path in (self.root / 'modules/photos/frontend/source.txt', self.root / 'configuration.nix'):
                with self.assertRaises(ValueError):
                    with runtime.file_write([str(path)], task_id='worker', session_id='session'):
                        path.write_text('wrong')
            path = self.root / 'modules/books/source.txt'
            with runtime.file_write([str(path)], task_id='worker', session_id='session'):
                path.write_text('owned')
                with self.assertRaises(ValueError):
                    self.project.release('fixture:session')
        self.assertEqual('owned', path.read_text())
        for name in ('file_tools.py', 'terminal_tool.py'):
            original = (Path.home() / '.hermes/hermes-agent/tools' / name)
            if original.exists():
                adapted = directory_claims_adapter.adapt(name, original.read_text())
                self.assertEqual(adapted, directory_claims_adapter.adapt(name, adapted))

    def test_installer_is_atomic_on_source_drift_and_converges(self):
        spec = importlib.util.spec_from_file_location('claim_installer', source / 'install-directory-claims.py')
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        home = Path(self.scratch.name) / 'hermes'
        home.mkdir()
        (home / 'SOUL.md').write_text('Preserve operator notes.\n')
        tools = home / 'hermes-agent/tools'
        tools.mkdir(parents=True)
        (tools / 'file_tools.py').write_text('native source drift\n')
        with self.assertRaises(ValueError):
            installer.install(home)
        self.assertEqual('Preserve operator notes.\n', (home / 'SOUL.md').read_text())
        self.assertFalse((home / 'scripts').exists())
        (tools / 'file_tools.py').write_text(
            'from contextlib import ExitStack\n'
            'def write(path, task_id, session_id):\n'
            '    if True:\n        with ExitStack() as _lock:\n            pass\n'
            'def patch(_paths_to_check, task_id, session_id):\n'
            '    if True:\n        with ExitStack() as _locks:\n            pass\n')
        (tools / 'terminal_tool.py').write_text(
            'def terminal(command, cwd, workdir, task_id, session_id, env_type, plan, force):\n'
            '    if True:\n'
            '        verdict = _run_approval_guards(command, env_type, plan.config, force=force)\n')
        self.assertEqual(1, installer.install(home, check=True))
        self.assertEqual(0, installer.install(home))
        self.assertEqual(0, installer.install(home, check=True))
        self.assertIn('Preserve operator notes.', (home / 'SOUL.md').read_text())
        release = home / 'state/fleet/current.json'
        release.parent.mkdir(parents=True)
        release.write_text(json.dumps({'status': 'active', 'revision': 'fixture'}))
        (home / 'scripts/directory_claims.py').write_text('old helper\n')
        with self.assertRaisesRegex(ValueError, 'fleet-release.py'):
            installer.install(home)
        self.assertEqual('old helper\n', (home / 'scripts/directory_claims.py').read_text())

    @unittest.skipUnless(shutil.which('bwrap'), 'bubblewrap integration requires Linux user namespaces')
    def test_shell_and_generators_can_only_write_owned_source(self):
        self.project.claim('one', ['modules/books'])
        command = [sys.executable, '-B', str(source / 'directory_claims.py'),
                   '--repo', str(self.root), '--owner', 'one', 'run', '--cwd', '/tmp', '--']
        owned = self.root / 'modules/books/source.txt'
        unowned = self.root / 'modules/photos/frontend/source.txt'
        def run(script):
            return subprocess.run(command + [sys.executable, '-c', script],
                                  capture_output=True, text=True)
        self.assertEqual(0, run(f'from pathlib import Path; Path({str(owned)!r}).write_text("owned")').returncode)
        self.assertNotEqual(0, run(f'from pathlib import Path; Path({str(unowned)!r}).write_text("wrong")').returncode)
        self.assertNotEqual(0, run(f'from pathlib import Path; Path({str(self.root / ".git/config")!r}).write_text("wrong")').returncode)
        self.assertNotEqual(0, run(f'from pathlib import Path; Path({str(self.project.directory / "state.json")!r}).write_text("wrong")').returncode)
        self.assertEqual('owned', owned.read_text())
        self.assertEqual('original\n', unowned.read_text())
        alias = self.root / 'modules/books/alias'
        os.link(unowned, alias)
        self.assertNotEqual(0, run(f'from pathlib import Path; Path({str(alias)!r}).write_text("wrong")').returncode)
        self.assertEqual('original\n', unowned.read_text())

    @unittest.skipUnless(shutil.which('bwrap'), 'bubblewrap integration requires Linux user namespaces')
    def test_checked_git_mutations_preserve_other_scopes_and_hooks(self):
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.project.claim('one', ['modules/books'])
        (self.root / 'modules/books/source.txt').write_text('changed\n')
        self.assertEqual(0, claims.git_mutation(self.project, 'one', ['add', '--', 'modules/books/source.txt']))
        self.assertEqual(0, claims.git_mutation(self.project, 'one', ['commit', '-m', 'owned change']))
        self.project.release('one')
        self.project.claim('one', ['modules/books'])
        (self.root / 'configuration.nix').write_text('another scope\n')
        self.git('add', 'configuration.nix')
        before = self.git('rev-parse', 'HEAD')
        with self.assertRaises(ValueError):
            claims.git_mutation(self.project, 'one', ['commit', '-m', 'wrong scope'])
        self.assertEqual(before, self.git('rev-parse', 'HEAD'))
        self.assertIn('configuration.nix', self.git('diff', '--cached', '--name-only'))

    @unittest.skipUnless(shutil.which('bwrap'), 'bubblewrap integration requires Linux user namespaces')
    def test_hooks_cannot_publish_a_commit_from_another_scope(self):
        self.git('config', 'user.name', 'Fixture')
        self.git('config', 'user.email', 'fixture@example.invalid')
        self.project.claim('one', ['modules/books'])
        (self.root / 'modules/books/source.txt').write_text('owned change\n')
        (self.root / 'configuration.nix').write_text('unrelated dirty source\n')
        hook = self.root / '.git/hooks/pre-commit'
        hook.write_text('#!/bin/sh\ngit add -u\n')
        hook.chmod(0o700)
        self.assertEqual(0, claims.git_mutation(self.project, 'one', ['add', '--', 'modules/books/source.txt']))
        before = self.git('rev-parse', 'HEAD')
        staged = self.git('diff', '--cached', '--name-only')
        self.assertNotEqual(0, claims.git_mutation(self.project, 'one', ['commit', '-m', 'scope violation']))
        self.assertEqual(before, self.git('rev-parse', 'HEAD'))
        self.assertEqual(staged, self.git('diff', '--cached', '--name-only'))
        self.assertEqual('unrelated dirty source\n', (self.root / 'configuration.nix').read_text())

    @unittest.skipUnless(shutil.which('bwrap'), 'bubblewrap integration requires Linux user namespaces')
    def test_operation_lock_survives_the_terminal_wrapper(self):
        self.project.claim('one', ['modules/books'])
        command = [sys.executable, '-B', str(source / 'directory_claims.py'),
                   '--repo', str(self.root), '--owner', 'one', 'run', '--cwd', '/tmp', '--',
                   sys.executable, '-c', 'import time; print("ready", flush=True); time.sleep(20)']
        worker = subprocess.Popen(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertEqual('ready\n', worker.stdout.readline())
            with self.assertRaisesRegex(ValueError, 'operation running'):
                self.project.release('one')
        finally:
            worker.terminate()
            worker.communicate(timeout=5)
        for attempt in range(40):
            try:
                self.project.release('one')
                break
            except ValueError:
                if attempt == 39:
                    raise
                time.sleep(0.05)


unittest.main(argv=[sys.argv[0]])
PY
