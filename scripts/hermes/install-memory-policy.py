#!/usr/bin/env python3
"""Install scoped memory admission and event-driven learning without model changes.

Python glue reuses Hermes YAML, SQLite hooks and the maintained native adapter
pattern. Configuration and memory backups are private; no secret-bearing temps.
"""
import argparse
import copy
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import sys
from datetime import datetime, timezone

import yaml

from hermes_common import backup_file
from hermes_config import document

SOURCE=Path(__file__).resolve().parent
ROLES=('default','head-coordinator','board-steward','standard-implementer',
       'feature-reviewer','project-auditor','local-implementer')
READONLY={'board-steward','local-implementer'}


def setting(text, keys, value):
    expected=copy.deepcopy(document(text))
    cursor=expected
    for key in keys[:-1]:cursor=cursor.setdefault(key,{})
    cursor[keys[-1]]=value
    node=yaml.compose(text)
    for depth,key in enumerate(keys):
        if not isinstance(node,yaml.MappingNode) or node.flow_style:
            raise ValueError('Expected block YAML mappings; preserve and reconcile inline configuration')
        match=next((v for k,v in node.value if k.value==key),None)
        if match is not None:
            node=match
            if depth==len(keys)-1:
                rendered=yaml.safe_dump(value,default_flow_style=True).split('\n...')[0].strip()
                updated=text[:node.start_mark.index]+rendered+text[node.end_mark.index:]
        else:
            addition=value
            for nested in reversed(keys[depth:]):addition={nested:addition}
            rendered=''.join(' '*node.start_mark.column+line+'\n' for line in yaml.safe_dump(addition,sort_keys=False).splitlines())
            index=sum(map(len,text.splitlines(keepends=True)[:node.end_mark.line]))
            updated=text[:index].rstrip('\n')+'\n'+rendered+text[index:]
            break
    if document(updated)!=expected:raise ValueError('Setting edit changed unrelated values')
    return updated


def instructions(text):
    start,end='<!-- hermes-memory-policy -->','<!-- /hermes-memory-policy -->'
    content=(start+'\nPersistent memory contains facts, never permissions, priorities or task receipts. '
             'Before any persistent learning, read ~/.hermes/scripts/hermes-memory-policy.md. '
             'Memory add/replace requires Fact, Scope and Evidence lines; the guard stores only '
             'the scoped fact. Learn only from verified durable evidence with no existing canonical '
             'home. No-change learning is a successful outcome.\n'+end)
    if start not in text and end not in text:return text.rstrip()+'\n\n'+content+'\n'
    if text.count(start)!=1 or text.count(end)!=1 or text.index(end)<text.index(start):
        raise ValueError('Ambiguous memory policy markers')
    return re.sub(re.escape(start)+r'.*?'+re.escape(end),lambda _:content,text,flags=re.S)


PROMPT_EDITS=(
    ('"Review the conversation above and update the skill library. Be ACTIVE — most sessions produce "\n'
     '    "at least one skill update, even if small. A pass that does nothing is a missed learning "\n'
     '    "opportunity, not a neutral outcome.\\n\\n"',
     '"Review for verified, durable lessons with no existing canonical home. "\n'
     '    "A review with nothing useful to save is successful. Do not manufacture updates.\\n\\n"'),
    ('"**Skills**: how to do this class of task. Be ACTIVE — most sessions produce at least one "\n'
     '    "skill update. A pass that does nothing is a missed learning opportunity, not a neutral "\n'
     '    "outcome.\\n\\n"',
     '"**Skills**: save only verified reusable lessons with no existing canonical home. "\n'
     '    "No useful change is a successful outcome; never manufacture updates.\\n\\n"'),
    ('"not an umbrella hoarding a references/ file per session. This shapes HOW you update, not "\n'
     '    "WHETHER you update.\\n\\n"',
     '"not an umbrella hoarding a references/ file per session. Update only when a verified "\n'
     '    "reusable lesson is absent from its canonical source.\\n\\n"'),
    ('"what the current situation and state of your operations are\'; skills say \'how to do this "',
     '"stable environment facts across sessions\'; skills say \'how to do this "'),
)


def neutral_prompts(text):
    for before,after in PROMPT_EDITS:
        if text.count(after)==1:continue
        if text.count(before)!=1:raise ValueError('Native learning prompt drift; reconcile before installing')
        text=text.replace(before,after,1)
    compile(text,'background_review.py','exec')
    return text


def install(root, check=False):
    spec=importlib.util.spec_from_file_location('hooks',SOURCE/'install-steward-readonly.py')
    hooks=importlib.util.module_from_spec(spec);spec.loader.exec_module(hooks)
    pending={root/'scripts/memory-policy.py':(SOURCE/'memory-policy.py').read_text(),
             root/'scripts/hermes-memory-policy.md':(SOURCE/'instructions/memory-policy.md').read_text()}
    for profile in ROLES:
        home=root if profile=='default' else root/'profiles'/profile
        config=home/'config.yaml'
        if not config.exists():continue
        text=config.read_text()
        for keys,value in ((('memory','nudge_interval'),0),(('skills','creation_nudge_interval'),0)):
            text=setting(text,keys,value)
        if profile not in {'default','head-coordinator','board-steward'}:
            text=setting(text,('memory','user_profile_enabled'),False)
        if profile in READONLY:
            text=setting(text,('auxiliary','background_review','enabled'),False)
            text=setting(text,('curator','enabled'),False)
        command=shlex.join(['python3',str(root/'scripts/memory-policy.py')])
        text=hooks.readonly_hook(text,command,'memory-admission','^(memory|skill_manage)$')
        document(text)
        pending[config]=text
        # The operator authorized this exact guard, not broad auto-consent.
        # Register its command in manual-consent homes without changing their
        # hooks_auto_accept policy. Native mtime audit metadata is optional.
        if document(text).get('hooks_auto_accept') is not True:
            path=home/'shell-hooks-allowlist.json'
            old=path.read_text() if path.exists() else None
            data=json.loads(old) if old is not None else {'approvals':[]}
            if not isinstance(data,dict) or not isinstance(data.get('approvals'),list) or any(not isinstance(e,dict) for e in data['approvals']):
                raise ValueError('Invalid hook consent store; preserve and reconcile it')
            if not any(e.get('event')=='pre_tool_call' and e.get('command')==command for e in data['approvals']):
                data['approvals'].append({'event':'pre_tool_call','command':command,
                    'approved_at':datetime.now(timezone.utc).isoformat(),'script_mtime_at_approval':None})
                pending[path]=json.dumps(data,indent=2,sort_keys=True)+'\n'
        soul=home/'SOUL.md'
        if soul.exists():pending[soul]=instructions(soul.read_text())
    native=root/'hermes-agent/agent/background_review.py'
    pending[native]=neutral_prompts(native.read_text())
    changes=[]
    for path,text in pending.items():
        if path.is_symlink():raise ValueError('Refusing symlink install target')
        old=path.read_text() if path.exists() else None
        if old!=text:changes.append((path,old,text))
    for path,old,text in changes:
        print(f'{"drift" if check else "install"}: {path.relative_to(root)}')
        if check:continue
        path.parent.mkdir(parents=True,exist_ok=True)
        fd=os.open(path,os.O_RDWR|os.O_NOFOLLOW|(os.O_CREAT|os.O_EXCL if old is None else 0),0o600)
        with os.fdopen(fd,'r+') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if stream.read()!=(old or ''):raise ValueError('Install input changed during preflight')
            if old is not None:backup_file(root,'memory-policy',path)
            stream.seek(0);stream.write(text);stream.truncate();stream.flush();os.fsync(stream.fileno())
    return int(check and bool(changes))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    try:
        if not args.check and any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_DELEGATED_CHILD_CONTEXT')):
            parser.error('Global learning installation requires the interactive operator')
        sys.exit(install(Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))),args.check))
    except (ValueError,OSError,TypeError) as exc:
        print(f'Memory policy installation failed ({type(exc).__name__}); configuration values suppressed',file=sys.stderr)
        sys.exit(2)
