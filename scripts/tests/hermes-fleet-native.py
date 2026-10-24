#!/usr/bin/env python3
"""Installed native tools and shell hooks, inside the maintained fixture only."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time
from unittest.mock import patch

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hermes-repo', type=Path, required=True)
parser.add_argument('--scratch', type=Path, required=True)
args = parser.parse_args()
if os.environ.get('HERMES_FIXTURE_ACTIVE') != '1':
    parser.error('Use test-hermes-fleet-native.sh through the confined fixture; no unsandboxed fallback')
origin = json.loads(Path(os.environ['HERMES_FIXTURE_ORIGIN']).read_text())
assert Path(origin['suite']).name == 'test-hermes-fleet-native.sh'
assert origin['provenance'] == 'confined-synthetic-test'
assert not any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK', 'HERMES_KANBAN_RUN_ID',
                                          'HERMES_DELEGATED_CHILD_CONTEXT'))
source = Path(__file__).resolve().parents[1] / 'hermes'
root = args.scratch / 'home'
root.mkdir()
for name in ('HERMES_HOME', 'HERMES_ROOT', 'HERMES_KANBAN_HOME'):
    os.environ[name] = str(root)
os.environ['HERMES_DISABLE_LAZY_INSTALLS'] = '1'
os.environ['HERMES_KANBAN_WORKSPACES_ROOT'] = str(args.scratch / 'workspaces')
sys.path.insert(0, str(source))
sys.path.insert(0, str(args.hermes_repo))
import hermes_bootstrap  # noqa: E402,F401


def module(name, filename):
    spec = importlib.util.spec_from_file_location(name, source / filename)
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


# Install maintained transforms into a private native overlay. Other native
# modules are imported from the read-only declared runtime, never copied secrets.
for relative in ('hermes_cli/kanban_db.py', 'hermes_cli/kanban_db_dispatch.py',
                 'hermes_cli/kanban.py', 'hermes_cli/kanban_parser.py',
                 'tools/kanban_tools.py', 'tools/kanban_tools_schemas.py',
                 'agent/kanban_stop.py',
                 'hermes_cli/nixhomeserver_resume_recovered.py',
                 'hermes_cli/nixhomeserver_coordinator_repair.py'):
    target = root / 'hermes-agent' / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(args.hermes_repo / relative, target)
for profile in ('head-coordinator', 'standard-implementer', 'feature-reviewer', 'project-auditor'):
    directory = root / 'profiles' / profile
    directory.mkdir(parents=True)
    (directory / 'config.yaml').write_text('model:\n  default: fixture\n')
    (directory / 'profile.yaml').write_text('name: ' + profile + '\n')
# Installers use the declared system PyYAML interpreter; actual execution uses
# the native Hermes interpreter. Both run inside the same confined filesystem.
installation = r"""
import importlib.util, pathlib, sys
source, root = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(source))
def load(name, filename):
    spec=importlib.util.spec_from_file_location(name,source/filename)
    value=importlib.util.module_from_spec(spec);spec.loader.exec_module(value);return value
worker=load('fixture_worker_installer','install-worker-policy.py')
assert worker.install(root)==0
assert worker.install(root,check=True)==0
hooks=load('fixture_taskforce_installer','install-review-taskforce.py')
for path,text in hooks.review_hook_files(root).items():
    path.parent.mkdir(parents=True,exist_ok=True);path.write_text(text)
(root/'scripts/feature_flow.py').write_text((source/'feature_flow.py').read_text())
"""
subprocess.run(['/usr/bin/python3', '-B', '-c', installation, str(source), str(root)], check=True)
import hermes_cli  # noqa: E402
hermes_cli.__path__.insert(0, str(root / 'hermes-agent/hermes_cli'))
import tools  # noqa: E402
tools.__path__.insert(0, str(root / 'hermes-agent/tools'))
from hermes_cli import kanban_db as kb, kanban_db_dispatch as dispatch  # noqa: E402
from hermes_cli import nixhomeserver_worker_policy as policy  # noqa: E402
from hermes_cli.kanban_db_connect import connect  # noqa: E402
from tools import kanban_tools as transport  # noqa: E402
from agent import shell_hooks  # noqa: E402
import hermes_yaml as yaml  # noqa: E402
assert kb.kanban_home().resolve().is_relative_to(args.scratch.resolve())
kb.create_board('fixture')
db = connect(kb.kanban_db_path('fixture'))
assert Path(transport.__file__).is_relative_to(root)
assert Path(kb.__file__).is_relative_to(root)


def call(name, **fields):
    fields = dict(board='fixture', **fields)
    config = yaml.safe_load((root / 'profiles/feature-reviewer/config.yaml').read_text())
    for hook in config['hooks']['pre_tool_call']:
        callback = shell_hooks._make_callback(shell_hooks.ShellHookSpec(
            event='pre_tool_call', command=hook['command'], matcher=hook['matcher'],
            timeout=15, fail_closed=True))
        result = callback(tool_name=name, session_id='confined-fleet', args=fields)
        if result and result.get('action') == 'block':
            return {'error': result['message']}
    return json.loads(getattr(transport, '_handle_' + name.removeprefix('kanban_'))(fields))


def okay(value):
    assert 'error' not in value, value
    return value


work=args.scratch/'source';work.mkdir()
def git(*arguments):
    return subprocess.check_output(['git','-C',str(work),*arguments],stderr=subprocess.DEVNULL,text=True).strip()
git('init');git('config','user.name','Fixture');git('config','user.email','fixture@example.invalid')
git('commit','--allow-empty','-m','baseline');baseline=git('rev-parse','HEAD')
try:
    # Exercise real preclaim and post-preparation dispatch seams with an inert
    # spawn callback. No model or production process is started.
    spawned=[]
    def inert_spawn(*args,**kwargs):
        spawned.append((args,kwargs));return 99999999
    for revision,should_spawn in [('a'*40,False),(baseline,True)]:
        probe=okay(call('kanban_create',title='Dispatch prerequisite fixture',assignee='standard-implementer',
            workflow={'version':1,'requirements':{'source_revision':revision}},
            workspace_kind='dir',workspace_path=str(work)))['task_id']
        row=db.execute('SELECT * FROM tasks WHERE id=?',(probe,)).fetchone()
        result=dispatch.DispatchResult()
        dispatched=dispatch._dispatch_lane_task(db,row,'standard-implementer',result,lane='ready',dry_run=False,
            ttl_seconds=None,board='fixture',failure_limit=2,spawn_fn=inert_spawn,
            per_profile_caps=None,per_profile_running={})
        assert bool(dispatched)==should_spawn,(dispatched,result)
        assert (kb.get_task(db,probe).status=='blocked') != should_spawn
    assert len(spawned)==1
    tracker = okay(call('kanban_create', title='[FEATURE TRACKER] fixture slice',
                        assignee='head-coordinator', body='Requested synthetic accepted-source slice.'))['task_id']
    feature = {'tracker': 'fixture:' + tracker, 'role': 'producer',
               'scope': 'synthetic accepted source only', 'stage': 'accepted'}
    workflow = {'version': 1, 'review': 'native-review-v1', 'plan_author': 'owner', 'feature': feature,'requirements':{'source_revision':baseline}}
    # The author error must guide correction of this request, never a second
    # prose-only task. Exercise both actual hook/transport and native DB seams.
    missing = object()
    request = dict(title='Implement fixture slice', assignee='standard-implementer',
                   parents=[tracker], workspace_kind='dir', workspace_path=str(work))
    for author in (missing, None, False, True, 123, [], {}, '', 'head coordinator',
                   'head/coordinator', 'a' * 81):
        invalid = {**workflow}
        if author is missing:
            del invalid['plan_author']
        else:
            invalid['plan_author'] = author
        db.commit()
        before = list(db.iterdump())
        result = call('kanban_create', **request, workflow=invalid)
        assert list(db.iterdump()) == before, 'Rejected tool create wrote task/events/links'
        assert 'error' in result, result
        messages = [result['error']]
        try:
            kb.create_task(db, **request, workflow=invalid)
            raise AssertionError('Native create accepted an invalid author')
        except ValueError as exc:
            messages.append(str(exc))
        assert list(db.iterdump()) == before, 'Rejected native create wrote task/events/links'
        for message in messages:
            for detail in ('[A-Za-z0-9_-]{1,80}', 'pre-write rejection',
                           'no task, events or links created', 'same request',
                           'truthful author', 'preserve workflow', 'native-review-v1'):
                assert detail in message, (author, message)
    # In this synthetic specification the owner is the actual author. Change
    # only the invalid field, preserving all other request fields and bindings.
    invalid['plan_author'] = 'owner'
    assert invalid == workflow
    corrected = okay(call('kanban_create', **request, workflow=invalid))['task_id']
    from hermes_cli import nixhomeserver_fleet_contract as contract
    assert contract.load(db, corrected) == workflow
    assert okay(call('kanban_show', task_id=corrected))['workflow'] == workflow
    assert 'Workflow: native-review-v1' in kb.get_task(db, corrected).body
    assert db.execute("SELECT COUNT(*) FROM task_events WHERE task_id=? AND kind='created'",
                      (corrected,)).fetchone()[0] == 1
    print('PASS: invalid author creates no task/events/links; corrected request retains structured review')
    tid = okay(call('kanban_create', title='Implement fixture slice', assignee='standard-implementer',
                   workflow=workflow, workspace_kind='dir', workspace_path=str(work)))['task_id']
    from hermes_cli import nixhomeserver_fleet_contract as contract
    assert contract.load(db, tid) == workflow
    # Conflicting body/comments cannot erase immutable workflow membership.
    db.execute('UPDATE tasks SET body=? WHERE id=?', ('Workflow: wrong\nFeature tracker: foreign:t_wrong', tid))
    kb.add_comment(db, tid, author='fixture', body='Feature tracker: foreign:t_wrong')
    claim = kb.claim_task(db, tid)
    assert claim
    checks = [{'command': 'confined fixture assertions', 'exit_code': 0}]
    git('commit','--allow-empty','-m','implementation');first=git('rev-parse','HEAD')
    handoff = {'revision': first, 'checks': checks}
    okay(call('kanban_request_review', task_id=tid, summary='Implemented and checked the requested fixture.',
              metadata=handoff, reviewer='feature-reviewer'))
    assert policy.reason(db,tid,'feature-reviewer') is None
    assert kb.claim_review_task(db, tid)
    accepted = {**handoff, 'verdict': 'accept',
                'independence': {'plan_author': False, 'implementer': False}}
    okay(call('kanban_request_changes', task_id=tid, reason='Synthetic correction required.'))
    assert kb.claim_task(db, tid)
    assert 'error' in call('kanban_complete', task_id=tid, summary='Cannot self-accept.', metadata=accepted)
    git('commit','--allow-empty','-m','rework');second=git('rev-parse','HEAD')
    handoff['revision'] = second
    okay(call('kanban_request_review', task_id=tid, summary='Corrected and checked the fixture.', metadata=handoff))
    assert kb.claim_review_task(db, tid)
    assert 'error' in call('kanban_complete', task_id=tid, summary='Stale revision.', metadata=accepted)
    accepted['revision'] = handoff['revision']
    okay(call('kanban_complete', task_id=tid, summary='Independently accepted fixture scope.', metadata=accepted))
    # GC must keep new contract authority even after terminal lifecycle history ages.
    db.execute('UPDATE task_events SET created_at=? WHERE task_id=?', (1, tid))
    kb.gc_events(db, older_than_seconds=1)
    assert contract.load(db, tid) == workflow
    assert okay(call('kanban_show', task_id=tid))['workflow'] == workflow
    delivery_feature = {**feature, 'role': 'delivery'}
    delivery_task = okay(call('kanban_create', title='Reconcile delivered fixture scope', assignee='head-coordinator',
                             workflow={'version': 1, 'feature': delivery_feature},
                             workspace_kind='dir', workspace_path=str(args.scratch)))['task_id']
    assert kb.claim_task(db, delivery_task)
    assert 'error' in call('kanban_complete', task_id=delivery_task, summary='Missing machine evidence.')
    sys.path.insert(0, str(root / 'scripts'))
    import feature_flow
    inspected = feature_flow.inspect_feature(db, 'fixture', tracker)
    delivery = {'state': 'delivered_scope', 'evidence_task_id': tid,
                'expected_version': inspected['evidence_version']}
    kb.add_comment(db, tracker, author='owner', body='An actual changed scope input.')
    assert 'error' in call('kanban_complete', task_id=delivery_task, summary='Stale scope.', delivery=delivery)
    try:
        kb.complete_task(db,delivery_task,summary='Stale scope through direct native call.',delivery=delivery)
        raise AssertionError('Native transaction accepted stale delivery')
    except ValueError:
        assert kb.get_task(db,delivery_task).status=='running'
    delivery['expected_version'] = feature_flow.inspect_feature(db, 'fixture', tracker)['evidence_version']
    okay(call('kanban_complete', task_id=delivery_task, summary='Accepted source scope delivered.', delivery=delivery))
    meta = json.loads(db.execute('SELECT metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                                (delivery_task,)).fetchone()[0])
    assert meta['feature_delivery']['revision'] == second
    assert meta['feature_delivery']['stage'] == 'accepted'
    assert not feature_flow.observe_features(db, 'fixture', int(time.time()) + 49 * 3600)
    # Replay pre-upgrade creation through the native lifecycle, not fabricated
    # review events. Only the newly introduced create-time rule is suspended.
    plan = kb.create_task(db, title='Original immutable plan', assignee='project-auditor')
    assert kb.claim_task(db, plan)
    legacy_feature = {**feature, 'stage': 'integrated', 'role': 'delivery'}
    legacy_delivery = kb.create_task(db, title='Structured legacy commissioning delivery',
        assignee='head-coordinator', parents=[plan], creator_task_id=plan,
        workflow={'version': 1, 'plan_author': 'project-auditor', 'feature': legacy_feature})
    plan_hash = 'c' * 64
    kb.complete_task(db, plan, summary='Published original plan.', metadata={
        'plan_sha256': plan_hash, 'feature_tracker': feature['tracker'], 'delivery_task': legacy_delivery})
    with patch.object(contract, 'validate_create', create=True):
        legacy = kb.create_task(db, title='Historical prose-only native producer',
            assignee='standard-implementer', body='Workflow: native-review-v1',
            parents=[plan], creator_task_id=legacy_delivery, created_by='head-coordinator')
    assert kb.claim_task(db, legacy)
    legacy_handoff = {'revision': second, 'checks': checks, 'plan_author': 'project-auditor',
                      'plan_sha256': plan_hash}
    okay(call('kanban_request_review', task_id=legacy, metadata=legacy_handoff,
              summary='Legacy implementer handoff.', reviewer='feature-reviewer'))
    assert kb.claim_review_task(db, legacy)
    legacy_acceptance = {**legacy_handoff, 'verdict': 'accept', 'feature_tracker': feature['tracker'],
                         'independence': {'plan_author': False, 'implementer': False}}
    okay(call('kanban_complete', task_id=legacy, metadata=legacy_acceptance,
              summary='Independent historical acceptance.'))
    assert kb.claim_task(db, legacy_delivery)
    registration = kb.kanban_db_path('fixture').with_name('board.json')
    board_meta = json.loads(registration.read_text())
    registration.write_text(json.dumps({**board_meta, 'default_workdir': str(work)}))

    def legacy_payload(**fields):
        return {'state': 'delivered_scope', 'evidence_task_id': legacy,
                'expected_version': feature_flow.inspect_feature(db, 'fixture', tracker)['evidence_version'], **fields}

    def refused_unchanged(payload, message):
        db.commit()
        before = list(db.iterdump())
        assert 'error' in call('kanban_complete', task_id=legacy_delivery,
                              summary='Rejected synthetic delivery.', delivery=payload), message
        assert list(db.iterdump()) == before, message
        try:
            kb.complete_task(db, legacy_delivery, summary='Direct rejection.', delivery=payload)
            raise AssertionError(message)
        except ValueError:
            pass
        assert list(db.iterdump()) == before, message

    refused_unchanged(legacy_payload(), 'Metadata tracker alone must not establish membership')
    kb.add_comment(db, legacy, author='head-coordinator', body='Feature tracker: ' + feature['tracker'])
    db.commit()
    # This is the original RED: exact authentic legacy commissioning is still
    # refused by the structured-source-only gate, after membership is reconciled.
    candidate = contract.completion_metadata(db, legacy_delivery, None, legacy_payload())
    assert candidate['feature_delivery']['revision'] == second
    assert candidate['feature_delivery']['scope'] == feature['scope']
    assert candidate['feature_delivery']['stage'] == 'integrated'

    def changed_json(table, column, where, values, transform, message):
        raw = db.execute(f'SELECT {column} FROM {table} WHERE {where}', values).fetchone()[0]
        modified = transform(json.loads(raw))
        db.execute(f'UPDATE {table} SET {column}=? WHERE {where}', (json.dumps(modified), *values))
        refused_unchanged(legacy_payload(), message)
        db.execute(f'UPDATE {table} SET {column}=? WHERE {where}', (raw, *values)); db.commit()

    kb.add_comment(db, legacy, author='head-coordinator', body='Feature tracker: fixture:t_wrong')
    refused_unchanged(legacy_payload(), 'Latest explicit membership must still match')
    kb.add_comment(db, legacy, author='head-coordinator', body='Feature tracker: ' + feature['tracker'])
    db.commit()
    created_where = "task_id=? AND kind='created'"
    # Negative mutations model corrupt/unrelated evidence only inside the fixture.
    # Production creation events are never rewritten by this repair.
    for changes in ({'creator_task_id': tid}, {'parents': [tid]}, {'workflow': {'version': 1}},
                    *({'workflow': {'version': 1, 'review': 'native-review-v1', 'plan_author': 'project-auditor',
                        'feature': {**legacy_feature, 'role': 'producer', **mismatch}}}
                      for mismatch in ({'scope': 'unrelated'}, {'tracker': 'fixture:t_wrong'}, {'stage': 'accepted'}))):
        changed_json('task_events', 'payload', created_where, (legacy,),
                     lambda value, changes=changes: {**value, **changes}, 'Wrong producer commissioning')
    changed_json('task_events', 'payload', created_where, (legacy_delivery,),
                 lambda value: {**value, 'creator_task_id': tid}, 'Wrong original plan')
    for changes in ({'feature_tracker': 'fixture:t_wrong'}, {'plan_sha256': 'd'*64},
                    {'revision': 'a'*40}, {'revision': second[:7]}, {'verdict': 'request-changes'},
                    {'checks': []}, {'checks': [{'command': 'failed owning check', 'exit_code': 1}]},
                    {'independence': {'plan_author': False, 'implementer': True}}):
        changed_json('task_runs', 'metadata', "task_id=? AND status='done'", (legacy,),
                     lambda value, changes=changes: {**value, **changes}, 'Invalid acceptance evidence')
    for changes in ({'plan_author': 'feature-reviewer'}, {'plan_author': 'head-coordinator'},
                    {'plan_sha256': 'd'*64}, {'revision': 'a'*40}):
        changed_json('task_runs', 'metadata', "task_id=? AND outcome='review_requested'", (legacy,),
                     lambda value, changes=changes: {**value, **changes}, 'Invalid handoff evidence')
    changed_json('task_events', 'payload', "task_id=? AND kind='review_requested'", (legacy,),
                 lambda value: {**value, 'implementer': 'feature-reviewer'}, 'Self acceptance')
    changed_json('task_events', 'payload',
                 "id=(SELECT MAX(id) FROM task_events WHERE task_id=? AND kind='claimed')", (legacy,),
                 lambda value: {**value, 'source_status': 'ready'}, 'Ordinary claim is not native review')
    for changes in ({'plan_sha256': 'd'*64}, {'delivery_task': tid}, {'feature_tracker': 'fixture:t_wrong'}):
        changed_json('task_runs', 'metadata', 'task_id=?', (plan,),
                     lambda value, changes=changes: {**value, **changes}, 'Unrelated plan result')
    refused_unchanged(legacy_payload(scope='broader unrequested work'), 'Scope inflation')
    refused_unchanged(legacy_payload(stage='accepted'), 'Stage mismatch')
    refused_unchanged(legacy_payload(tracker='t_wrong'), 'Tracker mismatch')
    refused_unchanged(legacy_payload(expected_version='stale'), 'Scope CAS')
    git('checkout', '--detach', baseline)
    refused_unchanged(legacy_payload(), 'Accepted revision must actually be integrated')
    git('checkout', '--detach', second)
    preflight = subprocess.run(['/usr/bin/python3', '-B', str(root / 'scripts/review-verdict-guard.py')],
        input=json.dumps({'tool_name': 'kanban_complete', 'tool_input': {'board': 'fixture',
            'task_id': legacy_delivery, 'delivery': legacy_payload()}}),
        text=True, capture_output=True)
    assert preflight.returncode == 0, preflight.stderr
    assert json.loads(preflight.stdout) == {}, preflight.stdout
    okay(call('kanban_complete', task_id=legacy_delivery, summary='Legacy accepted scope integrated.',
              delivery=legacy_payload()))
    assert contract.load(db, legacy) is None
    assert not feature_flow.observe_features(db, 'fixture', int(time.time()) + 49 * 3600)
    print('PASS: exact legacy commissioning bridge and transactional negative evidence guards')

    # New native-review creates must never reproduce the prose/structured split. Fail before
    # any row is written through both the tool hook and direct native seam.
    for body in ('Workflow: native-review-v1', 'Feature tracker: ' + feature['tracker'],
                 'Feature handoff: delivery', 'Feature role: documentary-closure'):
        for workflow_input in ((None, {'version': 1}) if body.startswith('Workflow:') else ({'version': 1},)):
            db.commit(); before = list(db.iterdump())
            fields = {'body': body, **({'workflow': workflow_input} if workflow_input is not None else {})}
            assert 'error' in call('kanban_create', title='Invalid machine marker',
                                  assignee='standard-implementer', **fields)
            try:
                kb.create_task(db, title='Invalid direct machine marker', assignee='standard-implementer', **fields)
                raise AssertionError('Native create accepted an unstructured machine marker')
            except ValueError:
                pass
            assert list(db.iterdump()) == before
    # Real maintained feature-gap generators still use legacy CLI contracts,
    # including independent assessed_defer. They must not be disabled by the
    # new implementation-workflow guard.
    from deadlock_recovery import recovery_body
    for audit in (False, True):
        recovery_body_text = recovery_body('fixture', {'kind': 'feature-delivery-gap', 'task_id': tracker}, audit)
        legacy_controller = kb.create_task(db, title='Maintained legacy feature gap controller',
            assignee='project-auditor' if audit else 'head-coordinator', body=recovery_body_text,
            created_by='deadlock-recovery-monitor')
        assert contract.load(db, legacy_controller) is None
        assert kb.claim_task(db, legacy_controller)
        defer = {'feature_delivery': {'tracker': tracker, 'state': 'assessed_defer',
                                     'wake_condition': 'actual missing synthetic input'}}
        # Existing exact legacy metadata is retained, never promoted to delivery.
        assert contract.completion_metadata(db, legacy_controller, defer) == defer
        kb.complete_task(db, legacy_controller, summary='Legacy reconciliation result retained.', metadata=defer)
    # A delivery's newly commissioned implementation must carry the matching
    # immutable producer contract, even when it uses no readable markers.
    matching = {'version': 1, 'review': 'native-review-v1', 'plan_author': 'project-auditor',
                'feature': {**legacy_feature, 'role': 'producer'}}
    for workflow_input in (None, {'version': 1, 'review': 'native-review-v1', 'plan_author': 'project-auditor'},
                           {**matching, 'feature': {**matching['feature'], 'scope': 'unrelated'}},
                           {**matching, 'feature': {**matching['feature'], 'tracker': 'fixture:t_wrong'}},
                           {**matching, 'feature': {**matching['feature'], 'stage': 'accepted'}},
                           {**matching, 'plan_author': 'head-coordinator'}):
        db.commit(); before = list(db.iterdump())
        try:
            kb.create_task(db, title='Invalid commissioning', assignee='standard-implementer',
                           creator_task_id=legacy_delivery, workflow=workflow_input)
            raise AssertionError('Unmatched structured delivery commissioning accepted')
        except ValueError:
            pass
        assert list(db.iterdump()) == before
    db.commit(); before = list(db.iterdump())
    try:
        kb.create_task(db, title='Normalized implementer commissioning', assignee=' Standard-Implementer ',
                       creator_task_id=legacy_delivery)
        raise AssertionError('Normalized implementer bypassed commissioning')
    except ValueError:
        pass
    assert list(db.iterdump()) == before
    okay(call('kanban_create', title='Plain legacy diagnostic', assignee='standard-implementer',
              body='Goal: inspect a bounded diagnostic without machine markers.'))
    commissioned = kb.create_task(db, title='Matched producer contract', assignee='standard-implementer',
                                  creator_task_id=legacy_delivery, workflow=matching)
    assert contract.load(db, commissioned) == matching
    print('PASS: structured create enforcement and matched delivery commissioning')

    # The maintained completion transform must enforce actual delegation in the
    # native transaction. Synthetic PIDs record native spawn evidence without
    # starting a process, making a claim alone visibly insufficient.
    dispatch_hold = kb.create_task(db, title='Parallel dispatch original incident',
        assignee='standard-implementer', body='Input supplier: agent. Qualified input is missing.')
    assert kb.block_task(db, dispatch_hold, reason='Synthetic technical hold', kind='capability')
    dispatch_consumer = kb.create_task(db, title='Parallel dispatch gated consumer',
        assignee='standard-implementer', parents=[dispatch_hold])
    dispatch_owner = kb.create_task(db, title='Parallel dispatch supervision',
        assignee='head-coordinator', tenant='board-progress', created_by='board-progress-monitor',
        body='Goal: Delegate independent requested fixes.\nDispatch policy: parallel-v1',
        max_runtime_seconds=360, max_retries=1)
    assert kb.claim_task(db, dispatch_owner)
    independent = [kb.create_task(db, title='Independent dispatch slice ' + suffix,
        assignee='standard-implementer', creator_task_id=dispatch_owner) for suffix in ('A', 'B')]
    dispatch_metadata = {'board_progress': {'dispatched_task_ids': independent}}

    def reject_dispatch_completion(metadata):
        db.commit()
        before = list(db.iterdump())
        for complete in (
            lambda: contract.completion_metadata(db, dispatch_owner, metadata),
            lambda: kb.complete_task(db, dispatch_owner, summary='Delegation needs native starts.', metadata=metadata),
        ):
            try:
                complete()
                raise AssertionError('Queued, partial or omitted delegation evidence completed supervision')
            except ValueError:
                pass
            assert list(db.iterdump()) == before, 'Refused dispatch completion must be transactional'

    reject_dispatch_completion(None)
    reject_dispatch_completion(dispatch_metadata)
    for task_id in independent:
        assert kb.claim_task(db, task_id)
    reject_dispatch_completion(dispatch_metadata)
    dispatch._set_worker_pid(db, independent[0], 99999991)
    reject_dispatch_completion(dispatch_metadata)
    dispatch._set_worker_pid(db, independent[1], 99999992)
    assert contract.completion_metadata(db, dispatch_owner, dispatch_metadata) == dispatch_metadata
    assert kb.complete_task(db, dispatch_owner, summary='Both independent workers started.', metadata=dispatch_metadata)
    assert kb.get_task(db, dispatch_hold).status == 'blocked'
    assert kb.get_task(db, dispatch_consumer).status == 'todo'
    assert [(row['parent_id'], row['child_id']) for row in db.execute(
        'SELECT parent_id,child_id FROM task_links WHERE child_id=?', (dispatch_consumer,))] == [
            (dispatch_hold, dispatch_consumer)]
    for task_id in independent:
        assert db.execute("SELECT 1 FROM task_events WHERE task_id=? AND kind='spawned'", (task_id,)).fetchone()
    print('PASS: native parallel dispatch refuses queued/partial evidence and retains original gates')

    continuation = kb.create_task(db, title='Bounded scheduled dispatch continuation',
        assignee='head-coordinator', tenant='board-progress', created_by='board-progress-monitor',
        body='Goal: Wait for independently dispatched native starts.\nDispatch policy: parallel-v1',
        max_runtime_seconds=360, max_retries=1)
    assert kb.claim_task(db, continuation)
    continuing_workers = [kb.create_task(db, title='Continuation slice ' + suffix,
        assignee='standard-implementer', creator_task_id=continuation) for suffix in ('A', 'B')]
    continuing_receipt = {'board_progress': {'dispatched_task_ids': continuing_workers}}
    wait_reason = 'Dispatch wait: ' + json.dumps(continuing_receipt['board_progress'])
    assert kb.schedule_task(db, continuation, reason=wait_reason)
    assert kb.get_task(db, continuation).current_run_id is None

    def reject_continuation():
        db.commit()
        before = list(db.iterdump())
        try:
            kb.unblock_task(db, continuation)
            raise AssertionError('Unqualified scheduled dispatch continuation was released')
        except ValueError:
            pass
        assert list(db.iterdump()) == before, 'Continuation refusal must preserve counters and existing gates'

    reject_continuation()
    for task_id in continuing_workers:
        assert kb.claim_task(db, task_id)
    dispatch._set_worker_pid(db, continuing_workers[0], 99999993)
    reject_continuation()
    dispatch._set_worker_pid(db, continuing_workers[1], 99999994)
    for field, value in [('block_kind', 'capability'), ('block_kind', 'needs_input'),
                         ('consecutive_failures', 1), ('block_recurrences', 1)]:
        db.execute(f'UPDATE tasks SET {field}=? WHERE id=?', (value, continuation))
        db.commit()
        reject_continuation()
        db.execute('UPDATE tasks SET block_kind=NULL,consecutive_failures=0,block_recurrences=0 WHERE id=?',
                   (continuation,))
        db.commit()
    assert kb.unblock_task(db, continuation)
    assert kb.get_task(db, continuation).status == 'ready'
    reject_continuation()  # The same owner gets one continuation, never another retry budget.
    assert kb.claim_task(db, continuation)
    assert kb.complete_task(db, continuation, summary='Qualified continuation observed both starts.',
                            metadata=continuing_receipt)
    assert kb.get_task(db, dispatch_hold).status == 'blocked'
    assert kb.get_task(db, dispatch_consumer).status == 'todo'
    assert db.execute("SELECT count(*) FROM task_events WHERE task_id=? AND kind='unblocked'",
                      (continuation,)).fetchone()[0] == 1
    assert db.execute('SELECT consecutive_failures,block_recurrences FROM tasks WHERE id=?',
                      (continuation,)).fetchone()[:] == (0, 0)
    print('PASS: native scheduled dispatch continuation is single-use and preserves typed/failed holds')

    recovery=okay(call('kanban_create',title='Interrupted recovery fixture',assignee='standard-implementer',
        body='Recovery mode: evidence-only',max_runtime_seconds=300,
        workflow={'version':1},workspace_kind='dir',workspace_path=str(work)))['task_id']
    claim=kb.claim_task(db,recovery)
    assert dispatch._record_task_failure(db,recovery,'Synthetic interruption',outcome='timed_out',
        release_claim=True,end_run=True)
    try:
        kb.unblock_task(db,recovery)
        raise AssertionError('Unchanged interrupted recovery was rearmed')
    except ValueError:
        pass
    assert kb.get_task(db,recovery).consecutive_failures==1

    # A failed dispatch supervisor uses the existing exact-version technical
    # recovery path. Ordinary unblock must never consume/reset its allowance,
    # while the guarded API retains its native actor/process authentication.
    from hermes_cli import nixhomeserver_resume_recovered as guarded_resume
    from cron import nixhomeserver_capability_recovery as capability
    failed_supervisor = kb.create_task(db, title='Failed marked dispatch supervisor',
        assignee='head-coordinator', tenant='board-progress', created_by='board-progress-monitor',
        body='Goal: inspect bounded dispatch evidence.\nRecovery mode: evidence-only\nDispatch policy: parallel-v1',
        max_runtime_seconds=360, max_retries=1, workspace_kind='dir', workspace_path=str(work))
    assert kb.claim_task(db, failed_supervisor)
    assert dispatch._record_task_failure(db, failed_supervisor, 'Synthetic timed-out bounded inspection',
        outcome='timed_out', release_claim=True, end_run=True)
    assert kb.block_task(db, failed_supervisor, reason='Input supplier: agent. Bounded input has now been repaired.',
                         kind='capability')
    failed_run = db.execute('SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                           (failed_supervisor,)).fetchone()[0]
    kb.add_comment(db, failed_supervisor, author='head-coordinator',
        body=f'Recovery run: {failed_run}\nRecovery change: The synthetic qualified input is now available.\n'
             'Recovery action: Inspect only that input within the unchanged bounded allowance.')
    before_failed = dict(db.execute('SELECT * FROM tasks WHERE id=?', (failed_supervisor,)).fetchone())
    assert before_failed['consecutive_failures'] == 1 and before_failed['block_kind'] == 'capability'
    try:
        kb.unblock_task(db, failed_supervisor)
        raise AssertionError('Ordinary unblock released a typed failed supervision task')
    except ValueError:
        pass
    assert dict(db.execute('SELECT * FROM tasks WHERE id=?', (failed_supervisor,)).fetchone()) == before_failed

    actor = kb.create_task(db, title='Authenticated fixture recovery coordinator', assignee='head-coordinator',
        workspace_kind='dir', workspace_path=str(work), max_runtime_seconds=360, max_retries=1)
    assert kb.claim_task(db, actor)
    dispatch._set_worker_pid(db, actor, os.getpid())
    actor_row = db.execute('SELECT current_run_id,claim_lock FROM tasks WHERE id=?', (actor,)).fetchone()
    actor_env = {'HERMES_KANBAN_TASK': actor, 'HERMES_KANBAN_RUN_ID': str(actor_row['current_run_id']),
                 'HERMES_KANBAN_BOARD': 'fixture', 'HERMES_KANBAN_DB': str(kb.kanban_db_path('fixture')),
                 'HERMES_KANBAN_WORKSPACE': str(work), 'HERMES_PROFILE': 'head-coordinator',
                 'HERMES_KANBAN_CLAIM_LOCK': actor_row['claim_lock']}
    with patch.dict(os.environ, actor_env):
        assert guarded_resume.coordinator_origin()['task_id'] == actor
        hold = next(item for item in capability.read_board(db, root, 'fixture', capability.helper_identity(root))
                    if item['task_id'] == failed_supervisor)
        try:
            guarded_resume.resume_recovered(kb, db, failed_supervisor, '0' * 64,
                'A stale version cannot release the repaired supervision task.')
            raise AssertionError('Guarded technical recovery accepted stale version')
        except ValueError:
            pass
        result = guarded_resume.resume_recovered(kb, db, failed_supervisor, hold['version'],
            'Qualified changed input recorded; continue only the exact bounded inspection.')
        assert result['applied'] and result['actor_task'] == actor
    assert dict(db.execute('SELECT * FROM tasks WHERE id=?', (failed_supervisor,)).fetchone()) == {
        **before_failed, 'status': 'ready'}
    assert kb.get_task(db, dispatch_hold).status == 'blocked'
    assert kb.get_task(db, dispatch_consumer).status == 'todo'
    print('PASS: typed failed dispatch supervisor retains exact-version authenticated technical recovery')

    print('PASS: installed tools/hooks dispatch, handoff, rejection/rework, independent acceptance, GC authority, transactional scope CAS, delivery and interrupted recovery')
finally:
    db.close()
