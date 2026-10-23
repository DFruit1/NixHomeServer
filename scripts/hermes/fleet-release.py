#!/usr/bin/env python3
"""Plan, install, check and roll back a coherent Hermes fleet release.

Python installer glue composes existing tracked policy transforms. Native Hermes
and its reviewed recovery adapters remain dependencies, fingerprinted separately.
No credentials, board databases or whole cron journals are restored.
"""
import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import subprocess
import sys
import time

from hermes_common import atomic_write

HERE = Path(__file__).resolve().parent
NAME = 'hermes fleet supervisor'
JOBS = {
    ('default', 'kanban retry breaker'): ('retry-breaker', 900),
    ('default', 'kanban technical recovery'): ('technical-recovery', 300),
    ('default', 'kanban aging escalation'): ('aging', 21600),
    ('default', 'cron loop escalation'): ('cron-loops', 3600),
    ('default', 'kanban review taskforce'): ('proactive-intake', 3600),
    ('head-coordinator', 'kanban board health'): ('board-health', 1800),
    ('head-coordinator', 'kanban idle recovery'): ('idle-state', 900),
    ('board-steward', 'steward opportunity scan'): (None, 7200),
    ('board-steward', 'steward stall follow-up'): (None, 14400),
}


def checked(root, path):
    root, path = root.absolute(), path.absolute()
    if not path.is_relative_to(root) or '..' in path.relative_to(root).parts:
        raise ValueError('Release path leaves its fleet root')
    for part in (path, *path.parents):
        if part.is_relative_to(root) and part.is_symlink():
            raise ValueError('Release paths must not contain symlinks')
    return path


def sha(value):
    return hashlib.sha256(value).hexdigest()


def read(path):
    return path.read_bytes() if path.exists() else None


def journal(root, revision):
    if not re.fullmatch(r'[a-f0-9]{40}|[a-f0-9]{64}', revision):
        raise ValueError('Release identity must be a full source revision')
    return checked(root, root / 'state/fleet/releases' / revision / 'manifest.json')


def install_files(root, pending, revision, *, source=None, context=None, preimages=None):
    """Preflight every target, then retain pre/postimages before the first write."""
    manifest_path = journal(root, revision)
    if manifest_path.exists():
        raise ValueError('This release already has a journal; check or roll it back before retry')
    records = []
    def install_order(item):
        path=item[0]
        # Publish dependencies before native entrypoints can reference them.
        return (path.name in {'kanban_db.py','kanban_db_dispatch.py','kanban_tools.py',
                            'kanban_tools_schemas.py','kanban_stop.py'}, str(path))
    for path, text in sorted(pending.items(), key=install_order):
        path = checked(root, path)
        relative = path.relative_to(root)
        if ('.env' in relative.parts or 'kanban' in relative.parts or 'cron' in relative.parts
                or path.name.endswith(('.db', '.age'))):
            raise ValueError('Release files cannot include credentials, boards or cron journals')
        if path.suffix == '.py':
            compile(text, str(relative), 'exec')
        before = read(path)
        before_mode = path.stat().st_mode & 0o777 if before is not None else None
        if preimages is not None and preimages.get(str(relative)) != {
                'sha256':sha(before) if before is not None else None,'mode':before_mode}:
            raise ValueError('Reviewed release input changed: ' + str(relative))
        records.append(dict(path=str(relative), before_sha256=sha(before) if before is not None else None,
                            after_sha256=sha(text.encode()), mode=before_mode if before_mode is not None else 0o600,
                            before=before, after=text))
    manifest_path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    manifest = dict(schema_version=1, revision=revision, source=str(source) if source else None,
                    status='applying', created_at=int(time.time()), files=[])
    manifest.update(context or {})
    for index, record in enumerate(records):
        entry = {k:v for k,v in record.items() if k not in {'before','after'}}
        entry['preimage'] = str(index) + '.before' if record['before'] is not None else None
        if record['before'] is not None:
            backup = checked(root, manifest_path.parent / entry['preimage'])
            fd = os.open(backup, os.O_CREAT | os.O_EXCL | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
            with os.fdopen(fd, 'wb') as stream:
                stream.write(record['before']); stream.flush(); os.fsync(stream.fileno())
        manifest['files'].append(entry)
    atomic_write(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + '\n', mode=0o600)
    for record in records:
        path = checked(root, root / record['path'])
        if (read(path) != record['before']
                or (record['before'] is not None and path.stat().st_mode & 0o777 != record['mode'])):
            raise ValueError('Release input changed: ' + record['path'])
        if record['before'] != record['after'].encode():
            atomic_write(path, record['after'], mode=record['mode'])
    manifest['status'] = 'files-installed'
    atomic_write(manifest_path, json.dumps(manifest, indent=2, sort_keys=True) + '\n', mode=0o600)
    if check_files(root, revision):
        raise ValueError('Installed release readback differs')
    return manifest


def check_files(root, revision, *, dependencies=True):
    manifest = json.loads(journal(root, revision).read_text())
    drift = []
    for item in manifest['files']:
        path = checked(root, root / item['path'])
        value = read(path)
        if (value is None or sha(value) != item['after_sha256']
                or path.stat().st_mode & 0o777 != item['mode']):
            drift.append(item['path'])
    for relative,expected in (manifest.get('dependencies',{}) if dependencies else {}).items():
        value=read(checked(root,root/relative))
        if (sha(value) if value is not None else None)!=expected:
            drift.append('dependency:'+relative)
    return drift


def runtime_dependencies(root):
    relatives=['scripts/deadlock_recovery.py','scripts/feature_flow.py',
               'scripts/capability_recovery.py','scripts/worker_origin.py','scripts/autonomy-policy.py',
               'scripts/cron_sweep.py','scripts/kanban-retry-breaker.sh',
               'scripts/kanban-aging-escalation.py','scripts/cron-loop-monitor.py',
               'hermes-agent/hermes_cli/kanban_db.py','hermes-agent/hermes_cli/kanban_db_dispatch.py',
               'hermes-agent/tools/kanban_tools.py','hermes-agent/tools/kanban_tools_schemas.py']
    relatives += [str(p.relative_to(root)) for pattern in
                  ('hermes-agent/hermes_cli/nixhomeserver_*.py','hermes-agent/cron/nixhomeserver_*.py')
                  for p in root.glob(pattern)]
    return {relative:sha(value) if value is not None else None
            for relative in sorted(set(relatives))
            for value in [read(checked(root,root/relative))]}


def rollback_files(root, revision, *, dry_run=False):
    path = journal(root, revision)
    manifest = json.loads(path.read_text())
    changes = []
    for item in manifest['files']:
        target = checked(root, root / item['path'])
        actual = read(target)
        identity = sha(actual) if actual is not None else None
        if actual is not None and target.stat().st_mode & 0o777 != item['mode']:
            raise ValueError('Rollback preserves another writer mode change: ' + item['path'])
        if identity == item['before_sha256']:
            continue
        if identity != item['after_sha256'] or target.stat().st_mode & 0o777 != item['mode']:
            raise ValueError('Rollback preserves another writer: ' + item['path'])
        old = read(checked(root, path.parent / item['preimage'])) if item['preimage'] else None
        if (sha(old) if old is not None else None) != item['before_sha256']:
            raise ValueError('Rollback preimage failed verification')
        changes.append((target, old, item['mode']))
    if dry_run:
        return
    for target, old, mode in reversed(changes):
        if old is None:
            target.unlink()
        else:
            atomic_write(target, old.decode(), mode=mode)
    manifest['status'] = 'rolled-back'
    atomic_write(path, json.dumps(manifest, indent=2, sort_keys=True) + '\n', mode=0o600)


def require_rollback_compatibility(root, manifest):
    previous=manifest.get('previous_release') or {}
    supported=[]
    if previous.get('revision'):
        old=json.loads(journal(root,previous['revision']).read_text())
        supported=old.get('workflow_versions',[])
    for path in sorted((root/'kanban/boards').glob('*/kanban.db')):
        with sqlite3.connect(path.as_uri()+'?mode=ro',uri=True,timeout=2) as db:
            db.execute('PRAGMA query_only=ON')
            rows=db.execute("SELECT DISTINCT json_extract(payload,'$.workflow.version') FROM task_events "
                            "WHERE kind='created' AND json_type(payload,'$.workflow') IS NOT NULL LIMIT 32").fetchall()
            if any(type(row[0]) is not int or row[0] not in supported for row in rows):
                raise ValueError('Rollback would remove a reader for existing workflow contracts; install a compatible reviewed release')


def jobs(root, profile):
    home = root if profile == 'default' else root / 'profiles' / profile
    path = checked(root, home / 'cron/jobs.json')
    if not path.exists():
        return []
    data = json.loads(path.read_text())
    return data if isinstance(data, list) else data['jobs']


def active(job):
    return bool(job.get('enabled', True)) and not job.get('paused_at') and job.get('state') != 'paused'


def owned(job):
    return {**{k:job.get(k) for k in ('script','no_agent','deliver','schedule','monitor_script')},
            'enabled':active(job), 'paused_at':job.get('paused_at') if not active(job) else None}


def current_job(root, item):
    matches=[j for j in jobs(root,item['profile']) if j['id']==item['id']]
    if len(matches)!=1:
        raise ValueError('Owned native schedule is missing or ambiguous')
    return matches[0]


def schedule_plan(root):
    policy = checked(root, root / 'state/fleet/handlers.json')
    handlers = json.loads(policy.read_text()) if policy.exists() else {'evidence': {'enabled': True, 'interval': 300}}
    result = dict(pause=[], daily=None, supervisor=None, handlers=handlers)
    for profile in ('default', 'head-coordinator', 'board-steward'):
        names = {}
        for job in jobs(root, profile):
            key = (profile, job.get('name'))
            is_owned = key in JOBS or key == ('board-steward','hermes daily steward') or key == ('default',NAME)
            if not is_owned:
                continue
            if key in names:
                raise ValueError('Duplicate owned schedule: ' + str(key))
            names[key] = job
            record = dict(profile=profile, id=job['id'], before=owned(job))
            if key == ('default', NAME):
                if (job.get('script')!='fleet-supervisor.py' or job.get('no_agent') is not True
                        or job.get('deliver')!='local' or job.get('monitor_script')
                        or job.get('schedule',{}).get('minutes')!=5):
                    raise ValueError('Existing supervisor definition differs; reconcile it before installation')
                result['supervisor'] = record
            elif key == ('board-steward','hermes daily steward'):
                result['daily'] = record
            else:
                result['pause'].append(record)
                handler, interval = JOBS[key]
                if handler and handler not in handlers:
                    minutes = (job.get('schedule') or {}).get('minutes')
                    handlers[handler] = dict(enabled=active(job), interval=minutes * 60 if type(minutes) is int and minutes > 0 else interval)
    return result


def cron(root, profile, *args):
    subprocess.run(['hermes', '--profile', profile, 'cron', *args], check=True,
                   timeout=60, capture_output=True, text=True,
                   env=dict(os.environ, HERMES_HOME=str(root), HERMES_ROOT=str(root)))


def schedule_snapshot(root, plan):
    for item in [*plan['pause'], plan.get('daily'), plan.get('supervisor')]:
        if item is None:
            continue
        item.setdefault('after',owned(current_job(root,item)))


def mutate_schedule(root, item, arguments, changes, checkpoint):
    expected=item.get('after',item['before'])
    if owned(current_job(root,item))!=expected:
        raise ValueError('Schedule changed since preflight: '+item['id'])
    item['intent']=dict(before=expected,changes=changes,operation=arguments[0])
    checkpoint()  # A successful native mutation remains recoverable if its reply is lost.
    cron(root,item['profile'],*arguments)
    actual=owned(current_job(root,item))
    desired={**expected,**changes}
    # Native pause assigns its own timestamp; all other owned fields must match.
    if changes.get('enabled') is False:
        desired['paused_at']=actual['paused_at']
    if actual!=desired:
        raise ValueError('Native schedule readback differs from the exact requested change')
    item['after']=actual
    item.pop('intent',None)
    checkpoint()


def apply_schedules(root, plan, *, checkpoint=lambda:None):
    # The new schedule stays paused until every old owner has stopped scheduling.
    supervisor = plan['supervisor']
    if supervisor is None:
        plan['creation_intent'] = {'name': NAME, 'profile': 'default'}
        checkpoint()
        cron(root, 'default', 'create', 'every 5m', '--name', NAME, '--script', 'fleet-supervisor.py',
             '--no-agent', '--deliver', 'local', '--paused', '--paused-reason', 'Fleet release migration')
        matches = [j for j in jobs(root,'default') if j.get('name') == NAME]
        if len(matches) != 1:
            raise ValueError('Supervisor creation needs unambiguous native readback')
        supervisor = plan['supervisor'] = dict(profile='default', id=matches[0]['id'], before=None,
                                              after=owned(matches[0]))
        plan.pop('creation_intent')
        checkpoint()
    else:
        if owned(current_job(root,supervisor))!=supervisor['before']:
            raise ValueError('Supervisor changed since preflight')
        supervisor['after']=supervisor['before']
    for item in plan['pause']:
        if active(item['before']):
            mutate_schedule(root,item,['pause',item['id']],{'enabled':False},checkpoint)
    if plan['daily']:
        item = plan['daily']
        mutate_schedule(root,item,['edit',item['id'],'--script','fleet-report.py','--no-agent'],
                        {'script':'fleet-report.py','no_agent':True},checkpoint)
    if supervisor['before'] is None:
        # Creation checkpoint recorded its paused preimage. Enable only this new
        # schedule; a previously paused supervisor remains deliberately paused.
        mutate_schedule(root,supervisor,['resume',supervisor['id']],
                        {'enabled':True,'paused_at':None},checkpoint)
    errors = check_schedules(root, plan)
    if errors:
        raise ValueError('Schedule readback differs: ' + ', '.join(errors))


def check_schedules(root, plan):
    errors = []
    for item in plan['pause']:
        current = next((j for j in jobs(root,item['profile']) if j['id']==item['id']), None)
        if current is None or active(current):
            errors.append(item['id'])
    if plan.get('supervisor'):
        current = next((j for j in jobs(root,'default') if j['id']==plan['supervisor']['id']), None)
        should_run=plan['supervisor']['before'] is None or active(plan['supervisor']['before'])
        if (current is None or active(current)!=should_run or not current.get('no_agent')
                or current.get('script') != 'fleet-supervisor.py' or current.get('schedule',{}).get('minutes') != 5):
            errors.append('supervisor')
    if plan['daily']:
        item = plan['daily']
        current = next((j for j in jobs(root,item['profile']) if j['id']==item['id']), None)
        if (current is None or current.get('script') != 'fleet-report.py' or not current.get('no_agent')
                or current.get('deliver') != item['before']['deliver']
                or current.get('schedule') != item['before']['schedule']):
            errors.append('daily-report')
    return errors


def restore_schedules(root, plan, *, checkpoint=lambda:None):
    # Compare all owned fields first, before pausing/resuming any job. Scheduler
    # run counters, outputs and next-run timestamps are intentionally unowned.
    if plan.get('creation_intent'):
        matches = [j for j in jobs(root,'default') if j.get('name') == NAME]
        if len(matches)>1:
            raise ValueError('Interrupted supervisor creation is ambiguous')
        if matches:
            job=matches[0]
            if (active(job) or job.get('script')!='fleet-supervisor.py'
                    or job.get('no_agent') is not True or job.get('deliver')!='local'
                    or job.get('monitor_script') or job.get('schedule',{}).get('minutes')!=5):
                raise ValueError('Interrupted supervisor creation has an unexpected poststate')
            plan['supervisor']=dict(profile='default',id=job['id'],before=None,after=owned(job),
                                    execution_observation='Paused native creation observed; completion reply unavailable')
        plan.pop('creation_intent')
        checkpoint()
    for item in [*plan['pause'], plan.get('daily'), plan.get('supervisor')]:
        if item and item.get('intent'):
            intent=item['intent'];actual=owned(current_job(root,item))
            desired={**intent['before'],**intent['changes']}
            if intent['changes'].get('enabled') is False:desired['paused_at']=actual['paused_at']
            if actual not in (intent['before'],desired):
                raise ValueError('Interrupted native mutation has an unexpected poststate')
            item['after']=actual
            item['execution_observation']='Intended native poststate observed; historical completion reply unavailable'
            item.pop('intent')
            checkpoint()
        if not item or not item.get('after'):
            continue
        actual=owned(current_job(root,item))
        if actual not in (item['after'],item.get('restored'),item['before']):
            if item is plan.get('supervisor') and item['before'] is None and not actual['enabled']:
                expected={**item['after'],'enabled':False,'paused_at':actual['paused_at']}
                if actual==expected:continue
            raise ValueError('Rollback preserves another schedule writer: '+item['id'])
    if (plan.get('supervisor') and plan['supervisor']['before'] is None
            and active(current_job(root,plan['supervisor']))):
        cron(root, 'default', 'pause', plan['supervisor']['id'])
        plan['supervisor']['restored']=owned(current_job(root,plan['supervisor']))
        checkpoint()
    # Restore only owned changes. Never restore a jobs.json snapshot or erase history.
    if plan.get('daily'):
        item = plan['daily']; before = item['before']
        if owned(current_job(root,item))==before:
            item['restored']=before
        else:
            current = current_job(root,item)
            if current.get('script') not in {before['script'], 'fleet-report.py'}:
                raise ValueError('Daily schedule changed by another writer; reconcile before rollback')
            cron(root, item['profile'], 'edit', item['id'], '--script', before['script'] or '',
                 '--no-agent' if before['no_agent'] else '--agent')
            item['restored']=owned(current_job(root,item));checkpoint()
    for item in plan['pause']:
        if active(item['before']) and owned(current_job(root,item))!=item['before']:
            cron(root, item['profile'], 'resume', item['id'])
            item['restored']=owned(current_job(root,item));checkpoint()


def source_changes(root, directory, *, workers=False):
    """Upgrade transforms use their source helpers, never cached installed ones."""
    names=('hermes_common','hermes_config') + (('worker_runtime_adapter','fleet_runtime_adapter',
        'coordinator_repair_adapter','recovered_resume_adapter','resume_recovered') if workers else ())
    previous={name:sys.modules.get(name) for name in names}
    previous_path=sys.path[:]
    try:
        sys.path.insert(0,str(directory))
        for name in names:
            spec=importlib.util.spec_from_file_location(name,directory/(name+'.py'))
            module=importlib.util.module_from_spec(spec)
            sys.modules[name]=module
            spec.loader.exec_module(module)
        spec=importlib.util.spec_from_file_location('fleet_taskforce_install',directory/'install-review-taskforce.py')
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        pending = installer.changed_files(root)
        if workers:
            spec = importlib.util.spec_from_file_location('fleet_worker_install', directory/'install-worker-policy.py')
            worker = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(worker)
            pending = worker.pending_files(root, pending)
            # These seams are already fleet-owned. Compose their reviewed
            # migration here rather than making the separate API installer
            # invalidate the active release's immutable file manifest.
            spec=importlib.util.spec_from_file_location('fleet_recovery_install',directory/'install-recovered-resume.py')
            recovery=importlib.util.module_from_spec(spec);spec.loader.exec_module(recovery)
            _,recovery_pending,_=recovery.pending_files(root)
            owned={'tools/kanban_tools.py','tools/kanban_tools_schemas.py',
                   'hermes_cli/nixhomeserver_coordinator_repair.py'}
            for path,before,after in recovery_pending:
                relative=str(path.relative_to(root/'hermes-agent'))
                if relative in owned:
                    # Compose on worker/workflow output, not the earlier input.
                    pending[path]=(sys.modules['coordinator_repair_adapter'].adapt(relative,pending[path])
                                   if path in pending else after)
                elif before!=after:
                    raise ValueError('Install the matching reviewed recovery prerequisites first: '+relative)
        return pending
    finally:
        sys.path[:]=previous_path
        for name,module in previous.items():
            if module is None:sys.modules.pop(name,None)
            else:sys.modules[name]=module


def merge_owned(pending, owners, changes, owner, *, compose=False):
    for path, value in changes.items():
        previous = owners.get(path, [])
        if path in pending and pending[path] != value and previous and previous != ['retained-legacy']:
            if not compose or (path.name not in {'SOUL.md', 'config.yaml'}):
                raise ValueError('Conflicting release file owners: ' + str(path))
        pending[path] = value
        owners[path] = sorted(set(previous) | {owner})


def pending_files(root, source, plan, *, owners=None):
    directory = source / 'scripts/hermes'
    pending = {}
    owners = {} if owners is None else owners
    current_path = root/'state/fleet/current.json'
    if current_path.exists():
        previous = json.loads(current_path.read_text())
        if previous.get('status') == 'active':
            if check_files(root,previous['revision'],dependencies=False):
                raise ValueError('Reconcile installed release drift before replacing it')
            manifest=json.loads(journal(root,previous['revision']).read_text())
            pending.update({root/item['path']:(root/item['path']).read_text() for item in manifest['files']})
            owners.update({p:['retained-legacy'] for p in pending})
    merge_owned(pending,owners,source_changes(root,directory,workers=True),'fleet-runtime')
    # These helpers previously needed a separate interactive files-only update.
    # They now share the release's preimage, readback and rollback transaction.
    for name in ('deadlock_recovery.py', 'feature_flow.py', 'capability_recovery.py',
                 'feature_contract.py', 'fleet_contract.py'):
        merge_owned(pending,owners,{root/'scripts'/name:(directory/name).read_text()},'recovery')
    for name in ('fleet-release.py','fleet-evidence.py','fleet-supervisor.py','fleet-report.py','kanban-analytics.py',
                 'fleet_workflow.py','idle-recovery-monitor.py','kanban-board-health.sh'):
        merge_owned(pending,owners,{root/'scripts'/name:(directory/name).read_text()},'fleet-runtime')
    merge_owned(pending,owners,{
        root/'profiles/board-steward/scripts/fleet-report.py':(directory/'fleet-report.py').read_text(),
        root/'state/fleet/handlers.json':json.dumps(plan['handlers'], sort_keys=True, indent=2) + '\n'},'fleet-runtime')
    return pending


def source_revision(source, *, clean=False):
    revision = subprocess.check_output(['git','-C',str(source),'rev-parse','HEAD'], text=True).strip()
    if clean and subprocess.check_output(['git','-C',str(source),'status','--porcelain','--untracked-files=all']):
        raise ValueError('Fleet installation requires clean committed source')
    return revision


def require_authority(root, args, revision, source_id, source):
    """Reuse native actor proof and independent operation review, without unpinning."""
    pinned=any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID',
                                          'HERMES_DELEGATED_CHILD_CONTEXT'))
    if not pinned:
        return {'kind':'interactive-operator'}
    if os.environ.get('HERMES_DELEGATED_CHILD_CONTEXT') or not args.review_card:
        raise ValueError('A native coordinator needs the exact independent fleet-release review')
    def load(name,filename):
        path=checked(root,root/'scripts'/filename)
        spec=importlib.util.spec_from_file_location(name,path)
        module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
        return module
    origin=load('fleet_native_origin','worker_origin.py')
    actor=origin.authenticated_current_origin(root,expected_profile='head-coordinator',expected_workspace=source)
    if not isinstance(actor,dict) or actor.get('profile')!='head-coordinator':
        raise ValueError('Actual native coordinator execution is required')
    if not re.fullmatch(r't_[A-Za-z0-9_]+',args.review_card) or args.review_card==actor.get('task_id'):
        raise ValueError('Name a different independent verification card')
    autonomy=load('fleet_native_autonomy','autonomy-policy.py')
    with autonomy._board(root,actor['board']) as db:
        autonomy._delegated_review(db,dict(task_id=actor['task_id'],executor='head-coordinator',sha256=revision),
                                   dict(review_task_id=args.review_card))
        accepted=autonomy._accepted_review(db,args.review_card,'head-coordinator')
    if (accepted.get('revision')!=revision or accepted.get('source_revision')!=source_id
            or accepted.get('installation_scope')!=['hermes-fleet']
            or accepted.get('fleet_action')!=args.action
            or accepted.get('operation_scope')!=dict(request_sha256=revision,executor='head-coordinator',risk_classes=[])
            or accepted.get('independence')!={'plan_author':False,'implementer':False}):
        raise ValueError('Independent acceptance must bind this release/action/source and no reserved effects')
    return dict(kind='native-coordinator',actor=actor,review_card=args.review_card)


@contextmanager
def mutation_locks(root):
    descriptors=[]
    try:
        for relative in ('state/fleet/release.lock','state/fleet/supervisor.lock',
                         'backups/recovered-resume/install.lock'):
            # Hold the owning API installer's lock from qualification through
            # fingerprint capture and publication; it cannot replace a guard
            # and have its new bytes adopted as an unqualified baseline.
            path=checked(root,root/relative)
            path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
            fd=os.open(path,os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
            descriptors.append(fd)
            fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
        yield
    finally:
        for fd in reversed(descriptors):os.close(fd)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=('plan','apply','check','status','rollback'))
    parser.add_argument('--source', type=Path)
    parser.add_argument('--revision')
    parser.add_argument('--review-card')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))).absolute()
    if args.action in {'apply','rollback'}:
        with mutation_locks(root):
            return operate(args,root)
    return operate(args,root)


def operate(args,root):
    state = checked(root,root/'state/fleet/current.json')
    current = json.loads(state.read_text()) if state.exists() else None
    if args.action in {'check','status','rollback'}:
        revision = args.revision or (current or {}).get('revision')
        if not revision:
            raise ValueError('No recorded fleet release')
        manifest_path = journal(root,revision)
        manifest = json.loads(manifest_path.read_text())
        if args.action == 'rollback':
            require_authority(root,args,revision,manifest.get('source_revision'),Path(manifest.get('source') or ''))
            require_rollback_compatibility(root,manifest)
            # Preflight file conflicts before modifying any schedules.
            rollback_files(root,revision,dry_run=True)
            if manifest.get('schedule'):
                def rollback_checkpoint():
                    atomic_write(manifest_path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
                restore_schedules(root,manifest['schedule'],checkpoint=rollback_checkpoint)
            rollback_files(root,revision)
            supervisor=(manifest.get('schedule') or {}).get('supervisor')
            if supervisor and supervisor.get('before') and active(supervisor['before']):
                cron(root,'default','resume',supervisor['id'])
            previous=manifest.get('previous_release')
            atomic_write(state,json.dumps(previous or {'revision':revision,'status':'rolled-back'})+'\n',mode=0o600)
            return 0
        drift = check_files(root,revision)
        schedules = check_schedules(root,manifest['schedule']) if manifest.get('schedule') else []
        print(json.dumps(dict(revision=revision,status=manifest['status'],file_drift=drift,
                              schedule_drift=schedules,runtime='Existing sessions may retain prior prompts; refresh at idle.'),sort_keys=True))
        return int(bool(drift or schedules or manifest['status']!='active'))
    source = args.source
    if source is None and current and current.get('status')=='active':
        recorded=json.loads(journal(root,current['revision']).read_text()).get('source')
        source=Path(recorded) if recorded else None
    source = (source or HERE.parents[1]).resolve()
    source_id = source_revision(source, clean=args.action=='apply')
    plan = schedule_plan(root)
    owners = {}
    pending = pending_files(root,source,plan,owners=owners)
    dependencies=runtime_dependencies(root)
    # Dependencies are retained rather than overwritten; omit any file whose
    # new bytes this package itself owns from the baseline dependency set.
    dependencies={p:h for p,h in dependencies.items() if root/p not in pending}
    ownership={str(p.relative_to(root)):owner for p,owner in sorted(owners.items())}
    content=dict(source_revision=source_id,dependencies=dependencies,ownership=ownership,
                  files={str(p.relative_to(root)):sha(t.encode()) for p,t in sorted(pending.items())})
    content_id=sha(json.dumps(content,sort_keys=True).encode())
    preimages={str(p.relative_to(root)):{'sha256':sha(value) if value is not None else None,
                                       'mode':p.stat().st_mode & 0o777 if value is not None else None}
               for p in pending for value in [read(checked(root,p))]}
    identity=dict(content_id=content_id,action='apply',schedules=plan,preimages=preimages)
    revision=sha(json.dumps(identity,sort_keys=True).encode())
    for path,text in pending.items():
        checked(root,path)
        if path.suffix=='.py':compile(text,str(path),'exec')
    if args.action=='plan':
        print(json.dumps(dict(revision=revision,source_revision=source_id,files=[str(p.relative_to(root)) for p in pending],
                              file_owners=ownership,schedules=plan),indent=2,sort_keys=True))
        return 0
    if current and current.get('status')=='active':
        installed=json.loads(journal(root,current['revision']).read_text())
        if installed.get('content_id')==content_id:
            if check_files(root,current['revision']) or check_schedules(root,installed['schedule']):
                raise ValueError('Existing release has drift; reconcile it before applying again')
            print('Fleet release is already installed and current: '+current['revision'])
            return 0
    authority=require_authority(root,args,revision,source_id,source)
    if current and current.get('revision')==revision and current.get('status')=='active':
        if check_files(root,revision) or check_schedules(root,plan):
            raise ValueError('Existing release has drift; reconcile it before applying again')
        print('Fleet release is already installed and current: '+revision)
        return 0
    for required in ('deadlock_recovery.py','kanban-retry-breaker.sh','kanban-aging-escalation.py',
                     'cron-loop-monitor.py','review-taskforce-tick.sh'):
        if not (root/'scripts'/required).is_file():
            raise ValueError('Install existing maintained runtime dependency first: '+required)
    if source_revision(source,clean=True)!=source_id:
        raise ValueError('Committed fleet source changed during preflight')
    for item in [*plan['pause'],plan.get('daily'),plan.get('supervisor')]:
        if item and owned(current_job(root,item))!=item['before']:
            raise ValueError('Schedule input changed during preflight')
    context=dict(source_revision=source_id,dependencies=dependencies,authority=authority,
                 previous_release=current,schedule=plan,content_id=content_id,file_owners=ownership,
                 workflow_versions=[1])
    manifest=install_files(root,pending,revision,source=source,context=context,preimages=preimages)
    manifest_path=journal(root,revision)
    atomic_write(manifest_path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
    def checkpoint():
        schedule_snapshot(root,plan)
        manifest['schedule']=plan
        atomic_write(manifest_path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
    apply_schedules(root,plan,checkpoint=checkpoint)
    manifest['schedule']=plan;manifest['status']='active'
    atomic_write(manifest_path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
    atomic_write(state,json.dumps({'revision':revision,'status':'active'})+'\n',mode=0o600)
    print('Installed fleet release '+revision+'; current sessions drain normally.')
    return 0


if __name__=='__main__':
    try:
        sys.exit(main())
    except (ValueError,OSError,sqlite3.Error,subprocess.SubprocessError) as exc:
        print('Fleet release stopped: '+str(exc),file=sys.stderr)
        sys.exit(2)
