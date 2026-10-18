"""Read-only, bounded evidence packets and deterministic inspection backoff.

Only the scheduler updates its journal after an actual successful model pass.
Inspection timestamps are not notification-delivery receipts or permissions.
"""
from contextlib import closing
import datetime as dt
import hashlib
import json
import sqlite3
import time


def utc(value):return dt.datetime.fromtimestamp(value,dt.timezone.utc).isoformat(timespec='seconds')


def collect(root,state,now):
    boards=sorted(p for p in (root/'kanban/boards').glob('*/board.json') if not p.parent.name.startswith(('_','.')))
    if not boards:raise ValueError('No active board manifests')
    issues=state.get('issues',{});due=[];live=set()
    for manifest in boards:
        board=manifest.parent.name;path=manifest.with_name('kanban.db')
        with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=.2)) as db:
            db.row_factory=sqlite3.Row;db.execute('PRAGMA query_only=ON');db.execute('BEGIN')
            deadline=time.monotonic()+2
            db.set_progress_handler(lambda:int(time.monotonic()>deadline),1000)
            columns={r[1] for r in db.execute('PRAGMA table_info(tasks)')}
            ownership=','.join(key if key in columns else 'NULL AS '+key for key in ('created_by','created_at'))
            rows=db.execute("SELECT id,status,assignee,block_kind,consecutive_failures,block_recurrences,"+ownership+" FROM tasks "
                            "WHERE status NOT IN ('done','archived') ORDER BY id LIMIT 1001").fetchall()
            if len(rows)>1000:raise ValueError('Open task inspection bound exceeded')
            for row in rows:
                task=dict(row);key=board+':'+task['id'];live.add(key)
                run=db.execute('SELECT status,outcome,ended_at,metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                               (task['id'],)).fetchone()
                owner=db.execute("SELECT id,body,created_at FROM task_comments WHERE task_id=? AND author IN ('desktop','user','owner') ORDER BY id DESC LIMIT 1",
                                 (task['id'],)).fetchone()
                outcome=run['outcome'] or run['status'] if run else None
                failed=outcome in {'crashed','failed','timed_out','spawn_failed','gave_up','blocked'}
                unfulfilled=bool(owner and (not run or owner['created_at']>(run['ended_at'] or 0)))
                owner_requested=task['created_by'] in {'desktop','user','owner','owner-agent'}
                if not (task['status']=='blocked' or failed or unfulfilled or owner_requested
                        or (task['block_recurrences'] or 0)>=2 or (task['consecutive_failures'] or 0)>=2):continue
                metadata=json.loads(run['metadata'] or '{}') if run else {}
                if not isinstance(metadata,dict):raise ValueError('Unsupported run metadata')
                evidence={k:metadata.get(k) for k in ('verdict','revision','failure_category')}
                evidence['verdict']=evidence['verdict'] if evidence['verdict'] in ('accept','request-changes') else None
                version=[task['status'],task['assignee'],task['block_kind'],outcome,evidence,
                         [owner['id'],hashlib.sha256(owner['body'].encode()).hexdigest()] if owner else None]
                digest=hashlib.sha256(json.dumps(version,sort_keys=True).encode()).hexdigest()
                previous=issues.get(key,{})
                if previous.get('version')==digest and now<previous.get('next_due',0):continue
                links=db.execute('SELECT parent_id,child_id FROM task_links WHERE parent_id=? OR child_id=? LIMIT 21',
                                 (task['id'],task['id'])).fetchall()
                due.append({'key':key,'version':digest,'status':task['status'],'assignee':task['assignee'],
                    'reason':'material_change' if previous.get('version')!=digest else 'reminder_due',
                    'block_kind':task['block_kind'],'last_outcome':outcome,'verdict':evidence['verdict'],
                    'owner_comment_id':owner['id'] if owner else None,
                    'owner_requested':owner_requested,
                    'last_run_utc':utc(run['ended_at']) if run and run['ended_at'] else None,
                    'last_inspected_utc':utc(previous['last_processed_at']) if previous.get('last_processed_at') else None,
                    'next_due_utc':utc(previous['next_due']) if previous.get('version')==digest and previous.get('next_due') else None,
                    'links':[list(link) for link in links[:20]],'links_truncated':len(links)>20,
                    '_order':(previous.get('next_due',0),key)})
    # Resolved tasks leave the scheduler ledger; no card, memory or report is written.
    state['issues']={key:value for key,value in issues.items() if key in live}
    selected=sorted(due,key=lambda item:item['_order'])[:3]
    for item in selected:item.pop('_order')
    return selected


def processed(state,focus,now):
    issues=state.setdefault('issues',{})
    for item in focus:
        old=issues.get(item['key'],{})
        stage=min(3,old.get('stage',0)+1) if old.get('version')==item['version'] else 1
        issues[item['key']]={'version':item['version'],'stage':stage,'last_processed_at':now,
                             'next_due':now+(8 if stage==1 else 16 if stage==2 else 24)*3600}


def packet(focus,now):
    return ('CANONICAL INSPECTION TIME UTC: '+utc(now)+'\n'
            'Scheduler-selected due evidence follows. Times are inspections, not delivery receipts. '
            'Use only these UTC times for reminder reasoning. Investigate these bounded questions, '
            'not the whole fleet. Recheck original instructions and current dispositions; '
            'routine acknowledgments and routing are not resolution.\n'+json.dumps(focus,sort_keys=True))
