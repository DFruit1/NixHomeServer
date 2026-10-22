#!/usr/bin/env python3
"""Install metadata-only Hermes evidence without changing models or credentials.

Python glue reuses Hermes' YAML dependency and native Python plugin interface.
All configs are checked before writing; previous bytes are private durable
backups. Configs are locked and updated in place, without secret-bearing temps.
"""
import argparse
import fcntl
import os
from pathlib import Path
import re
import sys

import yaml

from hermes_config import document
from hermes_common import backup_file

SOURCE=Path(__file__).resolve().parent
PLUGIN='runtime-evidence'


def enable(text):
    data=document(text)
    plugins=data.get('plugins',{})
    enabled=plugins.get('enabled',[])
    disabled=plugins.get('disabled',[])
    if 'observability/langfuse' not in enabled or 'observability/langfuse' in disabled:
        return text
    if PLUGIN in disabled:
        raise ValueError('runtime-evidence is explicitly disabled; reconcile before installing')
    if PLUGIN in enabled:
        return text
    if not isinstance(enabled,list) or any(not isinstance(x,str) for x in enabled):
        raise ValueError('Expected a plugin enabled list')
    tree=yaml.compose(text)
    node=next(v for k,v in tree.value if k.value=='plugins')
    node=next(v for k,v in node.value if k.value=='enabled')
    end=node.end_mark.index if node.flow_style else node.value[-1].end_mark.index
    desired=enabled+[PLUGIN]
    rendered=yaml.safe_dump(desired,default_flow_style=True,width=100000).strip()
    updated=text[:node.start_mark.index]+rendered+text[end:]
    data['plugins']['enabled']=desired
    if document(updated)!=data:
        raise ValueError('Plugin enable would change unrelated settings')
    return updated


def install(root,check=False):
    pending={}
    pending[root/'scripts/hermes-review-evidence.md']=(SOURCE/'instructions/review-evidence.md').read_text()
    for profile in ('feature-reviewer','project-auditor'):
        reviewer=root/'profiles'/profile/'SOUL.md'
        if not reviewer.exists():continue
        text=reviewer.read_text()
        start,end='<!-- hermes-review-taskforce -->','<!-- /hermes-review-taskforce -->'
        if text.count(start)!=1 or text.count(end)!=1 or text.index(start)>text.index(end):
            raise ValueError(f'{profile} role markers are ambiguous; preserve and reconcile them')
        role=(SOURCE/'taskforce'/f'{profile}.md').read_text().rstrip()
        pending[reviewer]=re.sub(re.escape(start)+r'.*?'+re.escape(end),
                                 lambda _:start+'\n'+role+'\n'+end,text,flags=re.S)
    configs=[root/'config.yaml',*sorted((root/'profiles').glob('*/config.yaml'))]
    for path in configs:
        if not path.exists():continue
        if path.is_symlink():raise ValueError('Refusing a symlink configuration')
        old=path.read_text()
        updated=enable(old)
        plugins=document(updated).get('plugins',{})
        if PLUGIN in plugins.get('enabled',[]) and PLUGIN not in plugins.get('disabled',[]):
            for name in ('__init__.py','plugin.yaml'):
                pending[path.parent/'plugins'/PLUGIN/name]=(SOURCE/PLUGIN/name).read_text()
        if updated!=old:pending[path]=updated
    for target in (root/'scripts/kanban-performance.py',root/'profiles/board-steward/scripts/kanban-performance.py'):
        if target.exists():pending[target]=(SOURCE/'kanban-performance.py').read_text()
    # Preflight all files and retain their exact input to detect another writer.
    changes=[]
    for path,text in pending.items():
        if path.is_symlink():raise ValueError('Refusing a symlink install target')
        old=path.read_text() if path.exists() else None
        if old!=text:changes.append((path,old,text))
    for path,old,text in changes:
        print(f'{"drift" if check else "install"}: {path.relative_to(root)}')
        if check:continue
        path.parent.mkdir(parents=True,exist_ok=True)
        with path.open('r+' if old is not None else 'x+') as stream:
            fcntl.flock(stream,fcntl.LOCK_EX|fcntl.LOCK_NB)
            if stream.read()!=(old or ''):
                raise ValueError('Install target changed during preflight; retry after its writer finishes')
            if old is not None:backup_file(root,'runtime-evidence',path)
            stream.seek(0);stream.write(text);stream.truncate();stream.flush();os.fsync(stream.fileno())
    return int(check and bool(changes))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check',action='store_true')
    args=parser.parse_args()
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))),args.check))
    except (ValueError,OSError) as exc:
        print(f'runtime evidence install failed ({type(exc).__name__})',file=sys.stderr)
        sys.exit(2)
