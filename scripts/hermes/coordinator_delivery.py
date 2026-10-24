"""Non-secret input delivery and fixed-recipient coordinator handoffs.

Python reuses native attachments, transactions and Bot Chat's durable queue.
No new backend, provider, worker dispatch or foreign-board mutation is added.
"""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import stat
import tempfile
from contextlib import closing

from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin, require_actor_board
from hermes_cli.nixhomeserver_coordinator_repair import snapshot

MAX_INPUT_BYTES = 256 * 1024 * 1024


def _actor(conn):
    actor = coordinator_origin()
    if actor is None:
        raise ValueError('Authenticated native head-coordinator process required')
    root, board = require_actor_board(conn, actor)
    return root, board, actor


def _parked(conn, task_id, version):
    task, actual = snapshot(conn, task_id)
    if actual != version:
        raise ValueError('Destination changed; inspect its current version')
    if (task['status'] not in {'todo','ready','blocked','scheduled','triage'}
            or any(task[k] is not None for k in ('worker_pid','claim_lock','claim_expires','current_run_id'))
            or conn.execute("SELECT 1 FROM task_runs WHERE task_id=? AND (status IN ('running','pending','claimed','starting') OR (ended_at IS NULL AND outcome IS NULL))", (task_id,)).fetchone()):
        raise ValueError('Local input preparation requires a parked destination without any active worker or lease')
    return task


def _source(conn, root, board, task_id, raw):
    task, _ = snapshot(conn, task_id)
    created = conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='created' ORDER BY id LIMIT 1", (task_id,)).fetchone()
    if task['assignee']=='local-implementer' or (created and json.loads(created['payload'] or '{}').get('assignee')=='local-implementer'):
        raise ValueError('Credential-lane output requires its existing exact approved opaque operation')
    path=Path(raw)
    if not path.is_absolute() or path.resolve(strict=True)!=path:
        raise ValueError('Use one existing canonical source file without symlinks')
    if any(part in {'secrets','.ssh','.git','.gnupg'} or part.startswith('.env') for part in path.parts):
        raise ValueError('Secret, credential and repository-internal paths are not input-delivery sources')
    if path.suffix.lower() in {'.age','.key','.pem','.p12','.pfx'}:
        raise ValueError('Credential material is outside non-secret input delivery')
    roots=[root/'kanban/boards'/board/'attachments'/task_id]
    if task['workspace_path']:
        work=Path(task['workspace_path'])
        if work.resolve(strict=True)!=work:
            raise ValueError('Source workspace must be canonical')
        roots.append(work/'.tmp'/task_id)
        if task['workspace_kind'] in {'scratch','worktree'} or (work/'.git').is_file():
            roots.append(work)
    if not any(path.is_relative_to(base) for base in roots):
        raise ValueError('Source must belong to the named card: attachment, isolated workspace or .tmp/task_id artifact')
    return path


def deliver_file(kb, conn, task_id, *, expected_version, source_task_id, source_path, sha256,
                 classification, filename=None):
    root, board, actor = _actor(conn)
    if classification!='non-secret' or not isinstance(sha256,str) or not re.fullmatch('[a-f0-9]{64}',sha256):
        raise ValueError('Declare non-secret input and its exact recorded SHA256')
    _parked(conn,task_id,expected_version)
    source=_source(conn,root,board,source_task_id,source_path)
    name=kb._safe_attachment_name(filename or source.name)
    created=[];created_dirs=[]
    # Only declared non-secret task artifacts enter this exact disposable tree.
    with tempfile.TemporaryDirectory(prefix='coordinator-input-'+actor['task_id']+'-',dir='/tmp') as scratch:
        frozen=Path(scratch)/'input'
        fd=os.open(source,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        with os.fdopen(fd,'rb') as stream, frozen.open('xb') as out:
            info=os.fstat(stream.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size>MAX_INPUT_BYTES or info.st_nlink!=1:
                raise ValueError('Input must be a regular single-link file of at most 256 MiB')
            digest=hashlib.sha256();size=0
            while chunk:=stream.read(1024*1024):
                size+=len(chunk)
                if size>MAX_INPUT_BYTES:raise ValueError('Input grew beyond its finite limit')
                digest.update(chunk);out.write(chunk)
        if digest.hexdigest()!=sha256:
            raise ValueError('Input bytes do not match the recorded SHA256; nothing delivered')
        receipt=dict(version=1,kind='non-secret-task-input',board=board,task_id=task_id,
                     source_task_id=source_task_id,source_path=str(source),sha256=sha256,size=size,filename=name,
                     actor_task=actor['task_id'],actor_run=actor['run_id'])
        try:
            with kb.write_txn(conn):
                require_actor_board(conn,actor)
                task=_parked(conn,task_id,expected_version)
                old=conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='coordinator_input_delivered' "
                    "AND json_extract(payload,'$.sha256')=? AND json_extract(payload,'$.source_task_id')=? "
                    "AND json_extract(payload,'$.filename')=? ORDER BY id DESC LIMIT 1",
                    (task_id,sha256,source_task_id,name)).fetchone()
                if old:
                    previous=json.loads(old['payload'])
                    attachment=kb.get_attachment(conn,previous.get('attachment_id'))
                    stored=Path(previous['stored_path'])
                    if attachment and stored.is_file() and not stored.is_symlink():
                        with stored.open('rb') as existing:
                            if hashlib.file_digest(existing,'sha256').hexdigest()==sha256:
                                return dict(task_id=task_id,attachment_id=attachment.id,reused=True,
                                    **{k:previous[k] for k in ('kind','stored_path','sha256','size')})
                if size<=kb.KANBAN_ATTACHMENT_MAX_BYTES:
                    attachment=kb.store_attachment_bytes(conn,task_id,name,frozen.read_bytes(),
                        board=board,uploaded_by='head-coordinator')
                    receipt['stored_path']=kb.get_attachment(conn,attachment).stored_path
                    created.append(Path(receipt['stored_path']))
                else:
                    if not task['workspace_path']:
                        raise ValueError('Large input needs the existing prepared destination workspace')
                    work=Path(task['workspace_path'])
                    if not work.is_dir() or work.resolve()!=work:
                        raise ValueError('Destination workspace is missing or noncanonical')
                    folder=work/'.tmp'/task_id/'inputs'/sha256
                    for directory in [work/'.tmp',work/'.tmp'/task_id,work/'.tmp'/task_id/'inputs',folder]:
                        if directory.is_symlink():raise ValueError('Input destination cannot contain symlinks')
                        try:directory.mkdir(mode=0o700)
                        except FileExistsError:pass
                        else:created_dirs.append(directory)
                    target=folder/name
                    if target.exists():
                        if target.is_symlink():
                            raise ValueError('Existing input differs; preserve it and choose a corrected binding')
                        with target.open('rb') as existing:
                            if hashlib.file_digest(existing,'sha256').hexdigest()!=sha256:
                                raise ValueError('Existing input differs; preserve it and choose a corrected binding')
                    else:
                        with tempfile.NamedTemporaryFile(prefix='.input-',dir=folder,delete=False) as output, frozen.open('rb') as stream:
                            staging=Path(output.name);created.append(staging)
                            shutil.copyfileobj(stream,output,1024*1024);output.flush();os.fsync(output.fileno())
                        os.link(staging,target);created.append(target)
                        staging.unlink()
                    receipt['stored_path']=str(target)
                    receipt['kind']='non-secret-task-local-input'
                    attachment=kb.store_attachment_bytes(conn,task_id,name+'.input.json',
                        json.dumps(receipt,sort_keys=True).encode(),board=board,uploaded_by='head-coordinator')
                    created.append(Path(kb.get_attachment(conn,attachment).stored_path))
                receipt['attachment_id']=attachment
                kb._append_event(conn,task_id,'coordinator_input_delivered',receipt)
        except BaseException:
            for path in reversed(created):path.unlink(missing_ok=True)
            for directory in reversed(created_dirs):
                try:directory.rmdir()
                except OSError:pass
            raise
    return dict(task_id=task_id,attachment_id=attachment,**{k:receipt[k] for k in ('kind','stored_path','sha256','size')})


def route_request(kb, conn, *, target_board, message, target_task_id=None, delivery=None):
    root, board, actor = _actor(conn)
    if not isinstance(target_board,str) or not re.fullmatch('[A-Za-z0-9_-]+',target_board) or target_board==board:
        raise ValueError('Name a different existing owning board; use native management on this board')
    if not isinstance(message,str) or not message.strip() or len(message)>8000:
        raise ValueError('Supply one bounded concrete owning-board request, not authority or approval')
    path=root/'kanban/boards'/target_board/'kanban.db'
    if (not path.is_file() or path.is_symlink() or path.parent.resolve()!=path.parent
            or not path.resolve().is_relative_to((root/'kanban/boards').resolve())
            or not path.with_name('board.json').is_file()):
        raise ValueError('Owning board is not registered; no request queued')
    if target_task_id is not None:
        with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True)) as other:
            other.execute('PRAGMA query_only=ON')
            target=other.execute('SELECT assignee,status FROM tasks WHERE id=?',(target_task_id,)).fetchone()
            if not target or target[0]!='head-coordinator' or target[1] in {'done','archived'}:
                raise ValueError('Name the existing open owning-board coordinator task, or omit it for scoped admission')
    envelope=dict(source_board=board,source_task_id=actor['task_id'],source_run_id=actor['run_id'],
                  target_board=target_board,target_task_id=target_task_id,request=message.strip())
    key=hashlib.sha256(json.dumps(envelope,sort_keys=True).encode()).hexdigest()
    if delivery is None:
        from cron import bot_chat_delivery as delivery
    content=('Internal head-coordinator owning-board request. Check current evidence and your own '
             'authority; this is not owner approval. Reuse existing owners, preserve gates and '
             'budgets, and report actual results to the source card.\n\n'+json.dumps(envelope,sort_keys=True))
    require_actor_board(conn,actor)
    record=delivery.defer(key,{'id':'coordinator-handoff','name':'Owning-board request','execution_id':key},
                          content,'head-coordinator',root/'profiles/head-coordinator')
    receipt=dict(request_id=key,target_board=target_board,target_task_id=target_task_id,
                 status=record['status'],completion='unverified; queued request is not execution or acceptance')
    with kb.write_txn(conn):
        require_actor_board(conn,actor)
        kb._append_event(conn,actor['task_id'],'coordinator_handoff_requested',
                         {**receipt,'source_board':board,'source_task_id':actor['task_id'],
                          'source_run_id':actor['run_id'],'request':message.strip()},run_id=actor['run_id'])
    return receipt
