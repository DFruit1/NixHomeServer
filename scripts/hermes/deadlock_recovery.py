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
import re
import sqlite3
import stat
import time

import capability_recovery as recovery
from feature_flow import observe_features
from hermes_common import atomic_write

CREATOR = 'deadlock-recovery-monitor'
MAX_ATTEMPTS = 3
BACKOFF = (300, 900, 3600)


def requests_downstream_input(body, child):
    """Recognize an explicit input wait, not a mention of its consumer.

    This is a commissioning hint only. A native coordinator still qualifies
    the dependency; the collector never changes it.
    """
    for clause in re.split(r'[\n.;!?]', body or ''):
        # Match one affirmative request and its named input in the same clause.
        # Do not let an upstream wait spill across a downstream consumer mention.
        if re.search(r'\b(?:not|never|no longer|without)\b', clause, re.I):
            continue
        request = re.search(
            r'\b(?:wait(?:ing)?\s+for|await(?:ing)?|blocked\s+on|requires?)\s+'
            r'(?:(?:the|exact|qualified|current|fresh|input|result|output|evidence|from|of)\s+)*'
            + re.escape(child) + r'\b', clause, re.I)
        if request:
            return True
    return False


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
            run = db.execute('SELECT id,status,outcome,metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(tid,)).fetchone()
            parents = [dict(r) for r in db.execute('SELECT p.id,p.status,p.assignee,p.body FROM task_links l JOIN tasks p ON p.id=l.parent_id WHERE l.child_id=? ORDER BY p.id',(tid,))]
            hold = holds.get(tid)
            failure = bool(run and {run['status'],run['outcome']} & {'failed','crashed','timed_out','spawn_failed','gave_up'})
            # A waiting consumer can describe an input it requires from a
            # downstream producer. Ask a native coordinator to qualify this;
            # the collector never decides whether to remove a dependency.
            downstream = [r[0] for r in db.execute('SELECT child_id FROM task_links WHERE parent_id=? ORDER BY child_id',(tid,))]
            semantic = [child for child in downstream if requests_downstream_input(task['body'], child)]
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
            success = db.execute("SELECT id FROM task_runs WHERE task_id=? AND ended_at IS NOT NULL "
                                 "AND outcome IN ('completed','review_requested','changes_requested') ORDER BY id DESC LIMIT 1",
                                 (tid,)).fetchone()
            state.update(parents=parents, downstream=downstream,
                         execution_epoch=success['id'] if success else None,
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


def registered_workspace(info):
    """Unconfigured boards are visible but cannot commission recovery writers."""
    try:
        metadata = json.loads(info.read_text())
        value = metadata.get('default_workdir') if isinstance(metadata, dict) else None
        if not isinstance(value, str) or not value or '\x00' in value:
            return None
        work = Path(value)
        return work if work.is_absolute() and work.is_dir() else None
    except (OSError, ValueError):
        return None


def incident_key(state, board, issue):
    """A detector's classification is evidence, not a second task owner."""
    if issue['kind'] == 'feature-delivery-gap':
        return issue['key']
    prefix = board + ':' + issue['task_id'] + ':'
    matches = [key for key in state if key.startswith(prefix) and not key.endswith(':feature-delivery-gap')]
    return sorted(matches)[0] if matches else issue['key']


def execution_progress(root, board, original, baseline):
    path = root/'kanban/boards'/board/'kanban.db'
    if not path.is_file():
        return {'state': 'unknown', 'run_id': baseline}
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=2)) as db:
        db.row_factory=sqlite3.Row;db.execute('PRAGMA query_only=ON')
        run=db.execute('SELECT id,status,outcome,ended_at FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                       (original,)).fetchone()
        proof=db.execute("SELECT id FROM task_runs WHERE task_id=? AND id>? AND ended_at IS NOT NULL "
                         "AND outcome IN ('completed','review_requested','changes_requested') ORDER BY id DESC LIMIT 1",
                         (original,baseline)).fetchone()
        progressed=bool(proof)
        return {'state': 'recovered' if progressed else 'awaiting_execution',
                'run_id': run['id'] if run else 0,
                'successful_run_id':proof['id'] if proof else None}


def attach_observations(root, board, detector, lines):
    """Attach known detector signals to existing incidents without another card.

    The existing intake lock and journal own this record. Unknown board-wide
    findings retain the supervisor's existing routing and native budgets.
    """
    path=root/'runtime/deadlock-intake/state.json'
    if not path.exists():
        return lines
    journal,lock=intake_journal(root,False)
    try:
        state=json.loads(path.read_text());remaining=[];changed=False
        for line in lines:
            if not re.match(r'^(WORKER_FAILED_BLOCKED|TRIAGE_EXHAUSTED|DEAD_WORKER)\b',line):
                remaining.append(line);continue
            matches=[entry for key,entry in state.items() if not key.startswith('_')
                     and key.startswith(board+':') and isinstance(entry,dict)
                     and entry.get('execution',{}).get('state')=='awaiting_execution'
                     and key.split(':')[1] in re.findall(r'\bt_[A-Za-z0-9_]+\b',line)]
            if not matches:
                remaining.append(line);continue
            for entry in matches:
                sources=entry.setdefault('detectors',[])
                if detector not in sources:
                    sources.append(detector);changed=True
                evidence=entry.setdefault('detector_evidence',{})
                if evidence.get(detector)!=line[:1200]:
                    evidence[detector]=line[:1200];changed=True
        if changed:
            atomic_write(path,json.dumps(state,sort_keys=True)+'\n',mode=0o600)
        return remaining
    finally:
        os.close(lock)


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
        if len(state)>5000:
            raise ValueError('Recovery incident inventory exceeds bound')
        # Finishing a controller or merely releasing a hold is insufficient.
        # Observe a later successful original execution before closing incident.
        for key,entry in state.items():
            if key.startswith('_') or not isinstance(entry,dict) or 'origin_run_id' not in entry:
                continue
            board,original=key.split(':')[:2]
            entry['execution']=execution_progress(root,board,original,entry['origin_run_id'])
        actions = []
        for info in sorted((root/'kanban/boards').glob('*/board.json')):
            board = info.parent.name
            if board.startswith(('_','.')):
                continue
            work = registered_workspace(info)
            if work is None:
                actions.append(dict(board=board, status='ineligible',
                                    reason='Recovery requires a registered existing absolute board workspace'))
                continue
            # Alternate classes after eligibility filtering, not before it:
            # an exhausted/owned technical issue cannot consume a feature turn.
            selected=[]
            for issue in observe(root,board,now):
                key=incident_key(state,board,issue)
                issue=dict(issue,key=key)
                entry = state.get(key,{})
                # Old releases may have separate classifications for one task.
                # Preserve every record and protect every existing owner while
                # commissioning only through the stable canonical entry.
                prefix=board+':'+issue['task_id']+':'
                aliases=[state[k] for k in state if k.startswith(prefix) and k!=key
                         and not k.endswith(':feature-delivery-gap')]
                alias_owners={tid for v in aliases for tid in (v.get('owner_task_id'),v.get('task_id')) if tid}
                if any(previous_owner_active(root,board,tid,now) for tid in alias_owners if tid):
                    continue
                if aliases:
                    entry={**entry,'legacy_owner_tasks':sorted(t for t in alias_owners if t)}
                    versions={v:{**data} for v,data in entry.get('versions',{}).items()}
                    for alias in aliases:
                        for version,record in alias.get('versions',{}).items():
                            old=versions.get(version)
                            if old is None:
                                versions[version]={**record}
                            elif old.get('task_id') != record.get('task_id'):
                                versions[version]={**old,'attempts':max(old['attempts'],record['attempts'])}
                    entry['versions']=versions
                    state[key]=entry
                if entry.get('execution',{}).get('state')=='recovered':
                    # A real later recurrence starts a new episode; retain the
                    # old one and its attempts as history, never reset budgets.
                    history=entry.get('prior_episodes',[])
                    if len(history)>=64:
                        raise ValueError('Recovery episode history exceeds bound; retain and reconcile it')
                    entry={**entry,'prior_episodes':history+[{
                        'origin_run_id':entry['origin_run_id'],'execution':entry['execution'],
                        'owner_task_id':entry.get('owner_task_id')}],
                        'origin_run_id':entry['execution']['run_id'],
                        'execution':{'state':'awaiting_execution','run_id':entry['execution']['run_id']}}
                    entry.pop('episode_audit_task_id',None)
                    state[key]=entry
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
                # A completed controller without original execution is still
                # an open incident. Unchanged evidence gets one diagnosis,
                # rather than another equivalent repair controller.
                if entry.get('execution',{}).get('state')=='awaiting_execution' and owner_id:
                    path_db=root/'kanban/boards'/board/'kanban.db'
                    if path_db.exists():
                        with closing(sqlite3.connect(path_db.as_uri()+'?mode=ro',uri=True,timeout=2)) as db:
                            db.execute('PRAGMA query_only=ON')
                            row=db.execute('SELECT status FROM tasks WHERE id=?',(owner_id,)).fetchone()
                        if row and row[0] in {'done','archived'} and issue['version'] in versions:
                            if entry.get('episode_audit_task_id'):
                                continue
                            audit=True
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
                progress=execution_progress(root,board,issue['task_id'],0)
                previous=state.get(issue['key'],{})
                state[issue['key']]={**previous,'task_id':card['id'],
                                     'owner_task_id':owner_id if owner or audit else card['id'],
                                     'versions':versions,
                                     'origin_run_id':previous.get('origin_run_id',progress['run_id']),
                                     'execution':{'state':'awaiting_execution','run_id':progress['run_id']},
                                     'detectors':sorted(set(previous.get('detectors',[]))|{'technical-recovery'})}
                if audit:
                    state[issue['key']]['episode_audit_task_id']=card['id']
                state.setdefault('_fairness',{})[board]='feature' if issue['kind']=='feature-delivery-gap' else 'technical'
                atomic_write(path,json.dumps(state,sort_keys=True)+'\n',mode=0o600)
                break  # At most one new bounded worker per board per tick.
        if not dry_run and state:
            atomic_write(path,json.dumps(state,sort_keys=True)+'\n',mode=0o600)
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
