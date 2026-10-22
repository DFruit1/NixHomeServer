#!/usr/bin/env python3
"""Five-minute deterministic intake for native coordinator recovery workers.

The collector reads boards query-only. Its sole board effect is native,
idempotent card creation; every repair runs under a real dispatcher claim.
"""
import argparse
from contextlib import closing
import fcntl
import importlib.util
import json
import os
from pathlib import Path
import sqlite3
import stat
import time

import capability_recovery as recovery
from feature_flow import observe_features
from hermes_common import atomic_write

CREATOR = 'deadlock-recovery-monitor'
MAX_ATTEMPTS = 3
BACKOFF = (300, 900, 3600)


def intake_journal(root, dry_run):
    journal=root/'runtime/deadlock-intake'
    for path in (root/'runtime',journal):
        if not dry_run:
            path.mkdir(mode=0o700,exist_ok=True)
        if path.exists() or path.is_symlink():
            info=path.lstat()
            if (not stat.S_ISDIR(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o022):
                raise ValueError('Recovery journal must be owned and private')
    if dry_run:
        return journal,None
    fd=os.open(journal/'operation.lock',os.O_CREAT|os.O_RDWR|os.O_NOFOLLOW,0o600)
    info=os.fstat(fd)
    if not stat.S_ISREG(info.st_mode) or info.st_uid!=os.getuid() or info.st_mode & 0o077 or info.st_nlink!=1:
        os.close(fd);raise ValueError('Recovery lock must be a private regular file')
    try:
        fcntl.flock(fd,fcntl.LOCK_EX|fcntl.LOCK_NB)
    except BaseException:
        os.close(fd);raise
    return journal,fd


def observe(root, board, now=None):
    now=int(time.time()) if now is None else now
    path = root / 'kanban/boards' / board / 'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=2)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON'); db.execute('BEGIN')
        tasks = [dict(r) for r in db.execute("SELECT * FROM tasks WHERE status NOT IN ('done','archived') LIMIT 1001")]
        if len(tasks) > 1000:
            raise ValueError('Board exceeds bounded recovery observation')
        if any(t.get('created_by') == CREATOR and
               (t['status']=='running' or t.get('worker_pid') is not None or t.get('claim_lock') is not None
                or (t['status'] not in {'blocked','triage'} and now-int(t['created_at'])<900)) for t in tasks):
            return []  # One actual recovery worker/audit per board, including pending dispatch.
        holds = {h['task_id']:h for h in recovery.read_board(db,root,board,recovery.helper_identity(root))}
        candidates = []
        for task in tasks:
            tid = task['id']
            if (task.get('created_by') == CREATOR or task['status'] not in recovery.PARKED or task['block_kind'] == 'needs_input'
                    or '[FEATURE TRACKER' in task['title'].upper()
                    or any(task.get(k) is not None for k in ('worker_pid','claim_lock','claim_expires'))):
                continue
            if db.execute("SELECT 1 FROM task_runs WHERE task_id=? AND (status IN ('running','pending','claimed','starting') OR (ended_at IS NULL AND outcome IS NULL)) LIMIT 1",(tid,)).fetchone():
                continue
            run = db.execute('SELECT status,outcome,metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(tid,)).fetchone()
            parents = [dict(r) for r in db.execute('SELECT p.id,p.status,p.assignee,p.body FROM task_links l JOIN tasks p ON p.id=l.parent_id WHERE l.child_id=? ORDER BY p.id',(tid,))]
            hold = holds.get(tid)
            failure = bool(run and {run['status'],run['outcome']} & {'failed','crashed','timed_out','spawn_failed','gave_up'})
            # A waiting consumer can describe an input it requires from a
            # downstream producer. Ask a native coordinator to qualify this;
            # the collector never decides whether to remove a dependency.
            downstream = [r[0] for r in db.execute('SELECT child_id FROM task_links WHERE parent_id=? ORDER BY child_id',(tid,))]
            semantic = [child for child in downstream if child in (task['body'] or '')]
            if hold and hold['supplier'] == 'owner':
                continue
            if hold:
                kind = 'technical-hold'
            elif failure:
                kind = 'failed-lifecycle'
            elif semantic and task['status'] == 'todo':
                kind = 'possible-dependency-deadlock'
            else:
                continue
            state = {k:task.get(k) for k in ('id','body','assignee','skills','max_runtime_seconds','max_retries','workspace_path','status','block_kind')}
            parent_results=[]
            for parent in parents:
                latest=db.execute('SELECT metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(parent['id'],)).fetchone()
                meta=json.loads(latest['metadata'] or '{}') if latest else {}
                parent_results.append([parent['id'],{k:meta[k] for k in ('verdict','revision','checks','requested_changes','missing_inputs') if k in meta}])
            metadata=json.loads(run['metadata'] or '{}') if run else {}
            semantic_result={k:metadata[k] for k in ('verdict','revision','checks','requested_changes','missing_inputs','independence') if k in metadata}
            state.update(parents=parents, downstream=downstream,
                         parent_results=parent_results,
                         workspace_identity=recovery.workspace_identity(task['workspace_path'],{}),
                         # Free-form failure prose (PID, elapsed, log/claim
                         # paths) is evidence, not changed recovery inputs.
                         hold={'supplier':hold['supplier'],'workspace_identity':hold['workspace_identity']} if hold else None,
                         result=semantic_result,
                         helpers=recovery.helper_identity(root),
                         attachments=recovery.attachments(root,board,tid))
            candidates.append({'key':board+':'+tid+':'+kind, 'version':recovery.digest(state),
                               'task_id':tid,'kind':kind, 'priority':task['priority'],
                               'reason':hold['reason'] if hold else ('Latest native run failed' if failure else 'Body requests downstream result'),
                               'parents':[[p['id'],p['status']] for p in parents],
                               'downstream':downstream,'semantic_candidates':semantic})
        return sorted(candidates + observe_features(db, board, now),key=lambda c:(-c['priority'],c['key']))


def recovery_body(board, issue, audit=False):
    if issue.get('recovery_owner') and not audit:
        return '\n'.join([
            'Goal: Repair and resume the existing parked recovery owner once.',
            'Decision owner: head-coordinator',
            'Input supplier: agent.',
            'Scope: '+board+'/'+issue['recovery_owner']+' only; original issue '+issue['task_id']+' is context, not another execution assignment.',
            'Observation: '+json.dumps(issue,sort_keys=True),
            'Read the prior owner and its latest actual run. If active/queued, stop with no mutation.',
            'Correct only its demonstrated missing skills, finite measured runtime, bounded scope or input delivery through maintained native tools/helpers. Preserve all original gates and historical evidence.',
            'Use kanban_amend with exact version, supersession reason, measured runtime evidence when needed and readback. Preserve retry/provider limits and active source writers.',
            'If the breaker left an untyped blocked failed run, classify only that parked failure with changes.block_kind=capability and Input supplier: agent/model/provider evidence; never retype an existing gate.',
            'Only after a verifiable material repair, guarded-resume that SAME owner with exact recovery_version/reason for capability holds (blocked/scheduled/triage); preserve failure counters. Then immediately complete this controller with native readback/resumed run ID; perform no more effects.',
            'Do not execute the original repair here, create another repair writer, transfer ownership implicitly, remove protected review edges or manufacture a changed input.',
            'If no material repair is available, retain the old parked state and return one exact auditor question through native block/schedule. No unchanged retry or owner ask.',
        ])
    if issue['kind'] == 'feature-delivery-gap' and not audit:
        return '\n'.join([
            'Goal: Give one requested feature a productive next step or qualified disposition.',
            'Decision owner: head-coordinator',
            'Feature tracker: '+board+':'+issue['task_id'],
            'Feature handoff: delivery',
            'Observation: '+json.dumps(issue,sort_keys=True),
            'Tracker is an evidence anchor only: never dispatch, complete, unblock or parent-link it to execution.',
            'Read the original request, latest material update and named existing owners. Reconcile the existing handoff; never duplicate its audit or active/queued implementation.',
            'Separate implemented, independently reviewed, integrated and live stages. Routing/cards-created/design acceptance alone is not product delivery.',
            'If no executable next action exists, commission one bounded result: project-auditor selects a first requested slice or missing mechanism; only that auditor commissions feature audits. Reuse qualified prior evidence instead of repeating unchanged audits.',
            'Use current tiered autonomy for reviewed reversible technical/architecture/frontend decisions. Unrelated desktop adoption, tracker automation, deployment or another project must not gate isolated planning/implementation.',
            'Preserve actual secret/destructive/exposure/spending/material outcome, independent acceptance and deploy gates. Planning-only requests (e.g. groundwater) do not authorize implementation; reduce missing requirements to the smallest real owner question without sending a message here.',
            'An agent technical deferral needs one finite input-producing experiment/proposal or an independent bounded auditor assessment with a precise material wake condition; generic unknowns are not a permanent owner gate.',
            'Bind every new productive task and handoff with the exact Feature tracker: '+board+':'+issue['task_id']+' line; annotate existing members with that line in a native comment. Do not link the tracker as a prerequisite.',
            'Update the single tracker with dated actual evidence and exact next-task IDs. Keep the existing delivery handoff open through accepted work and merge-back disposition; new verifiers/input producers precede their waiting consumer.',
            'Inputs precede this delivery handoff: parent new producers/reviewers on the completed plan/decision, then link their results before this recovery. Never parent an input behind this unfinished recovery; only documentary auditor closure (Feature role: documentary-closure) follows delivery.',
            'Before recording a disposition, inspect CURRENT evidence_version with python3 ~/.hermes/scripts/feature_flow.py --inspect '+board+':'+issue['task_id']+' after actual member results and tracker updates. Do not copy a stale observation version.',
            'For delivered requested scope or qualified deferral, native complete this reconciliation with metadata.feature_delivery={tracker:"'+issue['task_id']+'",evidence_version:"fresh_inspected_version",state:"delivered_scope"|"assessed_defer",evidence_task_id:"t_...",wake_condition:"exact missing input for deferral"}. Cite the actual independent completed acceptance/assessment. Never claim a plan as implemented/live.',
            'A concrete productive task suppresses duplicate intake while it progresses; completion of this routing card alone does not. If its original recovery owner is parked, repair/resume that same owner through maintained native tools.',
            'No source implementation, runtime/credential operations, installs, messages, publication or deployment in this reconciliation. Auditor assessment remains independent; no self-acceptance.',
        ])
    return '\n'.join(([
        'Feature tracker: '+board+':'+issue['task_id'],
        'This is a repeatedly unresolved feature delivery gap. Assess one finite next-result mechanism or qualified deferral; never repeat an unchanged feature audit or implement the feature.',
        'Inspect current scope with python3 ~/.hermes/scripts/feature_flow.py --inspect '+board+':'+issue['task_id']+'. For a finite deferral, complete with metadata.feature_assessment={tracker:"'+issue['task_id']+'",scope_sha256:"fresh inspector scope hash",outcome:"defer",missing_inputs:["exact missing fact/mechanism"],supplier:"actual supplier",wake_condition:"precise material input that reopens it"}. Report actual source/checks separately; this assessment is not implementation or acceptance.',
    ] if issue['kind']=='feature-delivery-gap' else []) + [
        'Goal: '+('Independently resolve a repeatedly stuck recovery cluster.' if audit else 'Repair one technical recovery cluster and verify actual progress.'),
        'Input supplier: agent. This is an internal technical assignment, not an owner gate.',
        'Scope: '+board+'/'+issue['task_id']+' and only its directly necessary prerequisites/consumers.',
        'Observation (re-read native state before acting): '+json.dumps(issue,sort_keys=True),
        'Use kanban_show and native read-only evidence; do not scan unrelated findings or boards.',
        'Determine the actual missing supplier, rejection gate, skill/tool/runtime gap or semantic wait.',
        'Coordinator may kanban_amend parked technical body/priority/skills/runtime: inspect version, apply exact changes with supersession evidence, read back. Never edit an active card.',
        'A real failed run parked blocked without block_kind may be classified once with kanban_amend changes.block_kind=capability and Input supplier: agent/model/provider reason; preserve counters and existing typed gates.',
        'For a measured timeout use one finite revised cap with actual run evidence; preserve retries, provider holds and exact operation timeouts.',
        'Repair sources/workspaces/inputs through maintained helpers. Reconcile obsolete generic refusals against current exact approvals.',
        'Keep original acceptance/rollout consumers gated. Separate corrective producers from consumers that require their acceptance; never remove a rejected review to release original work.',
        'If the result is needed from a downstream card, supply existing qualified receipts directly or split the corrective producer; do not wait for that consumer to close first.',
        'Run native guarded resume only after prerequisite readback; use exact recovery_version/reason for capability blocked/scheduled/triage to preserve spent failure counters. No forged worker origin, CLI mutation bypass, retry reset or self-acceptance.',
        'Architecture/provenance or an unavailable safe mechanical repair goes to one bounded project-auditor question, with independent implementation/review if needed. Keep original handoff open through results.',
        'Stop after one coherent repair plan; no unchanged investigation or repeated owner ask. Secret/destructive/exposure/spending/reserved allocation and deploy gates remain binding.',
        ('Auditor: return a bounded immutable corrective plan, concrete evidence and stopping condition; never implement or deploy. Coordinator performs the resulting technical routing.' if audit else
         'Required terminal response: native complete with actual changed fields/edges, readback and resumed run ID; or native schedule/block naming the exact agent/external prerequisite. Acknowledgment, a prose runtime claim or another waiting card is not repair.'),
    ])


def previous_owner_active(root,board,tid,now,material_changed=False):
    if not tid:
        return False
    path=root/'kanban/boards'/board/'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=2)) as db:
        db.row_factory=sqlite3.Row;db.execute('PRAGMA query_only=ON')
        task=db.execute('SELECT status,created_at,worker_pid,claim_lock FROM tasks WHERE id=?',(tid,)).fetchone()
        if not task or task['status'] in {'done','archived'}:
            return False
        if task['status'] == 'running' or task['worker_pid'] is not None or task['claim_lock'] is not None:
            return True
        if task['status'] in {'ready','todo','review'}:
            return True  # Queued ownership never expires into a duplicate writer.
        run=db.execute('SELECT status,outcome,ended_at FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(tid,)).fetchone()
        if task['status'] in {'blocked','triage'} and run and {run['status'],run['outcome']} & {'failed','crashed','timed_out','spawn_failed','gave_up'}:
            return False
        # Only actual running work keeps an old parked route alive forever.
        # A waiting card/acknowledgment is not productive recovery. Traverse a
        # bounded connected remedy cluster to preserve active source writers.
        seen={tid};front=[tid]
        for _ in range(32):
            if not front:
                break
            node=front.pop()
            related=db.execute('SELECT t.id,t.status,t.worker_pid,t.claim_lock FROM task_links l JOIN tasks t ON t.id=CASE WHEN l.parent_id=? THEN l.child_id ELSE l.parent_id END WHERE l.parent_id=? OR l.child_id=? LIMIT 129',(node,node,node)).fetchall()
            if len(related)>128:
                raise ValueError('Recovery remedy graph exceeds bound')
            for other in related:
                if other['id'] in seen or other['status'] in {'done','archived'}:
                    continue
                if other['status']=='running' or other['worker_pid'] is not None or other['claim_lock'] is not None:
                    return True
                seen.add(other['id']);front.append(other['id'])
        if front:
            raise ValueError('Recovery remedy traversal exceeds bound')
        if material_changed:
            return False
        quiet_since=(run['ended_at'] if run and run['ended_at'] else task['created_at'])
        return now-int(quiet_since or now)<900


def parked_owner(root,board,tid):
    if not tid:
        return None
    path=root/'kanban/boards'/board/'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=2)) as db:
        db.execute('PRAGMA query_only=ON')
        task=db.execute('SELECT status FROM tasks WHERE id=?',(tid,)).fetchone()
        return tid if task and task[0] in {'blocked','triage','scheduled'} else None


def tick(root, *, dry_run=False, now=None, create=None):
    now = int(time.time()) if now is None else now
    root = Path(root).resolve()
    journal,lock = intake_journal(root,dry_run)
    try:
        path = journal/'state.json'
        if path.is_symlink():
            raise ValueError('Recovery state must not be a symlink')
        state = json.loads(path.read_text()) if path.exists() else {}
        if not isinstance(state,dict):
            raise ValueError('Invalid recovery state')
        actions = []
        for info in sorted((root/'kanban/boards').glob('*/board.json')):
            board = info.parent.name
            if board.startswith(('_','.')):
                continue
            # Alternate classes after eligibility filtering, not before it:
            # an exhausted/owned technical issue cannot consume a feature turn.
            selected=[]
            for issue in observe(root,board,now):
                entry = state.get(issue['key'],{})
                owner_id=entry.get('owner_task_id',entry.get('task_id'))
                if previous_owner_active(root,board,owner_id,now,
                                         material_changed=issue['version'] not in entry.get('versions',{})):
                    continue
                if entry.get('task_id') != owner_id and previous_owner_active(
                        root,board,entry.get('task_id'),now,
                        material_changed=issue['version'] not in entry.get('versions',{})):
                    continue
                owner=parked_owner(root,board,owner_id)
                if owner:
                    issue=dict(issue,recovery_owner=owner)
                versions=entry.get('versions',{})
                prior=versions.get(issue['version'],{'attempts':0,'last_at':0})
                count = prior['attempts']
                if count > MAX_ATTEMPTS or (count and now-prior['last_at'] < BACKOFF[min(count-1,2)]):
                    continue
                audit = count == MAX_ATTEMPTS
                selected.append((issue, owner_id, owner, versions, prior, count, audit))
            last_class=state.get('_fairness',{}).get(board)
            selected.sort(key=lambda item: (
                (('feature' if item[0]['kind']=='feature-delivery-gap' else 'technical') == last_class),
                -item[0]['priority'],item[0]['key']))
            for issue,owner_id,owner,versions,prior,count,audit in selected[:1]:
                action = dict(board=board,issue=issue,audit=audit,attempt=count+1)
                actions.append(action)
                if dry_run:
                    break
                if create is None:
                    spec = importlib.util.spec_from_file_location('recovery_taskforce',Path(__file__).with_name('review-taskforce.py'))
                    scheduler = importlib.util.module_from_spec(spec);spec.loader.exec_module(scheduler)
                    create = scheduler.hermes
                work = Path(json.loads(info.read_text()).get('default_workdir',''))
                if not work.is_absolute() or not work.is_dir():
                    raise ValueError('Recovery requires the registered existing board workspace')
                # A directory workspace avoids composing into an active branch.
                # This worker inspects/routes; implementation gets its own checkout.
                card = create(board,'create','[RECOVERY] '+issue['kind']+' '+issue['task_id'],
                              '--assignee','project-auditor' if audit else 'head-coordinator',
                              '--created-by',CREATOR,'--tenant','technical-recovery',
                              '--priority','100' if issue['kind']=='feature-delivery-gap' else '75','--workspace','dir:'+str(work),
                              '--max-runtime','900','--max-retries','1',
                              '--idempotency-key','deadlock:'+issue['key']+':'+issue['version']+':'+str(count+1),
                              '--body',recovery_body(board,issue,audit))
                prior.update(attempts=count+1,last_at=now,task_id=card['id'])
                versions[issue['version']]=prior
                state[issue['key']]={'task_id':card['id'],
                                     'owner_task_id':owner_id if owner or audit else card['id'],
                                     'versions':versions}
                state.setdefault('_fairness',{})[board]='feature' if issue['kind']=='feature-delivery-gap' else 'technical'
                atomic_write(path,json.dumps(state,sort_keys=True)+'\n',mode=0o600)
                break  # At most one new bounded worker per board per tick.
        return actions
    finally:
        if lock is not None:
            os.close(lock)


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--dry-run',action='store_true')
    args=parser.parse_args()
    result=tick(Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))),dry_run=args.dry_run)
    if result:
        print(json.dumps(result,sort_keys=True))
