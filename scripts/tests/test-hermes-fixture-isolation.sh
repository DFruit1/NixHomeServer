#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  # The generic gate needs only the system Python; native integration is separate.
  exec python3 -B - "$repo" "${BASH_SOURCE[0]}" <<'PY'
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest.mock
repo=Path(sys.argv[1]);suite=Path(sys.argv[2]).resolve()
spec=importlib.util.spec_from_file_location('fixture',repo/'scripts/hermes/fixture-runner.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
sys.path.insert(0,str(repo/'scripts/hermes'))
installer_spec=importlib.util.spec_from_file_location('autonomy_installer',repo/'scripts/hermes/install-autonomy-policy.py')
installer=importlib.util.module_from_spec(installer_spec);installer_spec.loader.exec_module(installer)
cli=subprocess.run([sys.executable,'-B',str(repo/'scripts/hermes/fixture-runner.py'),
                   '--repo',str(repo),'--suite',str(suite),
                   '--subject','learning-trials-list'],capture_output=True,text=True)
assert cli.returncode == 2, cli.stderr
invalid=subprocess.run([sys.executable,'-B',str(repo/'scripts/hermes/fixture-runner.py'),
                       '--repo',str(repo),'--subject','unknown'],capture_output=True,text=True)
assert invalid.returncode == 2, invalid.stderr
invalid=subprocess.run([sys.executable,'-B',str(repo/'scripts/hermes/fixture-runner.py'),
                       '--repo',str(repo),'--subject','learning-trials-list','--timeout','0'],
                      capture_output=True,text=True)
assert invalid.returncode == 2, invalid.stderr
invalid=subprocess.run([sys.executable,'-B',str(repo/'scripts/hermes/fixture-runner.py'),
                       '--repo',str(repo),'--subject','learning-trials-list','--live'],
                      capture_output=True,text=True)
assert invalid.returncode == 2, invalid.stderr
invalid=subprocess.run([sys.executable,'-B',str(repo/'scripts/hermes/fixture-runner.py'),
                       '--repo',str(repo),'--subject','learning-trials-list','--','extra'],
                      capture_output=True,text=True)
assert invalid.returncode == 2, invalid.stderr
with tempfile.TemporaryDirectory(prefix='hermes-fixture-invalid-',dir='/tmp') as bad:
    runtime=Path(bad)/'runtime';binary=runtime/'.venv/bin';binary.mkdir(parents=True)
    (binary/'python').symlink_to(Path(sys.executable).resolve())
    (runtime/'.venv/pyvenv.cfg').write_text('home = '+str(Path(sys.executable).resolve().parent)+'\\n')
    scratch=Path(bad)/'scratch';scratch.mkdir()
    try:runner.command(repo,repo/'scripts/hermes/fixture-runner.py',runtime,Path(bad))
    except ValueError as exc:assert 'checked-in synthetic shell suite' in str(exc)
    else:raise AssertionError('Path traversal into scripts/hermes was accepted as a suite')
    fake_repo=Path(bad)/'repo';tests=fake_repo/'scripts/tests';tests.mkdir(parents=True)
    tracked_suite=tests/'test-tracked.sh';tracked_suite.write_text('#!/bin/sh\\nexit 0\\n')
    subprocess.run(['git','-C',str(fake_repo),'init','-q'],check=True)
    subprocess.run(['git','-C',str(fake_repo),'add','scripts/tests/test-tracked.sh'],check=True)
    untracked=tests/'test-untracked.sh';untracked.write_text('#!/bin/sh\\nexit 0\\n')
    try:runner.command(fake_repo,untracked,runtime,Path(bad))
    except ValueError as exc:assert 'must be tracked' in str(exc)
    else:raise AssertionError('Untracked synthetic suite was accepted')
    nested=tests/'nested';nested.mkdir();nested_suite=nested/'test-nested.sh';nested_suite.write_text('#!/bin/sh\\nexit 0\\n')
    try:runner.command(fake_repo,nested_suite,runtime,Path(bad))
    except ValueError as exc:assert 'checked-in synthetic shell suite' in str(exc)
    else:raise AssertionError('Nested suite path was accepted')
    outside=Path(bad)/'outside.sh';outside.write_text('#!/bin/sh\\nexit 0\\n')
    escaped=tests/'test-escaped.sh';escaped.symlink_to(outside)
    try:runner.command(fake_repo,escaped,runtime,Path(bad))
    except ValueError as exc:assert 'checked-in synthetic shell suite' in str(exc)
    else:raise AssertionError('Symlink escape was accepted')
    fake_subject=fake_repo/'scripts/hermes/background-learning-trials.py'
    fake_subject.parent.mkdir(parents=True);fake_subject.symlink_to(outside)
    try:runner.command(fake_repo,None,runtime,Path(bad),subject='learning-trials-list')
    except ValueError as exc:assert 'inside the readonly repository' in str(exc),str(exc)
    else:raise AssertionError('Symlinked synthetic subject was accepted')
    empty_runtime=Path(bad)/'empty-runtime';empty_runtime.mkdir()
    try:runner.command(repo,suite,empty_runtime,Path(bad))
    except ValueError as exc:assert 'Declared native Hermes Python environment' in str(exc)
    else:raise AssertionError('Missing native runtime was accepted')
    try:runner.command(repo,None,runtime,Path(bad),subject='arbitrary')
    except ValueError as exc:assert 'declared synthetic subject' in str(exc)
    else:raise AssertionError('Undeclared synthetic subject was accepted')
    real_which=shutil.which
    with unittest.mock.patch.object(shutil,'which',side_effect=lambda name: None if name=='bwrap' else real_which(name)):
        try:runner.command(repo,None,runtime,Path(bad),subject='learning-trials-list')
        except ValueError as exc:assert 'no unsandboxed fallback' in str(exc)
        else:raise AssertionError('Missing bubblewrap was accepted')
with tempfile.TemporaryDirectory(prefix='hermes-fixture-isolation-',dir='/tmp') as task:
    task=Path(task);runtime=task/'runtime';binary=runtime/'.venv/bin';binary.mkdir(parents=True)
    (binary/'python').symlink_to(Path(sys.executable).resolve())
    (runtime/'.venv/pyvenv.cfg').write_text('home = '+str(Path(sys.executable).resolve().parent)+'\n')
    scratch=task/'scratch';scratch.mkdir()
    native_root=task/'native-root';native_runtime=native_root/'hermes-agent'
    native_binary=native_runtime/'.venv/bin';native_binary.mkdir(parents=True)
    (native_binary/'python').symlink_to(Path(sys.executable).resolve())
    (native_runtime/'.venv/pyvenv.cfg').write_text('home = '+str(Path(sys.executable).resolve().parent)+'\n')
    readiness=task/'readiness';modules=readiness/'modules';native_cli=modules/'hermes_cli';native_cli.mkdir(parents=True)
    (native_cli/'__init__.py').write_text('')
    (native_cli/'main.py').write_text('')
    (modules/'yaml.py').write_text('__version__ = "fixture-yaml"\n')
    (modules/'hermes_yaml.py').write_text('def safe_load(text):\n    assert text == "fixture: true"\n    return {"fixture": True}\n')
    native_python=readiness/'native-python'
    # Hermes uses hermes_yaml/ruamel; its native runtime need not ship PyYAML.
    native_python.write_text('#!'+sys.executable+'\n'+
        'import importlib.abc, sys\n'+
        'class NoPyYaml(importlib.abc.MetaPathFinder):\n'+
        '    def find_spec(self, fullname, path=None, target=None):\n'+
        '        if fullname == "yaml": raise ModuleNotFoundError("native PyYAML deliberately absent")\n'+
        'sys.meta_path.insert(0, NoPyYaml())\n'+
        'assert sys.argv[1:3] == ["-B", "-c"]\n'+
        'exec(compile(sys.argv[3], "<native-readiness>", "exec"))\n')
    native_python.chmod(0o700)
    source=readiness/'test-hermes-autonomy.sh';source.parent.mkdir(parents=True,exist_ok=True)
    source.write_text('synthetic readiness source\\n')
    readiness_origin=readiness/'origin.json';readiness_origin.write_text('{"origin":{}}')
    cli_bin=readiness/'bin';cli_bin.mkdir()
    hermes=cli_bin/'hermes';hermes.write_text('#!/bin/sh\\nexit 0\\n');hermes.chmod(0o700)
    readiness_env=dict(os.environ,PYTHONPATH=str(modules),PATH=str(cli_bin)+':'+os.environ['PATH'],
                       HERMES_FIXTURE_NATIVE_PYTHON=str(native_python),
                       HERMES_FIXTURE_ORIGIN=str(readiness_origin),
                       HERMES_FIXTURE_SOURCE_SHA256=__import__('hashlib').sha256(source.read_bytes()).hexdigest(),
                       HERMES_FIXTURE_ORIGIN_SHA256=__import__('hashlib').sha256(readiness_origin.read_bytes()).hexdigest(),
                       HERMES_FIXTURE_HELPER_SHA256=__import__('hashlib').sha256((repo/'scripts/hermes/fixture-runner.py').read_bytes()).hexdigest())
    readiness_wrapper=("import subprocess; _run=subprocess.run; subprocess.run=lambda args, **kwargs: "
                       "subprocess.CompletedProcess(args, 0) if args == ['/run/hermes-fixture/bin/hermes', '--help'] "
                       "else _run(args, **kwargs); exec(compile("+repr(runner.FIXTURE_BOOTSTRAP)+", "
                       "'<synthetic-readiness>', 'exec'))")
    readiness_run=subprocess.run([sys.executable,'-B','-c',readiness_wrapper,
                                  'suite',str(source),sys.executable,'-B','-c',
                                  'print("SYNTHETIC_SUITE_BODY")'],env=readiness_env,
                                 capture_output=True,text=True,timeout=30)
    assert readiness_run.returncode==0,readiness_run.stderr
    assert 'SYNTHETIC_SUITE_BODY' in readiness_run.stdout,readiness_run.stdout
    ready_receipts=[json.loads(line.removeprefix('HERMES_FIXTURE_RECEIPT '))
                    for line in readiness_run.stderr.splitlines()
                    if line.startswith('HERMES_FIXTURE_RECEIPT ')]
    assert len(ready_receipts)==1 and ready_receipts[0]['event']=='readiness',ready_receipts
    assert ready_receipts[0]['native_python']['yaml_module']==str(modules/'hermes_yaml.py'),ready_receipts
    assert ready_receipts[0]['native_python']['yaml_probe']=={'fixture': True},ready_receipts
    assert ready_receipts[0]['hermes_help_exit']==0,ready_receipts
    retry_source=readiness/'test-kanban-retry-breaker.sh'
    retry_source.write_text('synthetic retry readiness source\\n')
    readiness_env['HERMES_FIXTURE_SOURCE_SHA256']=__import__('hashlib').sha256(retry_source.read_bytes()).hexdigest()
    retry_readiness=subprocess.run([sys.executable,'-B','-c',readiness_wrapper,
                                    'suite',str(retry_source),sys.executable,'-B','-c',
                                    'print("SYNTHETIC_RETRY_BODY")'],env=readiness_env,
                                   capture_output=True,text=True,timeout=30)
    assert retry_readiness.returncode==0,retry_readiness.stderr
    assert 'SYNTHETIC_RETRY_BODY' in retry_readiness.stdout,retry_readiness.stdout
    retry_receipts=[json.loads(line.removeprefix('HERMES_FIXTURE_RECEIPT '))
                    for line in retry_readiness.stderr.splitlines()
                    if line.startswith('HERMES_FIXTURE_RECEIPT ')]
    assert len(retry_receipts)==1 and retry_receipts[0]['event']=='readiness',retry_receipts
    assert retry_receipts[0]['hermes_help_exit']==0,retry_receipts
    parent_origin={key:os.environ.get(key) for key in runner.ORIGIN_KEYS}
    listed_argv,listed_env=runner.command(repo,None,native_runtime,scratch,subject='learning-trials-list')
    listed=subprocess.run(listed_argv,env=listed_env,capture_output=True,text=True)
    assert listed.returncode==0, f'returncode={listed.returncode} stdout={listed.stdout!r} stderr={listed.stderr!r}'
    assert 'Opt in with --live' in listed.stdout,listed.stdout
    receipts=[json.loads(line.removeprefix('HERMES_FIXTURE_RECEIPT ')) for line in listed.stderr.splitlines()
              if line.startswith('HERMES_FIXTURE_RECEIPT ')]
    print('CANONICAL_BWRAP_SYNTHETIC_SUBJECT_READINESS')
    print(listed.stderr,end='')
    assert [item['event'] for item in receipts]==['readiness'],receipts
    readiness=receipts[0]
    subject=repo/'scripts/hermes/background-learning-trials.py'
    assert readiness['kind']=='subject' and readiness['source']==str(subject.resolve()),readiness
    assert readiness['source_sha256']==__import__('hashlib').sha256(subject.read_bytes()).hexdigest(),readiness
    assert readiness['helper_sha256']==__import__('hashlib').sha256((repo/'scripts/hermes/fixture-runner.py').read_bytes()).hexdigest(),readiness
    expected_origin={key:value for key,value in parent_origin.items() if value is not None}
    recorded_origin=json.loads((scratch/'origin.json').read_text())
    assert recorded_origin['origin']==expected_origin,recorded_origin
    assert readiness['origin_sha256']==__import__('hashlib').sha256((scratch/'origin.json').read_bytes()).hexdigest(),readiness
    assert {key:os.environ.get(key) for key in runner.ORIGIN_KEYS}==parent_origin
    saved_argv=sys.argv
    class TimedOutProcess:
        pid=4242
        def wait(self,timeout=None):
            if timeout is not None:raise subprocess.TimeoutExpired('fixture',timeout)
            return 0
    def fake_timeout_command(repo_arg,suite_arg,runtime_arg,scratch_arg,subject_arg):
        (scratch_arg/'origin.json').write_text('{}')
        return ['bwrap'],{}
    try:
        sys.argv=['fixture-runner.py','--repo',str(repo),'--subject','learning-trials-list','--timeout','1']
        timed_output=io.StringIO()
        with unittest.mock.patch.object(runner,'command',side_effect=fake_timeout_command), unittest.mock.patch.object(subprocess,'Popen',return_value=TimedOutProcess()), unittest.mock.patch.object(os,'killpg') as killpg, contextlib.redirect_stderr(timed_output):
            assert runner.main()==124
        print('SYNTHETIC_TIMEOUT_ACCOUNTING_ONLY')
        print(timed_output.getvalue(),end='')
        timeout_receipts=[json.loads(line.removeprefix('HERMES_FIXTURE_RECEIPT '))
                          for line in timed_output.getvalue().splitlines()
                          if line.startswith('HERMES_FIXTURE_RECEIPT ')]
        assert [item['event'] for item in timeout_receipts]==['launch','terminal'],timeout_receipts
        timeout_launch,timeout_terminal=timeout_receipts
        for key in ('kind','source','source_sha256','helper_sha256','origin_sha256'):
            assert timeout_launch[key]==timeout_terminal[key],(key,timeout_receipts)
        assert timeout_terminal['timed_out'] is True and timeout_terminal['returncode']==124
        assert killpg.call_count==1
    finally:
        sys.argv=saved_argv
    assert {key:os.environ.get(key) for key in runner.ORIGIN_KEYS}==parent_origin
    routing_scratch=task/'routing-scratch';routing_scratch.mkdir()
    argv,env=runner.command(repo,repo/'scripts/tests/test-script-test-runner.sh',runtime,routing_scratch)
    routing=subprocess.run(argv,env=env,capture_output=True,text=True,timeout=180)
    assert routing.returncode==0,routing.stdout+'\\n'+routing.stderr
    assert 'confines exactly nine pinned suites' in routing.stdout,routing.stdout
    install_root=task/'install-root';target=install_root/'scripts/fixture-runner.py'
    target.parent.mkdir(parents=True);target.write_text('previous helper bytes\\n');target.chmod(0o640)
    old=target.read_bytes();old_mode=target.stat().st_mode & 0o777
    assert installer.install(install_root,True,True)==1
    assert target.read_bytes()==old and target.stat().st_mode & 0o777==old_mode
    assert installer.install(install_root,False,True)==0
    assert target.read_bytes()==(repo/'scripts/hermes/fixture-runner.py').read_bytes()
    assert target.stat().st_mode & 0o777==old_mode
    assert installer.install(install_root,True,True)==0
    backups=list((install_root/'backups/autonomy-policy').rglob('*'))
    assert any(p.is_file() and p.read_bytes()==old for p in backups)
    assert any(p.is_file() and p.name.endswith('.mode') and p.read_text()=='0640\n' for p in backups)
    check_before=(target.read_bytes(),target.stat().st_mode & 0o777)
    checked=subprocess.run([sys.executable,'-B',str(repo/'scripts/hermes/install-autonomy-policy.py'),
                            '--fixture-runner-only','--check'],
                           env=dict(os.environ,HERMES_ROOT=str(install_root)),capture_output=True,text=True)
    assert checked.returncode==0,checked.stderr
    assert (target.read_bytes(),target.stat().st_mode & 0o777)==check_before
    for pin in ('HERMES_KANBAN_TASK','HERMES_DELEGATED_CHILD_CONTEXT'):
        refused=subprocess.run([sys.executable,'-B',str(repo/'scripts/hermes/install-autonomy-policy.py'),
                                '--fixture-runner-only'],
                               env=dict(os.environ,HERMES_ROOT=str(install_root),**{pin:'synthetic-origin'}),
                               capture_output=True,text=True)
        assert refused.returncode==2 and 'interactive operator' in refused.stderr,refused.stderr
    target.unlink();outside=install_root/'outside';outside.write_text('do not follow\\n')
    target.symlink_to(outside)
    try:installer.install(install_root,True,True)
    except ValueError:pass
    else:raise AssertionError('Installer accepted symlink target')
    assert outside.read_text()=='do not follow\\n'
    target.unlink()
    target.write_text('preimage bytes\\n');target.chmod(0o640)
    original_backup_file=installer.backup_file
    def concurrent_edit(root,subdir,path):
        backup=original_backup_file(root,subdir,path)
        target.write_text('concurrent writer bytes\\n');target.chmod(0o600)
        return backup
    installer.backup_file=concurrent_edit
    try:
        installer.install(install_root,False,True)
    except ValueError:
        pass
    else:
        raise AssertionError('Installer overwrote a concurrent edit after backup')
    assert target.read_text()=='concurrent writer bytes\\n'
    assert target.stat().st_mode & 0o777==0o600
    race_backups=list((install_root/'backups/autonomy-policy').rglob('*'))
    assert any(p.is_file() and p.read_bytes()==b'preimage bytes\\n' for p in race_backups)
    assert any(p.is_file() and p.name.endswith('.mode') and p.read_text()=='0640\n' for p in race_backups)
    installer.backup_file=original_backup_file
    target.write_text('replacement preimage\\n');target.chmod(0o640)
    original_atomic_write=installer.atomic_write
    def replacement_before_atomic(path,content,mode=None):
        if Path(path).name.startswith('.fixture-runner.py.'):
            replacement=target.with_name('replacement-helper')
            replacement.write_bytes(target.read_bytes());replacement.chmod(0o640)
            replacement.replace(target)
        return original_atomic_write(path,content,mode)
    installer.atomic_write=replacement_before_atomic
    try:
        installer.install(install_root,False,True)
    except ValueError:
        pass
    else:
        raise AssertionError('Installer overwrote a replaced target at atomic replacement')
    assert target.read_text()=='replacement preimage\\n'
    assert target.stat().st_mode & 0o777==0o640
    installer.atomic_write=original_atomic_write
    absent_root=task/'absent-root';absent_target=absent_root/'scripts/fixture-runner.py'
    original_fixture_state=installer._fixture_state;state_calls=[0]
    def appears_after_preflight(path,root):
        state_calls[0]+=1
        if path==absent_target and state_calls[0]==2:
            absent_target.parent.mkdir(parents=True)
            absent_target.write_text('new concurrent file\\n');absent_target.chmod(0o600)
        return original_fixture_state(path,root)
    installer._fixture_state=appears_after_preflight
    try:
        installer.install(absent_root,False,True)
    except ValueError:
        pass
    else:
        raise AssertionError('Installer overwrote a target that appeared after preflight')
    finally:
        installer._fixture_state=original_fixture_state
    assert absent_target.read_text()=='new concurrent file\\n'
    # A reviewed coordinator may maintain only the fixture source helper.
    # Authentication/native reads are mocked; Git source identity and target
    # writes use isolated real checkouts and the actual installer path.
    import copy
    source_repo=task/'maintenance-source'
    source_dir=source_repo/'scripts/hermes';source_dir.mkdir(parents=True)
    reviewed_bytes=(repo/'scripts/hermes/fixture-runner.py').read_bytes()
    source_helper=source_dir/'fixture-runner.py';source_helper.write_bytes(reviewed_bytes)
    def source_git(*args):
        return subprocess.check_output(['git','-C',str(source_repo),*args],text=True).strip()
    source_git('init','-q','--initial-branch=master')
    source_git('config','user.name','fixture')
    source_git('config','user.email','fixture@example.invalid')
    source_git('add','scripts/hermes/fixture-runner.py')
    source_git('commit','-qm','reviewed fixture helper')
    revision=source_git('rev-parse','HEAD')
    maintenance_root=task/'maintenance-root'
    maintenance_target=maintenance_root/'scripts/fixture-runner.py'
    maintenance_target.parent.mkdir(parents=True)
    maintenance_target.write_text('previous helper');maintenance_target.chmod(0o640)
    auth_origin={'profile':'head-coordinator','task_id':'t_actor','run_id':31,'board':'actual-board'}
    accepted_review={'task':{'id':'t_review','status':'done','assignee':'feature-reviewer'},
        'runs':[{'id':32,'profile':'feature-reviewer','status':'done','outcome':'completed',
                 'metadata':{'verdict':'accept','revision':revision,
                    'checks':[{'command':'synthetic independent check','exit_code':0}],
                    'installation_scope':['scripts/hermes/fixture-runner.py']}}]}
    def native_review(board,task_id,*,root):
        assert root==maintenance_root
        assert (board,task_id)==('actual-board','t_review')
        return copy.deepcopy(accepted_review)
    forged_cli=task/'forged-hermes'
    forged_marker=task/'forged-hermes-invoked'
    forged_cli.write_text('#!'+sys.executable+'\nfrom pathlib import Path\n'
                          +'Path('+repr(str(forged_marker))+').write_text("forged")\n'
                          +'print('+repr(json.dumps(accepted_review))+')\n')
    forged_cli.chmod(0o700)
    # A caller-selected executable must never supply native acceptance evidence.
    with unittest.mock.patch.dict(os.environ,{'HERMES_BIN':str(forged_cli),'HERMES_ROOT':str(maintenance_root)}):
        try:installer._native_review('actual-board','t_review')
        except ValueError:pass
        else:raise AssertionError('Caller-controlled HERMES_BIN supplied forged acceptance')
    assert not forged_marker.exists()
    old_source=installer.SOURCE
    try:
        installer.SOURCE=source_dir
        with unittest.mock.patch.object(installer,'authenticated_current_origin',return_value=auth_origin) as authenticate, \
             unittest.mock.patch.object(installer,'_native_review',side_effect=native_review):
            assert installer.install(maintenance_root,False,True,review_card='t_review')==0
            authenticate.assert_called_with(maintenance_root,expected_profile='head-coordinator')
        assert maintenance_target.read_bytes()==reviewed_bytes
        assert maintenance_target.stat().st_mode & 0o777==0o640
        maintenance_backups=list((maintenance_root/'backups/autonomy-policy').rglob('*'))
        assert any(path.is_file() and path.read_bytes()==b'previous helper' for path in maintenance_backups)
        for bad_origin in (None, {**auth_origin,'profile':'standard-implementer'},
                           {**auth_origin,'profile':'feature-reviewer'}):
            with unittest.mock.patch.object(installer,'authenticated_current_origin',return_value=bad_origin):
                try:installer.install(maintenance_root,False,True,review_card='t_review')
                except ValueError:pass
                else:raise AssertionError('Unauthenticated source maintenance was accepted: '+repr(bad_origin))
            assert maintenance_target.read_bytes()==reviewed_bytes
        with unittest.mock.patch.object(installer,'authenticated_current_origin',side_effect=ValueError('delegated session has no native grant')):
            try:installer.install(maintenance_root,False,True,review_card='t_review')
            except ValueError:pass
            else:raise AssertionError('Delegated source maintenance was accepted')
        metadata=accepted_review['runs'][0]['metadata']
        for update in ({'revision':'0'*40}, {'verdict':'unknown'}, {'checks':[]},
                       {'checks':[{'command':'check','exit_code':1}]},
                       {'checks':[{'command':'check','exit_code':False}]},
                       {'installation_scope':None},
                       {'installation_scope':['scripts/hermes/fixture-runner.py','autonomy-policy.py']}):
            saved=copy.deepcopy(metadata);metadata.update(update)
            with unittest.mock.patch.object(installer,'authenticated_current_origin',return_value=auth_origin), \
                 unittest.mock.patch.object(installer,'_native_review',side_effect=native_review):
                try:installer.install(maintenance_root,False,True,review_card='t_review')
                except ValueError:pass
                else:raise AssertionError('Invalid source maintenance evidence was accepted: '+repr(update))
            metadata.clear();metadata.update(saved)
            assert maintenance_target.read_bytes()==reviewed_bytes
        accepted_review['runs'].append({'id':33,'profile':'feature-reviewer','status':'running','outcome':None,'metadata':{}})
        with unittest.mock.patch.object(installer,'authenticated_current_origin',return_value=auth_origin), \
             unittest.mock.patch.object(installer,'_native_review',side_effect=native_review):
            try:installer.install(maintenance_root,False,True,review_card='t_review')
            except ValueError:pass
            else:raise AssertionError('Older acceptance survived a newer unfinished run')
        accepted_review['runs'].pop()
        accepted_review['task']['assignee']='project-auditor'
        accepted_review['runs'][0]['profile']='project-auditor'
        with unittest.mock.patch.object(installer,'authenticated_current_origin',return_value=auth_origin), \
             unittest.mock.patch.object(installer,'_native_review',side_effect=native_review):
            try:installer.install(maintenance_root,False,True,review_card='t_review')
            except ValueError:pass
            else:raise AssertionError('Auditor acceptance without independence was trusted')
            metadata['independence']={'plan_author':False,'implementer':False}
            assert installer.install(maintenance_root,False,True,review_card='t_review')==0
        metadata.pop('independence')
        accepted_review['task']['assignee']='feature-reviewer'
        accepted_review['runs'][0]['profile']='feature-reviewer'
        source_helper.write_bytes(reviewed_bytes+b'\n# uncommitted change\n')
        with unittest.mock.patch.object(installer,'authenticated_current_origin',return_value=auth_origin), \
             unittest.mock.patch.object(installer,'_native_review',side_effect=native_review):
            try:installer.install(maintenance_root,False,True,review_card='t_review')
            except ValueError:pass
            else:raise AssertionError('Dirty source maintenance was accepted')
        source_helper.write_bytes(reviewed_bytes)
        with unittest.mock.patch.object(installer,'authenticated_current_origin',return_value=auth_origin):
            try:installer.install(maintenance_root,False,False,review_card='t_review')
            except ValueError:pass
            else:raise AssertionError('Bot maintenance expanded to the native/config installer')
        assert maintenance_target.read_bytes()==reviewed_bytes
        with unittest.mock.patch.object(installer,'authenticated_current_origin',side_effect=AssertionError('checks need no execution grant')):
            assert installer.install(maintenance_root,True,True,review_card='t_review')==0
    finally:
        installer.SOURCE=old_source
    if not shutil.which('bwrap'):
        try:runner.command(repo,suite,runtime,scratch)
        except ValueError as exc:
            assert 'bubblewrap is required' in str(exc)
            print('PASS missing bubblewrap refuses execution; confinement integration unavailable')
        else:raise AssertionError('Fixture execution silently lost confinement')
    else:
        parent_origin={key:os.environ.get(key) for key in runner.ORIGIN_KEYS}
        outer_scratch=task/'outer-scratch';outer_scratch.mkdir()
        argv,env=runner.command(repo,suite,runtime,outer_scratch)
        origin=json.loads((outer_scratch/'origin.json').read_text())
        assert origin['origin']=={key:value for key,value in parent_origin.items() if value is not None}
        assert {key:os.environ.get(key) for key in runner.ORIGIN_KEYS}==parent_origin
        raise SystemExit(subprocess.call(argv,env=env))
PY
fi
python3 -B - "$repo" <<'PY'
import json
import os
from pathlib import Path
import socket
import shutil
import sys

repo=Path(sys.argv[1])
origin=json.loads(Path(os.environ['HERMES_FIXTURE_ORIGIN']).read_text())
assert origin['provenance']=='confined-synthetic-test'
try:
    Path(os.environ['HERMES_FIXTURE_ORIGIN']).write_text('must refuse')
except OSError:
    pass
else:
    raise AssertionError('Origin receipt is writable')
for variable in ('HERMES_KANBAN_TASK','HERMES_KANBAN_DB','HERMES_DELEGATED_CHILD_CONTEXT',
                 'SSH_AUTH_SOCK','OPENAI_API_KEY','BASH_ENV','LD_PRELOAD'):
    assert variable not in os.environ, variable
assert not Path('/var/lib').exists()
assert not Path('/run/user').exists()
assert not Path('/home/dsaw/.ssh').exists()
assert not Path('/home/dsaw/.hermes/kanban/boards/nixhomeserver/kanban.db').exists()
assert not Path('/home/dsaw/.hermes/hermes-agent/.env').exists()
assert not any((repo/'secrets/unencrypted').glob('*'))
for path in (repo/'scripts/hermes/fixture-runner.py',Path(shutil.which('true')).resolve()):
    try:
        with path.open('ab'):
            pass
    except OSError:
        pass
    else:
        raise AssertionError('Readonly mount is writable: '+str(path))
probe=socket.socket()
probe.settimeout(.1)
try:
    probe.connect(('1.1.1.1',443))
except OSError:
    pass
else:
    raise AssertionError('Fixture network escaped its namespace')
finally:
    probe.close()
print('PASS fixture credentials/home/host state absent, readonly code, isolated network, origin retained')
PY
