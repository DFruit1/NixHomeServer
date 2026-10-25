#!/usr/bin/env python3
"""Plan, install, check and roll back a coherent Hermes fleet release.

Python installer glue composes existing tracked policy transforms. Native Hermes
and its reviewed recovery adapters remain dependencies, fingerprinted separately.
No credentials, board databases or whole cron journals are restored.
"""
import argparse
import ast
from contextlib import contextmanager
import fcntl
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sqlite3
import stat
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
}
STEWARD_JOBS = {'steward opportunity scan': 'steward-opportunity-prompt.txt',
                'steward stall follow-up': 'steward-stall-prompt.txt'}


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
        rank = (1 if path.name == 'kanban_tools_schemas.py' else
                2 if path.name == 'kanban_db_connect.py' else
                3 if path.name in {'kanban_db.py','kanban_db_dispatch.py','kanban_tools.py',
                            'kanban_tools_schemas.py','kanban_stop.py','kanban.py',
                            'run_agent.py','local.py'} else 0)
        return rank, str(path)
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
               'hermes-agent/hermes_cli/kanban.py','hermes-agent/hermes_cli/kanban_db.py','hermes-agent/hermes_cli/kanban_db_dispatch.py',
               'hermes-agent/run_agent.py','hermes-agent/tools/environments/local.py',
               'hermes-agent/tools/kanban_tools.py','hermes-agent/tools/kanban_tools_schemas.py']
    relatives += [str(p.relative_to(root)) for pattern in
                  ('hermes-agent/hermes_cli/nixhomeserver_*.py','hermes-agent/cron/nixhomeserver_*.py')
                  for p in root.glob(pattern)]
    return {relative:sha(value) if value is not None else None
            for relative in sorted(set(relatives))
            for value in [read(checked(root,root/relative))]}


def rollback_files(root, revision, *, dry_run=False):
    path=journal(root,revision)
    manifest=json.loads(path.read_text())
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
    require_iteration_rollback_compatibility(root, manifest)
    if manifest.get('release_condition_versions'):
        previous=manifest.get('previous_release') or {}
        old=json.loads(journal(root,previous['revision']).read_text()) if previous.get('revision') else {}
        if 1 not in old.get('release_condition_versions',[]):
            raise ValueError('Rollback would remove native release-condition readers and enforcement; install a compatible reviewed release')
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
    require_iteration_rollback_compatibility(root, manifest)
    if manifest.get('release_condition_versions'):
        previous=manifest.get('previous_release') or {}
        old=json.loads(journal(root,previous['revision']).read_text()) if previous.get('revision') else {}
        if 1 not in old.get('release_condition_versions',[]):
            raise ValueError('Rollback would remove native release-condition readers and enforcement; install a compatible reviewed release')
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


def iteration_guard_downgrade(root, manifest):
    """Inspect verified rollback bytes without importing historical code."""
    helper='hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py'
    item=next((entry for entry in manifest.get('files',[]) if entry['path']==helper),None)
    if item is None:
        return False
    preimage=item.get('preimage')
    old=read(checked(root,journal(root,manifest['revision']).parent/preimage)) if preimage else None
    if (sha(old) if old is not None else None)!=item['before_sha256']:
        raise ValueError('Rollback iteration-guard preimage failed verification')
    if old:
        tree=ast.parse(old)
        for node in tree.body:
            if (isinstance(node,ast.Assign) and len(node.targets)==1
                    and isinstance(node.targets[0],ast.Name)
                    and node.targets[0].id=='ITERATION_GUARD_VERSION'
                    and isinstance(node.value,ast.Constant)
                    and type(node.value.value) is int and node.value.value>=2):
                return False
    return True


def require_iteration_rollback_compatibility(root, manifest):
    """Never restore helpers that remove native finite-authority enforcement.

    A scan of existing boards cannot fence a newly created board or a first
    trip from a concurrent worker. Require a compatible reviewed rollback
    release even before first use; do not attempt a racy negative-history proof.
    """
    if iteration_guard_downgrade(root,manifest):
        raise ValueError('Rollback would remove iteration authority enforcement; install a compatible reviewed release')


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


def schedule_records(plan):
    return [*plan['pause'], *plan.get('steward', []), plan.get('daily'), plan.get('supervisor')]


def observed(root, item):
    job = current_job(root, item)
    return {**owned(job), **({'prompt': job.get('prompt')} if 'prompt' in (item['before'] or {}) else {})}


def current_job(root, item):
    matches=[j for j in jobs(root,item['profile']) if j['id']==item['id']]
    if len(matches)!=1:
        raise ValueError('Owned native schedule is missing or ambiguous')
    return matches[0]


def schedule_plan(root, *, activate_steward=False, directory=HERE):
    policy = checked(root, root / 'state/fleet/handlers.json')
    handlers = json.loads(policy.read_text()) if policy.exists() else {'evidence': {'enabled': True, 'interval': 300}}
    handlers.setdefault('agent-usage', {'enabled': True, 'interval': 300})
    handlers.setdefault('usage-guard', {'enabled': True, 'interval': 300})
    handlers.setdefault('board-progress', {'enabled': True, 'interval': 900})
    handlers.setdefault('release-conditions', {'enabled': True, 'interval': 300})
    result = dict(pause=[], steward=[], daily=None, supervisor=None, handlers=handlers)
    for profile in ('default', 'head-coordinator', 'board-steward'):
        names = {}
        for job in jobs(root, profile):
            key = (profile, job.get('name'))
            is_inspection = profile == 'board-steward' and job.get('name') in STEWARD_JOBS
            is_owned = is_inspection or key in JOBS or key == ('board-steward','hermes daily steward') or key == ('default',NAME)
            if not is_owned:
                continue
            if key in names:
                raise ValueError('Duplicate owned schedule: ' + str(key))
            names[key] = job
            record = dict(profile=profile, id=job['id'], before=owned(job))
            if is_inspection:
                record['before']['prompt'] = job.get('prompt')
                record['prompt_source'] = STEWARD_JOBS[job['name']]
                record['desired_prompt'] = (directory / record['prompt_source']).read_text()
                record['activate'] = active(job) or activate_steward
                result['steward'].append(record)
            elif key == ('default', NAME):
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
    for item in schedule_records(plan):
        if item is None:
            continue
        item.setdefault('after',observed(root,item))


def mutate_schedule(root, item, arguments, changes, checkpoint):
    expected=item.get('after',item['before'])
    if observed(root,item)!=expected:
        raise ValueError('Schedule changed since preflight: '+item['id'])
    item['intent']=dict(before=expected,changes=changes,operation=arguments[0])
    checkpoint()  # A successful native mutation remains recoverable if its reply is lost.
    cron(root,item['profile'],*arguments)
    actual=observed(root,item)
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
    for item in plan.get('steward', []):
        prompt = item['desired_prompt']
        mutate_schedule(root,item,['edit',item['id'],'--prompt',prompt],{'prompt':prompt},checkpoint)
        if item['activate'] and not item['before']['enabled']:
            mutate_schedule(root,item,['resume',item['id']],{'enabled':True,'paused_at':None},checkpoint)
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
    for item in plan.get('steward', []):
        if observed(root,item) != item.get('after'):
            errors.append('steward:'+item['id'])
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
    for item in schedule_records(plan):
        if item and item.get('intent'):
            intent=item['intent'];actual=observed(root,item)
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
        actual=observed(root,item)
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
    for item in plan.get('steward', []):
        before = item['before']
        if observed(root,item) != before:
            if current_job(root,item).get('prompt') != before['prompt']:
                mutate_schedule(root,item,['edit',item['id'],'--prompt',before['prompt'] or ''],
                                {'prompt':before['prompt']},checkpoint)
            if not before['enabled'] and active(current_job(root,item)):
                mutate_schedule(root,item,['pause',item['id']],{'enabled':False},checkpoint)
            item['restored'] = observed(root,item)
            checkpoint()
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


def source_changes(root, directory, *, workers=False, coordinator_only=False):
    """Upgrade transforms use their source helpers, never cached installed ones."""
    names=('hermes_common','hermes_config','coordinator_trial') + (('worker_runtime_adapter','fleet_runtime_adapter',
        'coordinator_repair_adapter','coordinator_tools_adapter','recovered_resume_adapter','resume_recovered',
        'worker_origin_adapter') if workers else ())
    previous={name:sys.modules.get(name) for name in names}
    previous_path=sys.path[:]
    try:
        sys.path.insert(0,str(directory))
        for name in names:
            spec=importlib.util.spec_from_file_location(name,directory/(name+'.py'))
            module=importlib.util.module_from_spec(spec)
            sys.modules[name]=module
            spec.loader.exec_module(module)
        pending = {}
        if not coordinator_only:
            spec=importlib.util.spec_from_file_location('fleet_taskforce_install',directory/'install-review-taskforce.py')
            installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
            pending = installer.changed_files(root)
        if workers and not coordinator_only:
            spec = importlib.util.spec_from_file_location('fleet_worker_install', directory/'install-worker-policy.py')
            worker = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(worker)
            pending = worker.pending_files(root, pending)
            spec=importlib.util.spec_from_file_location('fleet_origin_install',directory/'install-worker-origin.py')
            origin=importlib.util.module_from_spec(spec);spec.loader.exec_module(origin)
            for path,before,after in origin.pending_files(root):
                if path in pending and pending[path] != before:
                    raise ValueError('Native launch provenance has conflicting release owners')
                pending[path]=after
        if workers:
            # These seams are already fleet-owned. Compose their reviewed
            # migration here rather than making the separate API installer
            # invalidate the active release's immutable file manifest.
            spec=importlib.util.spec_from_file_location('fleet_recovery_install',directory/'install-recovered-resume.py')
            recovery=importlib.util.module_from_spec(spec);spec.loader.exec_module(recovery)
            _,recovery_pending,_=recovery.pending_files(root,
                origin_candidate=pending.get(root/'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py'))
            owned={'tools/kanban_tools.py','tools/kanban_tools_schemas.py',
                   'hermes_cli/nixhomeserver_coordinator_repair.py',
                   'hermes_cli/nixhomeserver_resume_recovered.py',
                   'hermes_cli/nixhomeserver_coordinator_tools.py',
                   'hermes_cli/nixhomeserver_coordinator_delivery.py',
                   'hermes_cli/kanban_db_connect.py',
                   'hermes_cli/kanban_db.py','hermes_cli/kanban.py'}
            for path,before,after in recovery_pending:
                relative=str(path.relative_to(root/'hermes-agent'))
                if relative in owned:
                    # Compose on worker/workflow output, not the earlier input.
                    if relative in {'hermes_cli/nixhomeserver_coordinator_repair.py',
                                    'hermes_cli/nixhomeserver_resume_recovered.py',
                                    'hermes_cli/nixhomeserver_coordinator_tools.py',
                                    'hermes_cli/nixhomeserver_coordinator_delivery.py'}:
                        if path in pending and pending[path] not in (before,after):
                            raise ValueError('Recovery helper has conflicting release owners: '+relative)
                        pending[path]=after
                    elif path in pending:
                        value=sys.modules['recovered_resume_adapter'].adapt(relative,pending[path])
                        if relative.startswith('tools/'):
                            value=sys.modules['coordinator_repair_adapter'].adapt(relative,value)
                        if relative != 'hermes_cli/kanban.py':
                            value=sys.modules['coordinator_tools_adapter'].adapt(relative,value)
                        pending[path]=value
                    else:
                        pending[path]=after
                elif before!=after:
                    raise ValueError('Install the matching reviewed recovery prerequisites first: '+relative)
        coordinator=root/'profiles/head-coordinator/config.yaml'
        if coordinator.exists() and not coordinator_only:
            pending[coordinator]=sys.modules['coordinator_trial'].configure(pending.get(coordinator,coordinator.read_text()))
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


def bounded_regular(path, *, limit=1024*1024):
    try:fd=os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
    except OSError:
        raise ValueError('Required adoption evidence is missing or unavailable') from None
    with os.fdopen(fd,'rb') as stream:
        info=os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_size>limit:
            raise ValueError('Adoption evidence must be a bounded regular file')
        value=stream.read(limit+1)
        if len(value)>limit:raise ValueError('Adoption evidence exceeds its bound')
        return value


def model_choices(text):
    """Compare the complete configuration without exposing credential values."""
    from hermes_config import document
    data=document(text)
    model=data.get('model')
    fallback=data.get('fallback_providers')
    if not isinstance(model,dict) or not isinstance(fallback,list) or len(fallback)>8:
        raise ValueError('Model adoption requires explicit model and bounded fallback mappings')
    def pair(value, keys):
        if (not isinstance(value,dict) or (keys and set(value)!=keys)
                or any(not isinstance(value.get(key),str) or not re.fullmatch(r'\S{1,256}',value[key])
                       for key in ('provider','model'))):
            raise ValueError('Fallback adoption supports provider/model pairs without extra settings')
        return (value['provider'],value['model'])
    primary=pair({'provider':model.get('provider'),'model':model.get('default')},None)
    chain=[primary,*[pair(entry,{'provider','model'}) for entry in fallback]]
    choices={'default':model['default'],'provider':model['provider'],'fallback_providers':fallback}
    remaining={**data,'model':{key:value for key,value in model.items() if key not in {'default','provider'}}}
    remaining.pop('fallback_providers')
    try:
        # JSON retains bool/int and other scalar type differences that ordinary
        # Python mapping equality would overlook. Unsupported YAML fails closed.
        projection=json.dumps(remaining,sort_keys=True,allow_nan=False)
    except (TypeError,ValueError):
        raise ValueError('Unsupported configuration values for bounded model adoption') from None
    return choices,sorted(chain),projection


def config_adoption(root, receipt_path):
    """Qualify one recorded owner grant; a receipt never supplies authority."""
    receipt_path=receipt_path.absolute()
    if any(part.is_symlink() for part in (receipt_path,*receipt_path.parents)):
        raise ValueError('Adoption receipt paths must not contain symlinks')
    raw=bounded_regular(receipt_path,limit=8192)
    def unique(pairs):
        value={}
        for key,item in pairs:
            if key in value:raise ValueError('Duplicate adoption receipt key')
            value[key]=item
        return value
    receipt=json.loads(raw,object_pairs_hook=unique)
    keys={'schema_version','prior_release','path','prior_sha256','observed_sha256','grant_reference'}
    if (not isinstance(receipt,dict) or set(receipt)!=keys or type(receipt['schema_version']) is not int
            or receipt['schema_version']!=1
            or receipt['path']!='profiles/feature-reviewer/config.yaml'
            or any(not isinstance(receipt[key],str) or not re.fullmatch(r'[a-f0-9]{64}',receipt[key])
                   for key in ('prior_sha256','observed_sha256'))
            or not isinstance(receipt['grant_reference'],str) or not receipt['grant_reference'].strip()
            or len(receipt['grant_reference'])>1000):
        raise ValueError('Adoption receipt needs exact release, config hashes and existing owner grant reference')
    state=json.loads(bounded_regular(checked(root,root/'state/fleet/current.json')))
    if state!={'revision':receipt['prior_release'],'status':'active'}:
        raise ValueError('Adoption receipt does not name the active prior release')
    manifest_path=journal(root,receipt['prior_release'])
    old_raw=bounded_regular(manifest_path)
    manifest=json.loads(old_raw)
    if manifest.get('status')!='active' or manifest.get('revision')!=receipt['prior_release']:
        raise ValueError('Adoption requires an active immutable prior manifest')
    matches=[item for item in manifest['files'] if item['path']==receipt['path']]
    if len(matches)!=1:raise ValueError('Adopted config is not uniquely owned by the prior release')
    entry=matches[0]
    if (entry['after_sha256']!=receipt['prior_sha256'] or entry['before_sha256']!=entry['after_sha256']
            or not isinstance(entry.get('preimage'),str)
            or not re.fullmatch(r'[0-9]+\.before',entry['preimage'])):
        raise ValueError('Prior config postimage is unavailable from a verified immutable preimage')
    before=bounded_regular(checked(root,manifest_path.parent/entry['preimage']))
    if sha(before)!=receipt['prior_sha256']:
        raise ValueError('Prior config immutable preimage failed verification')
    target=checked(root,root/receipt['path'])
    observed=bounded_regular(target)
    if sha(observed)!=receipt['observed_sha256'] or target.stat().st_mode&0o777!=entry['mode']:
        raise ValueError('Observed owner config changed or has an unapproved mode')
    if check_files(root,receipt['prior_release'])!=[receipt['path']]:
        raise ValueError('Model adoption requires exactly its named config drift and no dependency drift')
    if manifest.get('schedule') and check_schedules(root,manifest['schedule']):
        raise ValueError('Model adoption cannot adopt schedule drift')
    old_choices,old_pairs,old_rest=model_choices(before.decode())
    choices,pairs,rest=model_choices(observed.decode())
    if old_rest!=rest or old_pairs!=pairs or old_choices==choices:
        raise ValueError('Model adoption permits only rearranging the existing provider/model chain')
    return {**receipt,'receipt_sha256':sha(raw),'prior_manifest_sha256':sha(old_raw),
            'prior_preimage':entry['preimage'],'mode':entry['mode']}


def adoption_baseline(root, adoption, *, install=False):
    """A new no-write baseline preserves the approved model order on rollback."""
    raw=bounded_regular(journal(root,adoption['prior_release']))
    if sha(raw)!=adoption['prior_manifest_sha256']:
        raise ValueError('Prior immutable manifest changed during adoption')
    previous=json.loads(raw)
    identity={'adopted_from':adoption['prior_release'],'config_adoption':adoption}
    revision=sha(json.dumps(identity,sort_keys=True).encode())
    if not install:return {'revision':revision,'status':'active'}
    retained={key:previous[key] for key in ('source_revision','dependencies','schedule','file_owners','workflow_versions')
              if key in previous}
    expected={item['path']:{'sha256':adoption['observed_sha256'] if item['path']==adoption['path']
                           else item['after_sha256'],'mode':item['mode']} for item in previous['files']}
    path=journal(root,revision)
    if path.exists():
        existing=json.loads(path.read_text())
        inventory={item['path']:{'sha256':item['after_sha256'],'mode':item['mode']}
                   for item in existing.get('files',[]) if item['before_sha256']==item['after_sha256']}
        if (existing.get('status')!='active' or existing.get('adoption_baseline')!=identity
                or existing.get('source')!=previous.get('source') or inventory!=expected
                or len(existing.get('files',[]))!=len(expected) or existing.get('config_adoptions')!=[adoption]
                or any(existing.get(key)!=value for key,value in retained.items())
                or check_files(root,revision)
                or (existing.get('schedule') and check_schedules(root,existing['schedule']))):
            raise ValueError('Existing adoption baseline is incomplete or changed; reconcile its journal')
    else:
        pending={checked(root,root/item['path']):bounded_regular(checked(root,root/item['path'])).decode()
                 for item in previous['files']}
        context=dict(retained)
        context.update(adoption_baseline=identity,config_adoptions=[adoption])
        manifest=install_files(root,pending,revision,source=previous.get('source'),context=context,preimages=expected)
        if check_files(root,revision) or (manifest.get('schedule') and check_schedules(root,manifest['schedule'])):
            raise ValueError('Adoption baseline readback differs')
        manifest['status']='active'
        atomic_write(path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
    return {'revision':revision,'status':'active'}


def coordinator_schedule_updates(root, manifest):
    """Retain an independently updated steward prompt without running/editing it."""
    plan=manifest.get('schedule')
    retained=list(manifest.get('retained_external_schedule_updates',[]))
    for error in check_schedules(root,plan) if plan else []:
        match=next((item for item in plan.get('steward',[]) if error=='steward:'+item['id']),None)
        if match is None:
            raise ValueError('Existing schedule drift needs its owning repair')
        current=observed(root,match);previous=match.get('after',match['before'])
        if ({k:v for k,v in current.items() if k!='prompt'}!=
                {k:v for k,v in previous.items() if k!='prompt'}
                or not isinstance(current.get('prompt'),str) or len(current['prompt'])>24000):
            raise ValueError('Only an existing steward prompt may be retained; schedule/delivery/capacity drift refuses')
        record=dict(profile=match['profile'],id=match['id'],prompt_sha256=sha(current['prompt'].encode()))
        retained=[item for item in retained if (item['profile'],item['id'])!=(record['profile'],record['id'])]+[record]
    return retained


def coordinator_component_files(root, source, *, owners, retained, inputs=None, schedule_updates=None):
    """Publish only this API; preserve and identify independent instruction work.

    A config exception accepts only the added fail-closed dependency hook, never
    changed models, credentials, budgets, existing hooks or file modes. Native
    code/dependency drift still refuses. Previous manifests remain immutable.
    """
    state=json.loads(bounded_regular(checked(root,root/'state/fleet/current.json')))
    manifest_path=journal(root,state['revision'])
    manifest=json.loads(bounded_regular(manifest_path))
    if state.get('status')!='active' or manifest.get('status')!='active':
        raise ValueError('Coordinator component requires an active existing fleet release')
    preserved=coordinator_schedule_updates(root,manifest)
    if schedule_updates is not None:schedule_updates.extend(preserved)
    entries={entry['path']:entry for entry in manifest['files']}
    allowed={'tools/kanban_tools.py','tools/kanban_tools_schemas.py','hermes_cli/kanban_db.py',
             'hermes_cli/kanban_db_connect.py','hermes_cli/kanban.py',
             'hermes_cli/nixhomeserver_coordinator_repair.py','hermes_cli/nixhomeserver_resume_recovered.py',
             'hermes_cli/nixhomeserver_coordinator_tools.py'}
    allowed.add('hermes_cli/nixhomeserver_coordinator_delivery.py')
    paths={root/relative for relative in entries} | {root/'hermes-agent'/relative for relative in allowed}
    paths |= {root/'profiles/head-coordinator/SOUL.md',root/'scripts/hermes-coordinator-reference.md',root/'scripts/fleet-release.py'}
    initial={checked(root,path):read(checked(root,path)) for path in paths}
    observed={str(path.relative_to(root)):{'sha256':sha(value) if value is not None else None,
              'mode':path.stat().st_mode&0o777 if value is not None else None} for path,value in initial.items()}
    if inputs is not None:inputs.update(observed)
    profiles=('head-coordinator','standard-implementer','local-implementer','feature-reviewer','project-auditor','board-steward')
    documents={'SOUL.md','scripts/hermes-card-authoring.md','scripts/hermes-fleet-policy.md'}
    documents.update('profiles/'+name+'/SOUL.md' for name in profiles)
    documents.update(relative for relative in entries if relative.startswith('profiles/')
                     and '/skills/' in relative and relative.endswith('.md'))
    # The steward's separately maintained observation/feedback component is
    # retained byte-for-byte; this release does not execute or replace it.
    steward_helpers={relative for relative in entries if relative.startswith('profiles/board-steward/')
                     and Path(relative).suffix in {'.md','.py','.sh'}}
    steward_helpers |= {'scripts/steward-coordinator-request.py','scripts/steward-readonly-guard.py'}
    steward_helpers.update(relative for relative in entries if
        (relative.startswith('scripts/steward-') and relative.endswith('.py')) or
        relative in {'scripts/kanban-daily-steward.py','scripts/daily-steward-window.py'})
    configs={'profiles/'+name+'/config.yaml' for name in profiles}
    drift=check_files(root,state['revision'])
    for relative in drift:
        if relative not in documents | configs | steward_helpers:
            raise ValueError('Unrelated native, dependency or unknown file drift needs its owning repair: '+relative)
        entry=entries[relative];target=checked(root,root/relative)
        if target.stat().st_mode&0o777!=entry['mode']:
            raise ValueError('Instruction drift cannot adopt file modes')
        if relative in configs:
            if entry['before_sha256']!=entry['after_sha256'] or not entry.get('preimage'):
                raise ValueError('Config drift needs a verified unchanged baseline')
            previous=bounded_regular(checked(root,manifest_path.parent/entry['preimage']))
            if sha(previous)!=entry['after_sha256']:
                raise ValueError('Config drift baseline verification failed')
            from hermes_config import document
            before,after=document(previous.decode()),document(initial[target].decode())
            old_hooks,new_hooks=before.pop('hooks',{}),after.pop('hooks',{})
            old_calls=old_hooks.pop('pre_tool_call',[]);new_calls=new_hooks.pop('pre_tool_call',[])
            added=dict(matcher='^kanban_(create|amend|comment)$',
                       command=shlex.join(['python3',str(root/'scripts/card-dependency-guard.py')]),
                       timeout=10,fail_closed=True)
            if (before!=after or old_hooks!=new_hooks or new_calls.count(added)!=1
                    or [item for item in new_calls if item!=added]!=old_calls):
                raise ValueError('Config drift is not solely the additional fail-closed dependency hook')
    retained.extend(sorted(set(drift) | set(manifest.get('retained_external_changes',[]))))
    pending={checked(root,root/relative):initial[root/relative].decode()
             for relative in entries}
    owners.update({path:['retained-existing'] for path in pending})
    changes=source_changes(root,source/'scripts/hermes',workers=True,coordinator_only=True)
    if any(not path.is_relative_to(root/'hermes-agent') or
           str(path.relative_to(root/'hermes-agent')) not in allowed for path in changes):
        raise ValueError('Coordinator component attempted effects outside its native API')
    soul=checked(root,root/'profiles/head-coordinator/SOUL.md')
    text=initial[soul].decode()
    first,last='<!-- hermes-coordinator-role -->','<!-- /hermes-coordinator-role -->'
    if text.count(first)!=1 or text.count(last)!=1 or text.index(first)>text.index(last):
        raise ValueError('Coordinator role needs one existing managed block')
    role=(source/'scripts/hermes/taskforce/coordinator-role.md').read_text().rstrip()
    changes[soul]=text[:text.index(first)]+first+'\n'+role+'\n'+text[text.index(last):]
    changes[root/'scripts/hermes-coordinator-reference.md']=(source/'scripts/hermes/instructions/coordinator-reference.md').read_text()
    changes[root/'scripts/fleet-release.py']=(source/'scripts/hermes/fleet-release.py').read_text()
    for path,text in changes.items():
        pending[path]=text;owners[path]=['coordinator-tools']
    if any(read(path)!=value or (value is not None and path.stat().st_mode&0o777!=observed[str(path.relative_to(root))]['mode'])
           for path,value in initial.items()):
        raise ValueError('Coordinator component input changed during preparation')
    return pending


def recovery_wait_component_files(root, source, *, owners, retained, inputs=None, schedule_updates=None):
    """Retain the active fleet; publish only the qualified event-wait delta."""
    state=json.loads(bounded_regular(checked(root,root/'state/fleet/current.json')))
    manifest=json.loads(bounded_regular(journal(root,state['revision'])))
    if state.get('status')!='active' or manifest.get('status')!='active':
        raise ValueError('Recovery waits require an active existing fleet release')
    files={
        'scripts/fleet-release.py':'scripts/hermes/fleet-release.py',
        'scripts/fleet-supervisor.py':'scripts/hermes/fleet-supervisor.py',
        'scripts/deadlock_recovery.py':'scripts/hermes/deadlock_recovery.py',
        'scripts/hermes-capability-recovery.md':'scripts/hermes/instructions/capability-recovery.md',
        'scripts/hermes-coordinator-reference.md':'scripts/hermes/instructions/coordinator-reference.md',
    }
    helpers=('scripts/recovery_wait.py','hermes-agent/hermes_cli/nixhomeserver_recovery_wait.py')
    native=checked(root,root/'hermes-agent/hermes_cli/kanban_db.py')
    entries={item['path']:item for item in manifest['files']}
    paths={checked(root,root/relative) for relative in set(entries)|set(files)|set(helpers)}|{native}
    # Bind every retained and replaced byte/mode before composing any output.
    # A later read must never authorize overwriting a concurrent independent edit.
    initial={path:bounded_regular(path) if path.exists() else None for path in paths}
    observed={str(path.relative_to(root)):{'sha256':sha(value) if value is not None else None,
              'mode':path.stat().st_mode&0o777 if value is not None else None}
              for path,value in initial.items()}
    if (check_files(root,state['revision']) or any(
            observed[relative]!={'sha256':item['after_sha256'],'mode':item['mode']}
            for relative,item in entries.items())):
        raise ValueError('Reconcile active fleet drift before publishing recovery waits')
    for relative in helpers:
        if initial[root/relative] is not None and relative not in entries:
            raise ValueError('Recovery wait helper already exists outside fleet ownership')
    subprocess.run(['git','-C',str(source),'merge-base','--is-ancestor',
                    manifest['source_revision'],'HEAD'],check=True,capture_output=True)
    pending={root/relative:initial[root/relative].decode() for relative in entries}
    owners.update({path:['retained-existing'] for path in pending})
    retained.extend(manifest.get('retained_external_changes',[]))
    if schedule_updates is not None:
        schedule_updates.extend(coordinator_schedule_updates(root,manifest))
    for relative,original in files.items():
        path=checked(root,root/relative)
        predecessor=subprocess.check_output(['git','-C',str(source),'show',
                                            manifest['source_revision']+':'+original])
        if initial[path]!=predecessor:
            raise ValueError('Recovery wait target needs its current maintained source: '+relative)
        pending[path]=(source/original).read_text()
        owners[path]=['recovery-waits']
    from worker_runtime_adapter import adapt
    from recovered_resume_adapter import adapt as recovery_adapt
    pending[native]=recovery_adapt('hermes_cli/kanban_db.py',adapt('kanban_db.py',initial[native].decode()))
    owners[native]=['recovery-waits']
    helper=(source/'scripts/hermes/recovery_wait.py').read_text()
    for relative in helpers:
        path=checked(root,root/relative)
        pending[path]=helper;owners[path]=['recovery-waits']
    if any(read(checked(root,path))!=value or (value is not None and
           path.stat().st_mode&0o777!=observed[str(path.relative_to(root))]['mode'])
           for path,value in initial.items()):
        raise ValueError('Recovery wait component input changed during preparation')
    if inputs is not None:
        inputs.update(observed)
    return pending


def condition_adapter(source):
    """Load the selected committed transform, never a cached caller module."""
    path=source/'scripts/hermes/release_conditions_adapter.py'
    spec=importlib.util.spec_from_file_location('fleet_selected_condition_adapter',path)
    module=importlib.util.module_from_spec(spec);spec.loader.exec_module(module)
    return module.adapt


def release_condition_files(root, source, *, owners, retained, inputs=None, schedule_updates=None):
    """Add the native contract API and five-minute scan without replacing drift."""
    state=json.loads(bounded_regular(checked(root,root/'state/fleet/current.json')))
    manifest=json.loads(bounded_regular(journal(root,state['revision'])))
    if state.get('status')!='active' or manifest.get('status')!='active':
        raise ValueError('Release conditions require an active fleet')
    replacements={
        'scripts/fleet-release.py':'scripts/hermes/fleet-release.py',
        'scripts/fleet-supervisor.py':'scripts/hermes/fleet-supervisor.py',
        'scripts/recovery_wait.py':'scripts/hermes/recovery_wait.py',
        'hermes-agent/hermes_cli/nixhomeserver_recovery_wait.py':'scripts/hermes/recovery_wait.py',
        'scripts/board_progress.py':'scripts/hermes/board_progress.py',
        'hermes-agent/hermes_cli/nixhomeserver_board_progress.py':'scripts/hermes/board_progress.py'}
    additions={
        'scripts/release_conditions.py':'scripts/hermes/release_conditions.py',
        'hermes-agent/hermes_cli/nixhomeserver_release_conditions.py':'scripts/hermes/release_conditions.py',
        'scripts/hermes-release-conditions.md':'documentation/hermes-release-conditions.md'}
    native=('hermes_cli/kanban_db.py','hermes_cli/kanban_db_connect.py','hermes_cli/kanban.py','hermes_cli/kanban_parser.py','tools/kanban_tools.py')
    entries={item['path']:item for item in manifest['files']}
    paths=set(entries)|set(replacements)|set(additions)|{'hermes-agent/'+p for p in native}|{'state/fleet/handlers.json'}
    initial={relative:read(checked(root,root/relative)) for relative in paths}
    observed={relative:dict(sha256=sha(data) if data is not None else None,
        mode=(root/relative).stat().st_mode&0o777 if data is not None else None) for relative,data in initial.items()}
    if check_files(root,state['revision']) or any(observed[p]!={'sha256':e['after_sha256'],'mode':e['mode']} for p,e in entries.items()):
        raise ValueError('Reconcile fleet drift before adding release conditions')
    subprocess.run(['git','-C',str(source),'merge-base','--is-ancestor',manifest['source_revision'],'HEAD'],check=True,capture_output=True)
    pending={root/p:initial[p].decode() for p in entries}
    owners.update({path:['retained-existing'] for path in pending})
    retained.extend(manifest.get('retained_external_changes',[]))
    if schedule_updates is not None:schedule_updates.extend(coordinator_schedule_updates(root,manifest))
    for relative,original in replacements.items():
        predecessor=subprocess.check_output(['git','-C',str(source),'show',manifest['source_revision']+':'+original])
        if initial[relative]!=predecessor:
            raise ValueError('Release-condition target needs matching maintained source: '+relative)
        pending[root/relative]=(source/original).read_text();owners[root/relative]=['release-conditions']
    for relative,original in additions.items():
        if initial[relative] is not None and relative not in entries:
            raise ValueError('Release-condition target exists outside fleet ownership: '+relative)
        pending[root/relative]=(source/original).read_text();owners[root/relative]=['release-conditions']
    adapt=condition_adapter(source)
    for name in native:
        path=root/'hermes-agent'/name
        if initial['hermes-agent/'+name] is None:raise ValueError('Native contract dependency missing: '+name)
        pending[path]=adapt(name,initial['hermes-agent/'+name].decode());owners[path]=['release-conditions']
    policy=json.loads(initial['state/fleet/handlers.json'])
    policy.setdefault('release-conditions',dict(enabled=True,interval=300))
    pending[root/'state/fleet/handlers.json']=json.dumps(policy,sort_keys=True,indent=2)+'\n'
    owners[root/'state/fleet/handlers.json']=['release-conditions']
    if any(read(checked(root,root/p))!=value or (value is not None and (root/p).stat().st_mode&0o777!=observed[p]['mode']) for p,value in initial.items()):
        raise ValueError('Release-condition inputs changed during preparation')
    if inputs is not None:inputs.update(observed)
    return pending


def add_release_condition_runtime(root, source, pending, owners):
    adapt=condition_adapter(source)
    helper=(source/'scripts/hermes/release_conditions.py').read_text()
    for name in ('board_progress','recovery_wait'):
        text=(source/('scripts/hermes/'+name+'.py')).read_text()
        for path in (root/'scripts'/(name+'.py'),root/'hermes-agent/hermes_cli'/('nixhomeserver_'+name+'.py')):
            pending[path]=text;owners.setdefault(path,[]).append('release-conditions')
    for relative in ('scripts/release_conditions.py','hermes-agent/hermes_cli/nixhomeserver_release_conditions.py'):
        pending[root/relative]=helper;owners[root/relative]=['release-conditions']
    path=root/'scripts/hermes-release-conditions.md'
    pending[path]=(source/'documentation/hermes-release-conditions.md').read_text();owners[path]=['release-conditions']
    for name in ('hermes_cli/kanban_db.py','hermes_cli/kanban_db_connect.py','hermes_cli/kanban.py','hermes_cli/kanban_parser.py','tools/kanban_tools.py'):
        path=root/'hermes-agent'/name
        pending[path]=adapt(name,pending.get(path) or path.read_text())
        owners.setdefault(path,[]).append('release-conditions')


def pending_files(root, source, plan, *, owners=None, adopt_config=None, adoptions=None,
                  component='full', retained=None, inputs=None, schedule_updates=None):
    directory = source / 'scripts/hermes'
    pending = {}
    owners = {} if owners is None else owners
    if component=='release-conditions':
        if adopt_config is not None:raise ValueError('Config adoption is a separate operation')
        return release_condition_files(root,source,owners=owners,retained=retained if retained is not None else [],inputs=inputs,schedule_updates=schedule_updates)
    if component=='recovery-waits':
        if adopt_config is not None or adoptions:
            raise ValueError('Recovery wait component cannot adopt configuration changes')
        return recovery_wait_component_files(root,source,owners=owners,
            retained=retained if retained is not None else [],inputs=inputs,schedule_updates=schedule_updates)
    if component=='coordinator-tools':
        if adopt_config is not None or adoptions:
            raise ValueError('Coordinator component cannot adopt model/config choices')
        return coordinator_component_files(root,source,owners=owners,retained=retained if retained is not None else [],
                                            inputs=inputs,schedule_updates=schedule_updates)
    current_path = root/'state/fleet/current.json'
    manifest = {}
    adoption=config_adoption(root,adopt_config) if adopt_config is not None else None
    if current_path.exists():
        previous = json.loads(current_path.read_text())
        if previous.get('status') == 'active':
            if not adoption and check_files(root,previous['revision'],dependencies=False):
                raise ValueError('Reconcile installed release drift before replacing it')
            manifest=json.loads(journal(root,previous['revision']).read_text())
            pending.update({root/item['path']:(root/item['path']).read_text() for item in manifest['files']})
            owners.update({p:['retained-legacy'] for p in pending})
    merge_owned(pending,owners,source_changes(root,directory,workers=True),'fleet-runtime')
    spec=importlib.util.spec_from_file_location('fleet_steward_install',directory/'install-steward-readonly.py')
    steward=importlib.util.module_from_spec(spec);spec.loader.exec_module(steward)
    merge_owned(pending,owners,steward.profile_files(root,pending),'steward',compose=True)
    # These helpers previously needed a separate interactive files-only update.
    # They now share the release's preimage, readback and rollback transaction.
    for name in ('deadlock_recovery.py', 'feature_flow.py', 'capability_recovery.py',
                 'feature_contract.py', 'fleet_contract.py'):
        merge_owned(pending,owners,{root/'scripts'/name:(directory/name).read_text()},'recovery')
    for name in ('fleet-release.py','fleet-evidence.py','fleet-supervisor.py','fleet-report.py','kanban-analytics.py',
                 'agent-usage.py','agent_usage_report.py','agent_usage_guard.py','langfuse_mcp.py','coordinator_trial.py',
                 'fleet_workflow.py','idle-recovery-monitor.py','kanban-board-health.sh','board_progress.py'):
        merge_owned(pending,owners,{root/'scripts'/name:(directory/name).read_text()},'fleet-runtime')
    merge_owned(pending,owners,{
        root/'profiles/board-steward/scripts/fleet-report.py':(directory/'fleet-report.py').read_text(),
        root/'profiles/board-steward/scripts/agent_usage_report.py':(directory/'agent_usage_report.py').read_text(),
        root/'state/fleet/handlers.json':json.dumps(plan['handlers'], sort_keys=True, indent=2) + '\n'},'fleet-runtime')
    native=root/'hermes-agent/plugins/observability/langfuse/__init__.py'
    if native.is_file():
        spec=importlib.util.spec_from_file_location('fleet_agent_usage',directory/'agent-usage.py')
        module=importlib.util.module_from_spec(spec)
        original_path=sys.path[:]
        try:
            sys.path.insert(0,str(directory));spec.loader.exec_module(module)
            merge_owned(pending,owners,{native:module.patch_native(native.read_text())},'agent-usage')
            request_hook=root/'hermes-agent/agent/api_request_hooks.py'
            merge_owned(pending,owners,{request_hook:module.patch_request_hook(request_hook.read_text())},'agent-usage')
        finally:sys.path[:]=original_path
    if adoption:
        target=root/adoption['path']
        if model_choices(pending[target])[0]!=model_choices(bounded_regular(target).decode())[0]:
            raise ValueError('Release composition would replace the adopted owner model choices')
        if adoptions is not None:adoptions.append(adoption)
    add_release_condition_runtime(root,source,pending,owners)
    if current_path.exists():
        for relative in manifest.get('retained_external_changes',[]):
            if pending.get(root/relative)!=(root/relative).read_text():
                raise ValueError('Preserved external instructions need matching committed sources before a full release: '+relative)
        for record in manifest.get('retained_external_schedule_updates',[]):
            item=next((item for item in plan.get('steward',[]) if item['id']==record['id'] and item['profile']==record['profile']),None)
            if item is None or sha(item.get('prompt','').encode())!=record['prompt_sha256']:
                raise ValueError('Preserved steward prompt needs matching committed source before a full release')
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
                         'backups/recovered-resume/install.lock','runtime/recovered-resume/operation.lock'):
            # Hold the owning API installer's lock from qualification through
            # fingerprint capture and publication; it cannot replace a guard
            # and have its new bytes adopted as an unqualified baseline. The
            # native resume lock also fences a concurrent one-shot reservation
            # throughout compatibility checks, schedules and file publication.
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
    parser.add_argument('--adopt-config',type=Path,
                        help='Exact receipt of an existing owner-approved provider/model rearrangement')
    parser.add_argument('--activate-steward', action='store_true',
                        help='Explicitly resume the two existing steward inspection jobs')
    parser.add_argument('--component',choices=('full','coordinator-tools','recovery-waits','release-conditions'),default='full',
                        help='Publish a bounded component while preserving the active fleet and schedules')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))).absolute()
    if args.action in {'apply','rollback'}:
        with mutation_locks(root):
            return operate(args,root)
    return operate(args,root)


def operate(args,root):
    component=getattr(args,'component','full')
    if component!='full' and (args.action not in {'plan','apply'} or args.activate_steward):
        raise ValueError('Coordinator component is a plan/apply operation without schedule changes')
    adopt_config=getattr(args,'adopt_config',None)
    if adopt_config is not None and args.action not in {'plan','apply'}:
        raise ValueError('Config adoption is available only during release plan/apply')
    state = checked(root,root/'state/fleet/current.json')
    current = json.loads(state.read_text()) if state.exists() else None
    if args.action in {'check','status','rollback'}:
        revision = args.revision or (current or {}).get('revision')
        if not revision:
            raise ValueError('No recorded fleet release')
        manifest_path = journal(root,revision)
        manifest = json.loads(manifest_path.read_text())
        if args.action == 'rollback':
            if manifest.get('adoption_baseline'):
                raise ValueError('An owner config adoption baseline is retained; reversing it needs its own approved change')
            require_authority(root,args,revision,manifest.get('source_revision'),Path(manifest.get('source') or ''))
            require_rollback_compatibility(root,manifest)
            # Preflight file conflicts before modifying any schedules.
            rollback_files(root,revision,dry_run=True)
            if manifest.get('schedule') and manifest.get('component','full')=='full':
                def rollback_checkpoint():
                    atomic_write(manifest_path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
                restore_schedules(root,manifest['schedule'],checkpoint=rollback_checkpoint)
            rollback_files(root,revision)
            supervisor=(manifest.get('schedule') or {}).get('supervisor')
            if manifest.get('component','full')=='full' and supervisor and supervisor.get('before') and active(supervisor['before']):
                cron(root,'default','resume',supervisor['id'])
            previous=manifest.get('previous_release')
            atomic_write(state,json.dumps(previous or {'revision':revision,'status':'rolled-back'})+'\n',mode=0o600)
            return 0
        drift = check_files(root,revision)
        schedules = check_schedules(root,manifest['schedule']) if manifest.get('schedule') else []
        print(json.dumps(dict(revision=revision,status=manifest['status'],file_drift=drift,
                              schedule_drift=schedules,runtime='Existing sessions may retain prior prompts; refresh at idle.',
                              **({'component':manifest['component'],'retained_external_changes':manifest.get('retained_external_changes',[]),
                                  'retained_external_schedule_updates':manifest.get('retained_external_schedule_updates',[])}
                                 if manifest.get('component') else {})),sort_keys=True))
        return int(bool(drift or schedules or manifest['status']!='active'))
    source = args.source
    if source is None and current and current.get('status')=='active':
        recorded=json.loads(journal(root,current['revision']).read_text()).get('source')
        source=Path(recorded) if recorded else None
    source = (source or HERE.parents[1]).resolve()
    source_id = source_revision(source, clean=args.action=='apply')
    plan = schedule_plan(root, activate_steward=args.activate_steward, directory=source/'scripts/hermes')
    if component!='full':
        schedule_snapshot(root,plan)
        if check_schedules(root,plan):
            raise ValueError('Coordinator component cannot alter schedules')
    owners = {}
    adoptions=[]
    retained=[]
    component_inputs={}
    preserved_schedules=[]
    pending = pending_files(root,source,plan,owners=owners,adopt_config=adopt_config,adoptions=adoptions,
                            component=component,retained=retained,inputs=component_inputs,schedule_updates=preserved_schedules)
    dependencies=runtime_dependencies(root)
    # Dependencies are retained rather than overwritten; omit any file whose
    # new bytes this package itself owns from the baseline dependency set.
    dependencies={p:h for p,h in dependencies.items() if root/p not in pending}
    ownership={str(p.relative_to(root)):[item for item in owner if item!='retained-legacy'] or owner
               for p,owner in sorted(owners.items())}
    content=dict(source_revision=source_id,dependencies=dependencies,ownership=ownership,
                  files={str(p.relative_to(root)):sha(t.encode()) for p,t in sorted(pending.items())})
    if component!='full':content.update(component=component,retained_external_changes=retained,
                                      retained_external_schedule_updates=preserved_schedules)
    content_id=sha(json.dumps(content,sort_keys=True).encode())
    preimages={str(p.relative_to(root)):{'sha256':sha(value) if value is not None else None,
                                       'mode':p.stat().st_mode & 0o777 if value is not None else None}
               for p in pending for value in [read(checked(root,p))]}
    if component!='full' and any(preimages.get(path)!=value for path,value in component_inputs.items()):
        raise ValueError('Coordinator component input changed after preparation')
    identity=dict(content_id=content_id,action='apply',schedules=plan,preimages=preimages)
    baseline=adoption_baseline(root,adoptions[0]) if adoptions else None
    if baseline:identity.update(adoption_baseline=baseline,config_adoptions=adoptions)
    revision=sha(json.dumps(identity,sort_keys=True).encode())
    for path,text in pending.items():
        checked(root,path)
        if path.suffix=='.py':compile(text,str(path),'exec')
    if args.action=='apply' and args.revision and args.revision!=revision:
        raise ValueError('Reviewed release plan changed; nothing installed')
    if args.action=='plan':
        print(json.dumps(dict(revision=revision,source_revision=source_id,files=[str(p.relative_to(root)) for p in pending],
                              file_owners=ownership,schedules=plan,
                              **({'component':component,'retained_external_changes':retained} if component!='full' else {}),
                              **({'config_adoptions':adoptions,'adoption_baseline':baseline} if adoptions else {})),indent=2,sort_keys=True))
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
    for item in schedule_records(plan):
        if item and observed(root,item)!=item['before']:
            raise ValueError('Schedule input changed during preflight')
    if adoptions:
        if config_adoption(root,adopt_config)!=adoptions[0]:
            raise ValueError('Config adoption evidence changed during preflight')
        current=adoption_baseline(root,adoptions[0],install=True)
    context=dict(source_revision=source_id,dependencies=dependencies,authority=authority,
                 previous_release=current,schedule=plan,content_id=content_id,file_owners=ownership,
                 workflow_versions=[1],release_condition_versions=[1] if root/'hermes-agent/hermes_cli/nixhomeserver_release_conditions.py' in pending else [])
    if adoptions:context['config_adoptions']=adoptions
    if component!='full':context.update(component=component,retained_external_changes=retained,
                                      retained_external_schedule_updates=preserved_schedules)
    manifest=install_files(root,pending,revision,source=source,context=context,preimages=preimages)
    manifest_path=journal(root,revision)
    atomic_write(manifest_path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
    def checkpoint():
        schedule_snapshot(root,plan)
        manifest['schedule']=plan
        atomic_write(manifest_path,json.dumps(manifest,indent=2,sort_keys=True)+'\n',mode=0o600)
    if component=='full':apply_schedules(root,plan,checkpoint=checkpoint)
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
