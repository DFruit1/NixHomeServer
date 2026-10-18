#!/usr/bin/env python3
"""Install bounded scheduled inspections without model, credential or lane changes.

Python glue reuses native cron edits, exact source adapters and private backups.
It never runs a job, sends a message, edits a card or activates NixOS.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys

from cron_runtime_adapter import adapt,EDITS
from hermes_common import backup_file

SOURCE=Path(__file__).resolve().parent
JOBS=(
    ('head-coordinator','kanban board health',10,12,180,'monitor'),
    ('head-coordinator','kanban idle recovery',10,10,180,'monitor'),
    ('board-steward','hermes daily steward',10,12,180,'daily'),
    ('board-steward','steward opportunity scan',6,6,90,'monitor'),
    ('board-steward','steward stall follow-up',8,8,120,'stall'),
)


def instructions(text):
    start,end='<!-- hermes-cron-policy -->','<!-- /hermes-cron-policy -->'
    block=(start+'\nScheduled inspections have enforced tool/turn/runtime budgets. Read '
           '~/.hermes/scripts/hermes-cron-policy.md for their limits and outcome rules. '
           'The scheduler supplies authoritative UTC due-inspection times; these are not '
           'delivery receipts. Do not reconstruct reminder clocks from local run headers. '
           'Preserve original role restrictions, approval gates and existing dispositions.\n'+end)
    if start not in text and end not in text:return text.rstrip()+'\n\n'+block+'\n'
    if text.count(start)!=1 or text.count(end)!=1 or text.index(start)>text.index(end):
        raise ValueError('Ambiguous cron policy markers')
    return re.sub(re.escape(start)+r'.*?'+re.escape(end),lambda _:block,text,flags=re.S)


def changes(root):
    pending={};commands=[];manifest={'version':1,'jobs':{}}
    prompts={'hermes daily steward':'daily-steward-prompt.txt',
             'steward opportunity scan':'steward-opportunity-prompt.txt',
             'steward stall follow-up':'steward-stall-prompt.txt'}
    for role,name,turns,tools,seconds,kind in JOBS:
        home=root/'profiles'/role
        jobs=json.loads((home/'cron/jobs.json').read_text())['jobs']
        matches=[j for j in jobs if j.get('name')==name]
        if len(matches)!=1:raise ValueError('Expected one existing job per owned schedule')
        job=matches[0]
        if not re.fullmatch(r'[a-f0-9]+',job['id']) or job['id'] in manifest['jobs']:
            raise ValueError('Cron job identities must be unique and native')
        manifest['jobs'][job['id']]={'profile':role,'turns':turns,'tools':tools,'seconds':seconds,'kind':kind}
        if name in prompts:
            prompt=(SOURCE/prompts[name]).read_text()
            continuity=name=='hermes daily steward'
            if job.get('prompt')!=prompt or continuity!=('self' in (job.get('context_from') or [])):
                commands.append((home/'cron/jobs.json',['hermes','--profile',role,'cron','edit',job['id'],
                    '--prompt',prompt,'--continuity' if continuity else '--no-continuity']))
    pending[root/'scripts/hermes-cron-policy.json']=json.dumps(manifest,indent=2,sort_keys=True)+'\n'
    pending[root/'scripts/hermes-cron-policy.md']=(SOURCE/'instructions/cron-policy.md').read_text()
    native=root/'hermes-agent'
    for name in EDITS:pending[native/name]=adapt(name,(native/name).read_text())
    # Install the dependency first; active scheduler turns may import it on demand.
    for source,target in (('capability_recovery.py','nixhomeserver_capability_recovery.py'),
                          ('cron_policy.py','nixhomeserver_cron_policy.py'),('cron_stall.py','nixhomeserver_cron_stall.py')):
        pending[native/'cron'/target]=(SOURCE/source).read_text()
    for role in ('head-coordinator','board-steward'):
        soul=root/'profiles'/role/'SOUL.md';pending[soul]=instructions(soul.read_text())
    copies={'review-taskforce-tick.sh','cron_sweep.py','cron_policy.py','cron_stall.py','capability_recovery.py',
            'steward-opportunity-scan.py','kanban-daily-steward.py','kanban-board-health.sh','kanban-performance.py'}
    for name in sorted(copies,key=lambda name:(name!='capability_recovery.py',name)):
        pending[root/'scripts'/name]=(SOURCE/name).read_text()
        for role in ('head-coordinator','board-steward'):
            target=root/'profiles'/role/'scripts'/name
            if target.exists() or (name=='capability_recovery.py' and role=='board-steward'):
                pending[target]=(SOURCE/name).read_text()
    return pending,commands


def install(root,check=False):
    pending,commands=changes(root)
    updates=[]
    for path,text in pending.items():
        if path.is_symlink():raise ValueError('Refusing symlink target')
        old=path.read_text() if path.exists() else None
        if old!=text:updates.append((path,old,text))
    for path,old,text in updates:
        print(('drift: ' if check else 'install: ')+str(path.relative_to(root)))
        if check:continue
        path.parent.mkdir(parents=True,exist_ok=True)
        fd=os.open(path,os.O_RDWR|os.O_NOFOLLOW|(os.O_CREAT|os.O_EXCL if old is None else 0),0o700 if path.suffix=='.sh' else 0o600)
        with os.fdopen(fd,'r+') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if stream.read()!=(old or ''):raise ValueError('Installation input changed')
            if old is not None:backup_file(root,'cron-policy',path)
            stream.seek(0);stream.write(text);stream.truncate();stream.flush();os.fsync(stream.fileno())
    for path,command in commands:
        print(('drift: ' if check else 'edit: ')+'existing cron '+command[5])
        if check:continue
        backup_file(root,'cron-policy',path)
        subprocess.run(command,check=True,timeout=60,env={**os.environ,'HERMES_HOME':str(root),'HERMES_ROOT':str(root)},stdout=subprocess.DEVNULL)
    return int(check and bool(updates or commands))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--check',action='store_true');args=parser.parse_args()
    if not args.check and any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_DELEGATED_CHILD_CONTEXT')):
        parser.error('Scheduled inspection installation requires the interactive operator')
    try:sys.exit(install(Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))),args.check))
    except (ValueError,OSError,TypeError,subprocess.SubprocessError):
        print('Cron policy installation failed; preserve current state and reconcile drift',file=sys.stderr);sys.exit(2)
