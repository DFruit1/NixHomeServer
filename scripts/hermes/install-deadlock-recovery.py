#!/usr/bin/env python3
"""Install the owner-requested five-minute native recovery intake job.

No model budget increase, worker interruption, phone delivery or NixOS switch.
Existing jobs are edited through the native cron API with private backups.
Use --files-only to update owned helpers without reading or changing cron state
when fleet supervision already owns the maintenance cadence.
"""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys

from hermes_common import atomic_write, backup_file

SOURCE=Path(__file__).resolve().parent
NAME='kanban technical recovery'


def install(root,check=False,files_only=False):
    if root.is_symlink():
        raise ValueError('Recovery install root must not be a symlink')
    if not files_only and (root/'state/fleet/current.json').exists():
        raise ValueError('Fleet supervision owns recovery cadence; use fleet-release.py, never resume a legacy job')
    jobs_file=root/'cron/jobs.json'
    if not files_only:
        jobs=json.loads(jobs_file.read_text()).get('jobs',[])
        matches=[j for j in jobs if j.get('name')==NAME]
        if len(matches)>1:
            raise ValueError('Duplicate recovery jobs; reconcile native identities')
    changed=False
    for name in ('deadlock_recovery.py','feature_flow.py','feature_contract.py','fleet_contract.py','review-verdict-guard.py','capability_recovery.py','hermes_common.py','review-taskforce.py'):
        target=root/'scripts'/name
        if target.is_symlink():
            raise ValueError('Recovery install target must not be a symlink')
        source=(SOURCE/name).read_text()
        if target.exists() and target.read_text()==source:
            continue
        changed=True
        print(('drift: ' if check else 'install: ')+str(target.relative_to(root)))
        if not check:
            backup_file(root,'deadlock-recovery',target)
            atomic_write(target,source)
    if files_only:
        return int(check and changed)
    workdir=str(SOURCE.parent.parent)
    expected=dict(script='deadlock_recovery.py',no_agent=True,workdir=workdir,deliver='local')
    job=matches[0] if matches else None
    mismatch=(job is None or any(job.get(k)!=v for k,v in expected.items())
              or job.get('schedule',{}).get('minutes')!=5 or not job.get('enabled',True))
    if mismatch:
        changed=True
        print('drift: five-minute recovery schedule' if check else 'install: five-minute recovery schedule')
        if not check:
            backup_file(root,'deadlock-recovery',jobs_file)
            command=['hermes','--profile','default','cron']
            if job:
                command+=['edit',job['id'],'--schedule','every 5m']
            else:
                command+=['create','every 5m','--name',NAME]
            command+=['--script','deadlock_recovery.py','--no-agent','--deliver','local','--workdir',workdir]
            subprocess.run(command,check=True,timeout=60,env=dict(os.environ,HERMES_HOME=str(root)))
            if job and not job.get('enabled',True):
                subprocess.run(['hermes','--profile','default','cron','resume',job['id']],check=True,timeout=60,
                               env=dict(os.environ,HERMES_HOME=str(root)))
            readback=[j for j in json.loads(jobs_file.read_text())['jobs'] if j.get('name')==NAME]
            if (len(readback)!=1 or any(readback[0].get(k)!=v for k,v in expected.items())
                    or readback[0].get('schedule',{}).get('minutes')!=5):
                raise ValueError('Recovery cron readback differs')
    return int(check and changed)


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true')
    parser.add_argument('--files-only',action='store_true',
                        help='update/check owned helper files only; preserve all cron state')
    args=parser.parse_args()
    if not args.check and any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_DELEGATED_CHILD_CONTEXT')):
        parser.error('Recovery installation requires the interactive operator')
    sys.exit(install(Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))),args.check,files_only=args.files_only))
