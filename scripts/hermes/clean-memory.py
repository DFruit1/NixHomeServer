#!/usr/bin/env python3
"""Apply reviewed memory cleanup and retire explicitly identified proposals.

Python operations glue uses native memory delimiters/locks and private backups.
No model calls, recursive deletion or live-session database changes.
"""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import sys

from hermes_common import backup_file
from reviewed_memory_cleanup import REVIEWED, clean


def proposal(root, reference):
    parts=reference.split(':')
    if (len(parts)!=3 or not re.fullmatch(r'[a-z][a-z0-9-]+',parts[0])
            or not re.fullmatch(r'[a-f0-9]{8}',parts[1]) or not re.fullmatch(r'[a-f0-9]{64}',parts[2])):
        raise ValueError('Proposal identity must be profile:id:sha256')
    profile,identity,digest=parts
    path=root/'profiles'/profile/'pending/memory'/(identity+'.json')
    if path.is_symlink():raise ValueError('Refusing symlink proposal')
    if not path.exists():
        archive=root/'backups/memory-policy'/hashlib.sha256(str(path).encode()).hexdigest()[:12]/digest
        if archive.is_file() and hashlib.sha256(archive.read_bytes()).hexdigest()==digest:return None
        raise ValueError('Proposal is missing without its verified private archive')
    content=path.read_bytes()
    if hashlib.sha256(content).hexdigest()!=digest:raise ValueError('Reviewed proposal changed; do not retire it')
    data=json.loads(content)
    if data.get('id')!=identity or data.get('subsystem')!='memory' or data.get('origin')!='background_review':
        raise ValueError('Not the reviewed background-memory proposal')
    return path,content


def cleanup(root, apply=False, proposals=()):
    changes=[]
    for profile,filename in REVIEWED:
        path=root/'profiles'/profile/'memories'/filename
        if path.is_symlink():raise ValueError('Refusing symlink memory')
        if not path.exists():continue
        old=path.read_text()
        updated=clean(profile,filename,old)
        if old.strip()!=updated:changes.append((path,old,updated))
    retired=[item for reference in proposals if (item:=proposal(root,reference)) is not None]
    for path,old,updated in changes:
        print(f'{"clean" if apply else "would clean"}: {path.relative_to(root)} ({len(old)} -> {len(updated)} chars)')
        if not apply:continue
        with path.with_suffix(path.suffix+'.lock').open('a') as lock:
            fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
            with path.open('r+') as stream:
                if stream.read()!=old:raise ValueError('Memory changed during preflight; preserve the newer entry')
                backup_file(root,'memory-policy',path)
                stream.seek(0);stream.write(updated);stream.truncate();stream.flush();os.fsync(stream.fileno())
    for path,old in retired:
        print(f'{"archive" if apply else "would archive"}: {path.relative_to(root)}')
        if not apply:continue
        if path.read_bytes()!=old:raise ValueError('Proposal changed during preflight')
        backup=backup_file(root,'memory-policy',path)
        if backup.read_bytes()!=old:raise ValueError('Proposal backup verification failed')
        path.unlink()
    return int(not apply and bool(changes or retired))


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--retire-proposal',action='append',default=[])
    args=parser.parse_args()
    try:
        if args.apply and any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK','HERMES_KANBAN_RUN_ID','HERMES_DELEGATED_CHILD_CONTEXT')):
            parser.error('Global memory maintenance requires the interactive operator')
        sys.exit(cleanup(Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))),args.apply,args.retire_proposal))
    except (ValueError,OSError,TypeError) as exc:
        print(f'Memory cleanup refused ({type(exc).__name__}); memory and proposal text suppressed',file=sys.stderr)
        sys.exit(2)
