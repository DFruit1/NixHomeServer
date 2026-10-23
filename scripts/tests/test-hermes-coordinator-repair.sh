#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ -n "${HERMES_KANBAN_TASK:-}${HERMES_KANBAN_RUN_ID:-}${HERMES_DELEGATED_CHILD_CONTEXT:-}" && "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  echo 'Use the authorised fixture-runner for native synthetic tests' >&2
  exit 2
fi
python3 -B - "$repo" <<'PY'
import importlib.util
import json
import os
import subprocess
from pathlib import Path
import sys
import tempfile
import time
import types
import unittest
from unittest.mock import patch

source=Path(sys.argv[1])/'scripts/hermes'
native=(Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2] if os.environ.get('HERMES_FIXTURE_NATIVE_PYTHON') else Path.home()/'.hermes/hermes-agent')
sys.path[:0]=[str(source),str(native)]
from hermes_cli import kanban_db as kb,kanban_db_connect as kbc
from agent.delegation_context import delegated_child_context
import worker_origin, resume_recovered, coordinator_repair as repair, deadlock_recovery as monitor
sys.modules['hermes_cli.nixhomeserver_worker_origin']=worker_origin
sys.modules['hermes_cli.nixhomeserver_resume_recovered']=resume_recovered
sys.modules['hermes_cli.nixhomeserver_coordinator_repair']=repair
sys.modules['cron.nixhomeserver_capability_recovery']=monitor.recovery
from coordinator_repair_adapter import adapt,EDITS

class RepairTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='coordinator-repair-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.path=self.root/'kanban/boards/testboard/kanban.db';self.path.parent.mkdir(parents=True)
        self.work=self.root/'work';self.work.mkdir()
        self.path.with_name('board.json').write_text(json.dumps({'default_workdir':str(self.work)}))
        self.conn=kbc.connect(db_path=self.path);self.addCleanup(self.conn.close)
        self.actor=kb.create_task(self.conn,title='Coordinator',assignee='head-coordinator',workspace_kind='scratch')
        self.target=kb.create_task(self.conn,title='Missing skill',assignee='feature-reviewer',skills=['kanban-orchestration'],max_runtime_seconds=900,max_retries=1,triage=True,workspace_kind='scratch')
        now=int(time.time());self.now=now
        with kb.write_txn(self.conn):
            self.conn.execute("UPDATE tasks SET status='running',worker_pid=?,worker_started_at=?,claim_lock='proof',claim_expires=?,workspace_path=?,current_run_id=42 WHERE id=?",(os.getpid(),worker_origin.process_fingerprint(),now+600,str(self.work),self.actor))
            self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,worker_pid,worker_started_at,claim_lock,claim_expires,started_at) VALUES(42,?,'running','head-coordinator',?,?,'proof',?,?)",(self.actor,os.getpid(),worker_origin.process_fingerprint(),now+600,now))
        self.env=patch.dict(os.environ,{'HERMES_ROOT':str(self.root),'HERMES_KANBAN_TASK':self.actor,'HERMES_KANBAN_RUN_ID':'42','HERMES_KANBAN_BOARD':'testboard','HERMES_KANBAN_DB':str(self.path),'HERMES_KANBAN_WORKSPACE':str(self.work),'HERMES_PROFILE':'head-coordinator','HERMES_KANBAN_CLAIM_LOCK':'proof'})
        self.env.start();self.addCleanup(self.env.stop)

    def apply(self,changes=None,**kwargs):
        version=repair.amend(kb,self.conn,self.target)['version']
        return repair.amend(kb,self.conn,self.target,expected_version=version,changes=changes or {'skills':[]},reason='Supersede invalid coordinator-only preload; same review scope',**kwargs)

    def hold(self):
        self.conn.execute("UPDATE tasks SET status='ready' WHERE id=?",(self.target,));self.conn.commit()
        self.assertTrue(kb.block_task(self.conn,self.target,reason='Input supplier: agent. Missing skill',kind='capability'))

    def test_actual_native_identity_and_exact_field_readback(self):
        before=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        result=self.apply();self.assertTrue(result['applied'])
        after=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        before['skills']='[]';self.assertEqual(before,after)
        event=json.loads(self.conn.execute("SELECT payload FROM task_events WHERE task_id=? AND kind='coordinator_amended'",(self.target,)).fetchone()[0])
        self.assertEqual(42,event['actor_run']);self.assertEqual(self.actor,event['actor_task'])

    def test_stale_cas_refuses_all_changes(self):
        version=repair.amend(kb,self.conn,self.target)['version']
        kb.edit_task(self.conn,self.target,body='Concurrent approved amendment')
        with self.assertRaisesRegex(ValueError,'changed'):
            repair.amend(kb,self.conn,self.target,expected_version=version,changes={'skills':[]},reason='old scope')
        self.assertEqual('["kanban-orchestration"]',self.conn.execute('SELECT skills FROM tasks WHERE id=?',(self.target,)).fetchone()[0])

    def test_forged_delegated_wrong_board_and_active_target_refused(self):
        with delegated_child_context(),self.assertRaises(ValueError):self.apply()
        with patch.dict(os.environ,{'HERMES_KANBAN_RUN_ID':'43'}),self.assertRaises(ValueError):self.apply()
        other=kbc.connect(db_path=self.root/'other.db')
        try:
            with self.assertRaises(ValueError):repair.amend(kb,other,self.target)
        finally:other.close()
        for update in ("status='running'","worker_pid=999","claim_lock='lease'","claim_expires=1"):
            self.conn.execute('UPDATE tasks SET '+update+' WHERE id=?',(self.target,));self.conn.commit()
            with self.assertRaises(ValueError):self.apply()
            self.conn.execute("UPDATE tasks SET status='triage',worker_pid=NULL,claim_lock=NULL,claim_expires=NULL WHERE id=?",(self.target,));self.conn.commit()

    def test_forbidden_fields_and_evidence_fence_refused(self):
        for changes in ({'max_retries':4},{'result':'accept'},{'assignee':'head-coordinator'},{'body':'Recovery mode: evidence-only'},{'block_kind':'needs_input'}):
            with self.subTest(changes=changes),self.assertRaises(ValueError):self.apply(changes)

    def test_classify_real_untyped_failure_preserves_counter_and_cannot_retype_gate(self):
        self.conn.execute("UPDATE tasks SET status='blocked',consecutive_failures=1,last_failure_error='protocol violation' WHERE id=?",(self.target,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'crashed','feature-reviewer',?,?,'crashed')",(self.target,self.now-20,self.now));self.conn.commit()
        version=repair.amend(kb,self.conn,self.target)['version']
        result=repair.amend(kb,self.conn,self.target,expected_version=version,changes={'block_kind':'capability'},reason='Input supplier: agent. Native missing terminal response; corrected skill/tool input is available.')
        self.assertTrue(result['applied'])
        row=self.conn.execute('SELECT status,block_kind,consecutive_failures,last_failure_error FROM tasks WHERE id=?',(self.target,)).fetchone()
        self.assertEqual(('blocked','capability',1,'protocol violation'),tuple(row))
        for kind in ('capability','needs_input'):
            self.conn.execute('UPDATE tasks SET block_kind=? WHERE id=?',(kind,self.target));self.conn.commit()
            with self.assertRaises(ValueError):self.apply({'block_kind':'capability'})

    def dump(self):
        return [[dict(row) for row in self.conn.execute(sql)] for sql in (
            'SELECT * FROM tasks ORDER BY id','SELECT * FROM task_runs ORDER BY id',
            'SELECT * FROM task_events ORDER BY id','SELECT * FROM task_links ORDER BY parent_id,child_id')]

    def probe(self, calls):
        """Record every subprocess argv while keeping the real call semantics."""
        real=subprocess.run
        def record(*args,**kwargs):
            calls.append(args[0] if args else kwargs.get('args'))
            return real(*args,**kwargs)
        return record

    def episode(self,run_id,source_status='review'):
        """One real native untyped kanban_block handoff owned by its own run."""
        self.conn.execute("UPDATE tasks SET status='running',skills='[]',max_retries=NULL,"
                          "consecutive_failures=0,block_kind=NULL,block_recurrences=0,claim_lock='proof',"
                          "claim_expires=?,current_run_id=? WHERE id=?",(self.now+600,run_id,self.target))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,claim_lock,claim_expires)"
                          " VALUES(?,?,'running','feature-reviewer',?,'proof',?)",
                          (run_id,self.target,self.now-30,self.now+600))
        kb._append_event(self.conn,self.target,'claimed',{'source_status':source_status},run_id=run_id)
        self.conn.commit()
        self.assertTrue(kb.block_task(self.conn,self.target,
                                      reason='Reviewer stopped at the missing plan; Input supplier: agent.'))
        event=self.conn.execute("SELECT id FROM task_events WHERE task_id=? AND kind='blocked'"
                                " ORDER BY id DESC LIMIT 1",(self.target,)).fetchone()[0]
        return {'run_id':run_id,'event_id':event}

    def containment(self,episode,**kwargs):
        return self.amend_episode(episode,'Input supplier: agent. Repair evidence: the missing plan section '
                                  'was restored and read back; containment only, unchanged review scope.',**kwargs)

    def amend_episode(self,episode,reason,changes=None):
        version=repair.amend(kb,self.conn,self.target)['version']
        return repair.amend(kb,self.conn,self.target,expected_version=version,
                            changes=changes or {'block_kind':'capability'},reason=reason,
                            terminal_episode=episode)

    def current_hold(self):
        return monitor.recovery.read_board(self.conn,self.root,'testboard',
                                           monitor.recovery.helper_identity(self.root))[0]

    def holds(self):
        return monitor.recovery.read_board(self.conn,self.root,'testboard',
                                           monitor.recovery.helper_identity(self.root))

    def reclaimed_episode(self):
        """A genuine native capability hold, release, claim, stale reclaim, trip.

        The prior release is what hides this reclaim from the monitor. The
        claim, reclaim and gave_up rows come from the native lifecycle
        functions, so the fixture keeps the real shapes: the claimed and
        reclaimed events are run-scoped while the breaker's gave_up is
        task-scoped (run_id NULL).
        """
        self.conn.execute("UPDATE tasks SET status='ready',skills='[]',block_kind='capability',"
                          "max_retries=1,consecutive_failures=0 WHERE id=?",(self.target,));self.conn.commit()
        self.assertTrue(kb.block_task(self.conn,self.target,kind='capability',
                                      reason='Input supplier: agent. Older capability episode'))
        self.assertTrue(kb.unblock_task(self.conn,self.target))
        self.assertIsNotNone(kb.claim_task(self.conn,self.target,claimer='stale'))
        run=self.conn.execute('SELECT id FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                              (self.target,)).fetchone()[0]
        with kb.write_txn(self.conn):
            kb._record_reclaim(self.conn,self.target,{},error='stale_lock=stale',
                               payload={'retry_status':'review'})
            self.conn.execute("UPDATE tasks SET status='review',claim_lock=NULL,claim_expires=NULL"
                              " WHERE id=?",(self.target,))
        self.assertTrue(kb._record_task_failure(
            self.conn,self.target,'stale_lock=stale',outcome='reclaimed',failure_limit=3,
            release_claim=False,end_run=False,event_payload_extra={'retry_status':'review'}))
        event=self.conn.execute("SELECT id FROM task_events WHERE task_id=? AND kind='gave_up'"
                                " ORDER BY id DESC LIMIT 1",(self.target,)).fetchone()[0]
        return {'run_id':run,'event_id':event}

    def reviewer_history(self):
        """The historical consumption a Branch A containment must not rewrite.

        Native reviewer shape: one completed measurement run retained
        request-changes with its failed exit-1 check, then exactly one
        receipt-only completion attempt was refused for missing explicit
        board/task scope and stopped. The card itself is parked with failure 0
        and NULL retries, so those two consumptions exist only in the run and
        event record; a classification or release that replenished either one
        would silently authorise a second attempt.
        """
        parent=kb.create_task(self.conn,title='Completed prerequisite',assignee='standard-implementer')
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(parent,))
        self.conn.execute('INSERT INTO task_links(parent_id,child_id) VALUES(?,?)',(parent,self.target))
        revision='a'*64
        check='PATH=/usr/bin:$PATH python3 scripts/hermes/fixture-runner.py --repo . '\
              '--suite scripts/tests/test-coordinator-repair-product-check.sh --timeout 300'
        measurement={'verdict':'request-changes','revision':revision,'implementer':'standard-implementer',
                     'requested_changes':['Restore the missing plan section'],
                     'checks':[{'command':check,'exit_code':1}]}
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata)"
                          " VALUES(40,?,'done','feature-reviewer',?,?,'completed',?)",
                          (self.target,self.now-3000,self.now-2800,json.dumps(measurement)))
        kb._append_event(self.conn,self.target,'changes_requested',
                         {'retry_status':'review','revision':revision,'checks':measurement['checks']},run_id=40)
        refusal='Explicit board and task scope required; no further attempt recorded.'
        receipt={'attempt':'receipt-only','consumed':True,'refusal':refusal}
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata)"
                          " VALUES(41,?,'done','feature-reviewer',?,?,'completed',?)",
                          (self.target,self.now-2400,self.now-2300,json.dumps(receipt)))
        kb._append_event(self.conn,self.target,'failed',
                         {'error':refusal,'attempt':'receipt-only','consumed':True},run_id=41)
        self.conn.commit()
        return {'parent':parent,'measurement':40,'receipt':41,'revision':revision,
                'check':check,'refusal':refusal,
                'last_event':self.conn.execute('SELECT MAX(id) FROM task_events').fetchone()[0]}

    def test_terminal_episode_untyped_containment_preserves_review_phase_and_resumes_once(self):
        history=self.reviewer_history()
        episode=self.episode(43)
        before=self.dump()
        self.assertEqual([],self.holds())             # the untyped episode is not a hold yet
        version=repair.amend(kb,self.conn,self.target)['version']
        probes=[]
        with patch('subprocess.run',side_effect=self.probe(probes)):
            result=repair.amend(kb,self.conn,self.target,expected_version=version,
                                changes={'block_kind':'capability'},reason=self.containment_reason(),
                                terminal_episode=episode)
        self.assertTrue(result['applied'])
        after=self.dump()
        was={r['id']:r for r in before[0]}[self.target];now={r['id']:r for r in after[0]}[self.target]
        self.assertEqual(dict(was,block_kind='capability'),now)
        self.assertEqual('blocked',now['status']);self.assertEqual(0,now['consecutive_failures'])
        self.assertIsNone(now['max_retries']);self.assertIsNone(now['last_failure_error'])
        self.assertEqual(before[1],after[1])          # no run created, none mutated
        self.assertEqual(before[2],after[2][:-1])     # every earlier episode preserved
        self.assertEqual(before[3],after[3])
        added=after[2][-1];payload=json.loads(added['payload'])
        self.assertEqual(('blocked','terminal-containment'),(added['kind'],payload['branch']))
        self.assertEqual((43,episode['event_id'],42),
                         (payload['source_run'],payload['source_event'],payload['actor_run']))
        self.assertEqual(('capability','agent','review'),
                         (payload['kind'],payload['supplier'],payload['resume_status']))
        # The reviewer-shaped history survives byte for byte: the completed
        # measurement still carries its request-changes/exit-1 verdict and the
        # one receipt-only attempt is still spent. Nothing re-runs the failed
        # product check, and no attempt is minted for a later continuation.
        runs={r['id']:r for r in after[1]}
        self.assertEqual([40,41,42,43],sorted(runs))
        measured=json.loads(runs[history['measurement']]['metadata'])
        self.assertEqual(('request-changes',history['revision']),
                         (measured['verdict'],measured['revision']))
        self.assertEqual([{'command':history['check'],'exit_code':1}],measured['checks'])
        spent=json.loads(runs[history['receipt']]['metadata'])
        self.assertEqual(('receipt-only',True),(spent['attempt'],spent['consumed']))
        refusals=[e for e in after[2] if e['kind']=='failed' and e['run_id']==history['receipt']]
        self.assertEqual(1,len(refusals))
        self.assertEqual(history['refusal'],json.loads(refusals[0]['payload'])['error'])
        self.assertEqual([],probes)                   # classification ran no check
        self.assertIn({'parent_id':history['parent'],'child_id':self.target},after[3])
        self.assertEqual('done',{p['id']:p for p in after[0]}[history['parent']]['status'])
        # A consumed or superseded episode never rides a second amendment.
        replayed=self.dump()
        with self.assertRaisesRegex(ValueError,'changed'):
            repair.amend(kb,self.conn,self.target,expected_version=version,
                         changes={'block_kind':'capability'},reason=self.containment_reason(),
                         terminal_episode=episode)
        self.assertEqual(replayed,self.dump())
        with self.assertRaisesRegex(ValueError,'supersedes'):
            self.containment(episode)
        self.assertEqual(replayed,self.dump())
        current=self.current_hold()
        self.assertEqual('agent',current['supplier'])
        self.assertEqual((self.target,'feature-reviewer'),(current['task_id'],current['assignee']))
        self.assertRegex(current['version'],r'^[0-9a-f]{64}$')
        self.assertNotIn(current['version'],{version,result['version']})  # fresh hold, not the snapshot
        self.assertEqual('review',resume_recovered.resume_recovered(
            kb,self.conn,self.target,current['version'],'Containment classified; resume the unchanged review')['status'])
        with self.assertRaises(ValueError):
            resume_recovered.resume_recovered(kb,self.conn,self.target,current['version'],'replay')
        # One guarded release: only the target's status moves, and both spent
        # attempts, the counters and the retry budget survive it unchanged.
        final=self.dump()
        self.assertEqual(before[1],final[1])
        self.assertEqual(before[2],final[2][:-2])
        self.assertEqual(['blocked','unblocked'],[e['kind'] for e in final[2][-2:]])
        self.assertEqual(before[3],final[3])
        self.assertEqual([dict(r,status='review') if r['id']==self.target else r for r in after[0]],final[0])
        released={r['id']:r for r in final[0]}[self.target]
        self.assertEqual(('review','capability','feature-reviewer',0,None,None),
                         (released['status'],released['block_kind'],released['assignee'],
                          released['consecutive_failures'],released['max_retries'],
                          released['last_failure_error']))
        appended=final[2][len(after[2]):]
        self.assertEqual(['unblocked'],[e['kind'] for e in appended])
        episode_events=[e for e in final[2] if e['id']>history['last_event']]
        self.assertEqual(['claimed','blocked','blocked','unblocked'],
                         [e['kind'] for e in episode_events])
        self.assertFalse([e for e in episode_events
                          if 'test-coordinator-repair-product-check' in (e['payload'] or '')])

    def test_terminal_episode_reaffirms_reclaimed_capability_without_mutation(self):
        episode=self.reclaimed_episode()
        # The reclaim trip is invisible to the monitor: the newest block-phase
        # event is still the PRIOR release, so no current hold or resume exists.
        self.assertEqual([],monitor.recovery.read_board(
            self.conn,self.root,'testboard',monitor.recovery.helper_identity(self.root)))
        with self.assertRaisesRegex(ValueError,'technical recovery hold'):
            resume_recovered.resume_recovered(kb,self.conn,self.target,'0'*64,'no current episode')
        before=self.dump()
        give={r['id']:r for r in before[2]}[episode['event_id']]
        self.assertEqual(('gave_up',None),(give['kind'],give['run_id']))  # native trip is task-scoped
        self.assertTrue(self.amend_episode(episode,
            'Input supplier: agent. Authorized continuation: the reclaim at the stale claim was audited; '
            'reaffirm this reclaimed episode only.').get('applied'))
        after=self.dump()
        self.assertEqual(before[0],after[0])          # every task column byte-identical
        self.assertEqual(before[1],after[1]);self.assertEqual(before[3],after[3])
        self.assertEqual(before[2],after[2][:-1])
        payload=json.loads(after[2][-1]['payload'])
        self.assertEqual(('blocked','reclaimed-reaffirmation','capability'),
                         (after[2][-1]['kind'],payload['branch'],payload['kind']))
        self.assertEqual((episode['run_id'],episode['event_id'],42),
                         (payload['source_run'],payload['source_event'],payload['actor_run']))
        self.assertEqual(('agent','review'),(payload['supplier'],payload['resume_status']))
        row={r['id']:r for r in after[0]}[self.target]
        self.assertEqual((1,1,'stale_lock=stale','capability'),
                         (row['consecutive_failures'],row['max_retries'],row['last_failure_error'],row['block_kind']))
        current=self.current_hold()
        self.assertEqual('agent',current['supplier'])
        resumed=resume_recovered.resume_recovered(kb,self.conn,self.target,current['version'],
                                                  'Reaffirmed reclaimed episode; resume the unchanged review')
        self.assertEqual('review',resumed['status'])
        released={r['id']:r for r in self.dump()[0]}[self.target]
        self.assertEqual(dict(row,status='review'),released)

    def test_terminal_episode_reaffirmation_requires_material_repair_evidence(self):
        episode=self.reclaimed_episode()
        version=repair.amend(kb,self.conn,self.target)['version']
        holds=self.holds();before=self.dump()
        self.assertEqual([],holds)
        for reason in ('Input supplier: agent.',
                       'Input supplier: agent. The reclaim at the stale claim was audited.',
                       'Input supplier: agent. Repair evidence:',
                       'Input supplier: agent. Authorized continuation: '):
            with self.subTest(reason=reason),self.assertRaisesRegex(ValueError,'material'):
                repair.amend(kb,self.conn,self.target,expected_version=version,
                             changes={'block_kind':'capability'},reason=reason,
                             terminal_episode=episode)
            # A refusal must not type, append or consume this episode's hold.
            self.assertEqual(before,self.dump())
            self.assertEqual(holds,self.holds())
        self.assertTrue(self.amend_episode(episode,
            'Input supplier: agent. Authorized continuation: the reclaim at the stale claim was audited; '
            'reaffirm this reclaimed episode only.').get('applied'))

    def test_terminal_episode_reaffirmation_requires_this_runs_claim_reclaim_chronology(self):
        episode=self.reclaimed_episode()
        reason=('Input supplier: agent. Authorized continuation: the reclaim at the stale claim was '
                'audited; reaffirm this reclaimed episode only.')
        before=self.dump();holds=self.holds()
        rows={r['id']:dict(r) for r in before[2]}
        claim=next(r for r in rows.values() if r['kind']=='claimed' and r['run_id']==episode['run_id'])
        reclaim=next(r for r in rows.values() if r['kind']=='reclaimed' and r['run_id']==episode['run_id'])
        release=next(r for r in reversed(list(rows.values())) if r['kind']=='unblocked')
        give=rows[episode['event_id']]
        def restore(row):
            keys=list(row)
            self.conn.execute('INSERT OR REPLACE INTO task_events('+','.join(keys)+') VALUES('
                              +','.join('?'*len(keys))+')',tuple(row[k] for k in keys))
            self.conn.commit()
        cases=(('missing claim',claim,'DELETE FROM task_events WHERE id=?',(claim['id'],),
                "claim and reclaim records"),
               ('missing reclaim',reclaim,'DELETE FROM task_events WHERE id=?',(reclaim['id'],),
                "claim and reclaim records"),
               ('claim of another run',claim,'UPDATE task_events SET run_id=? WHERE id=?',(41,claim['id']),
                "claim and reclaim records"),
               ('reclaim of another run',reclaim,'UPDATE task_events SET run_id=? WHERE id=?',(41,reclaim['id']),
                "claim and reclaim records"),
               ('claim before the prior release',claim,'UPDATE task_events SET created_at=? WHERE id=?',
                (release['created_at']-1,claim['id']),'timestamps after the prior release'),
               ('reclaim before the prior release',reclaim,'UPDATE task_events SET created_at=? WHERE id=?',
                (release['created_at']-1,reclaim['id']),'timestamps after the prior release'),
               ('reclaim before its own claim',claim,'UPDATE task_events SET created_at=? WHERE id=?',
                (reclaim['created_at']+1,claim['id']),'timestamps after the prior release'),
               ('trip before its own reclaim',give,'UPDATE task_events SET created_at=? WHERE id=?',
                (reclaim['created_at']-1,give['id']),'Reaffirmation|terminal event'))
        for name,row,sql,params,expected in cases:
            with self.subTest(case=name):
                self.conn.execute(sql,params);self.conn.commit()
                mutated=self.dump();self.assertNotEqual(before,mutated)  # the probe changed the evidence
                # Re-inspect after the mutation: a coordinator sees the changed
                # card, and the chronology rule must still refuse it on its own.
                current=repair.amend(kb,self.conn,self.target)['version']
                with self.assertRaisesRegex(ValueError,expected):
                    repair.amend(kb,self.conn,self.target,expected_version=current,
                                 changes={'block_kind':'capability'},reason=reason,
                                 terminal_episode=episode)
                self.assertEqual(mutated,self.dump())      # a refusal appends or mutates nothing
                self.assertEqual(holds,self.holds())
                restore(row)
                self.assertEqual(before,self.dump())
        with self.subTest(case='release between the claim and the reclaim'):
            # release1 -> claim -> release3 -> reclaim -> gave_up. The newest
            # release is release3, so this trip did not follow the card's live
            # release and must be refused even though release1 predates the
            # claim. Shift this card's later event ids to free one slot.
            shift=10000
            self.conn.execute('UPDATE task_events SET id=id+? WHERE task_id=? AND id>?',
                              (shift,self.target,claim['id']))
            self.conn.execute("INSERT INTO task_events(id,task_id,kind,payload,created_at) "
                              "VALUES(?,?,'unblocked',?,?)",
                              (claim['id']+1,self.target,'{"status":"ready"}',claim['created_at']))
            self.conn.commit()
            intervening=self.dump();self.assertNotEqual(before,intervening)
            try:
                # Re-inspect so this is the chronology rule, not the CAS, refusing.
                current=repair.amend(kb,self.conn,self.target)['version']
                with self.assertRaisesRegex(ValueError,'claim after the latest prior release'):
                    repair.amend(kb,self.conn,self.target,expected_version=current,
                                 changes={'block_kind':'capability'},reason=reason,
                                 terminal_episode={'run_id':episode['run_id'],
                                                   'event_id':episode['event_id']+shift})
                self.assertEqual(intervening,self.dump())
                self.assertEqual(holds,self.holds())
            finally:
                self.conn.execute('DELETE FROM task_events WHERE id=?',(claim['id']+1,))
                self.conn.execute('UPDATE task_events SET id=id-? WHERE task_id=? AND id>?',
                                  (shift,self.target,claim['id']+shift))
                self.conn.commit()
            self.assertEqual(before,self.dump())

    def test_terminal_episode_rejections_preserve_rows_runs_events_and_links(self):
        fresh=self.episode(43)
        version=repair.amend(kb,self.conn,self.target)['version']
        before=self.dump()
        for episode in ({'run_id':43},{'run_id':43,'event_id':fresh['event_id'],'note':'closed object only'},
                        {'run_id':'43','event_id':fresh['event_id']},
                        {'run_id':True,'event_id':fresh['event_id']},
                        {'run_id':0,'event_id':fresh['event_id']},
                        {'run_id':999,'event_id':fresh['event_id']},
                        {'run_id':43,'event_id':999}):
            with self.subTest(episode=episode),self.assertRaises(ValueError):
                repair.amend(kb,self.conn,self.target,expected_version=version,
                             changes={'block_kind':'capability'},
                             reason='Input supplier: agent. Repair evidence: material input supplied.',
                             terminal_episode=episode)
            self.assertEqual(before,self.dump())
        with self.assertRaises(ValueError):   # an episode never travels alone or bundles edits
            repair.amend(kb,self.conn,self.target,expected_version=version,changes={'skills':[]},
                         reason='Input supplier: agent. Repair evidence: material input supplied.',
                         terminal_episode=fresh)
        self.assertEqual(before,self.dump())
        with self.assertRaises(ValueError):
            repair.amend(kb,self.conn,self.target,expected_version=version,
                         changes={'block_kind':'capability','priority':5},
                         reason='Input supplier: agent. Repair evidence: material input supplied.',
                         terminal_episode=fresh)
        self.assertEqual(before,self.dump())
        with self.assertRaises(ValueError):   # untyped containment needs material repair evidence
            repair.amend(kb,self.conn,self.target,expected_version=version,
                         changes={'block_kind':'capability'},reason='Input supplier: agent.',
                         terminal_episode=fresh)
        self.assertEqual(before,self.dump())
        with self.assertRaises(ValueError):   # never an owner or model-unattributed gate
            repair.amend(kb,self.conn,self.target,expected_version=version,
                         changes={'block_kind':'capability'},
                         reason='Input supplier: owner. Repair evidence: owner decided',
                         terminal_episode=fresh)
        self.assertEqual(before,self.dump())
        kb._append_event(self.conn,self.target,'unblocked',None);self.conn.commit()
        before=self.dump()
        with self.assertRaisesRegex(ValueError,'supersedes'):
            repair.amend(kb,self.conn,self.target,
                         expected_version=repair.amend(kb,self.conn,self.target)['version'],
                         changes={'block_kind':'capability'},
                         reason='Input supplier: agent. Repair evidence: material input supplied.',
                         terminal_episode=fresh)
        self.assertEqual(before,self.dump())
        self.conn.execute("UPDATE tasks SET status='blocked',block_kind='needs_input' WHERE id=?",(self.target,))
        self.conn.commit();before=self.dump()
        with self.assertRaises(ValueError):
            repair.amend(kb,self.conn,self.target,expected_version=repair.amend(kb,self.conn,self.target)['version'],
                         changes={'block_kind':'capability'},reason='Input supplier: agent.',
                         terminal_episode={'run_id':43,'event_id':fresh['event_id']})
        self.assertEqual(before,self.dump())
        self.conn.execute("UPDATE tasks SET block_kind=NULL,status='blocked',body='ASK: owner must decide' WHERE id=?",
                          (self.target,));self.conn.commit();before=self.dump()
        with self.assertRaises(ValueError):
            repair.amend(kb,self.conn,self.target,expected_version=repair.amend(kb,self.conn,self.target)['version'],
                         changes={'block_kind':'capability'},
                         reason='Input supplier: agent. Repair evidence: material input supplied.',
                         terminal_episode={'run_id':43,'event_id':fresh['event_id']})
        self.assertEqual(before,self.dump())

    def test_terminal_episode_reaffirmation_rejects_incoherent_reclaim_evidence(self):
        self.conn.execute("UPDATE tasks SET status='ready',skills='[]',block_kind='capability',"
                          "max_retries=1,consecutive_failures=0 WHERE id=?",(self.target,));self.conn.commit()
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome)"
                          " VALUES(44,?,'reclaimed','feature-reviewer',?,?,'reclaimed')",
                          (self.target,self.now-300,self.now))
        kb._append_event(self.conn,self.target,'reclaimed',{'retry_status':'review'},run_id=44)
        self.conn.execute("UPDATE tasks SET status='blocked',consecutive_failures=1,"
                          "last_failure_error='stale_lock=stale' WHERE id=?",(self.target,))
        kb._append_event(self.conn,self.target,'gave_up',
                         {'trigger_outcome':'reclaimed','failures':1,'effective_limit':1,
                          'limit_source':'task','retry_status':'review'});self.conn.commit()
        event=self.conn.execute("SELECT id FROM task_events WHERE task_id=? AND kind='gave_up'"
                                " ORDER BY id DESC LIMIT 1",(self.target,)).fetchone()[0]
        for payload in ({'failures':9,'effective_limit':1,'limit_source':'task','trigger_outcome':'reclaimed'},
                        {'failures':1,'effective_limit':7,'limit_source':'task','trigger_outcome':'reclaimed'},
                        {'failures':1,'effective_limit':1,'limit_source':'task','trigger_outcome':'timed_out'},
                        {'trigger_outcome':'reclaimed'}):
            with self.subTest(payload=payload):
                self.conn.execute("UPDATE task_events SET payload=? WHERE id=?",(json.dumps(payload),event))
                self.conn.commit();before=self.dump()
                with self.assertRaises(ValueError):
                    self.amend_episode({'run_id':44,'event_id':event},
                                       'Input supplier: agent. Authorized continuation: reclaim audited.')
                self.assertEqual(before,self.dump())
        self.conn.execute("UPDATE task_events SET payload=? WHERE id=?",(json.dumps(
            {'trigger_outcome':'reclaimed','failures':1,'effective_limit':1,'limit_source':'task'}),event))
        self.conn.execute("UPDATE task_runs SET status='crashed',outcome='crashed' WHERE id=44");self.conn.commit()
        before=self.dump()
        with self.assertRaisesRegex(ValueError,'reclaimed'):
            self.amend_episode({'run_id':44,'event_id':event},
                               'Input supplier: agent. Authorized continuation: reclaim audited.')
        self.assertEqual(before,self.dump())

    def test_terminal_episode_containment_respects_parent_gate_and_ready_source(self):
        parent=kb.create_task(self.conn,title='Open parent',assignee='standard-implementer')
        self.conn.execute('INSERT INTO task_links(parent_id,child_id) VALUES(?,?)',(parent,self.target))
        self.conn.commit()
        self.containment(self.episode(43,source_status='ready'))
        current=self.current_hold()
        self.assertEqual('todo',resume_recovered.resume_recovered(
            kb,self.conn,self.target,current['version'],'Open parent keeps the containment gated')['status'])
        self.conn.execute('DELETE FROM task_links WHERE child_id=?',(self.target,))
        self.conn.execute("UPDATE tasks SET status='ready',block_kind=NULL WHERE id=?",(self.target,))
        self.conn.commit()
        self.containment(self.episode(45,source_status='ready'))
        current=self.current_hold()
        self.assertEqual('ready',resume_recovered.resume_recovered(
            kb,self.conn,self.target,current['version'],'Ready source keeps its resume phase')['status'])
        self.assertEqual('capability',kb.get_task(self.conn,self.target).block_kind)

    def test_failed_reviewer_classification_and_versioned_resume_preserve_review_phase(self):
        self.conn.execute("UPDATE tasks SET status='blocked',max_retries=1,consecutive_failures=1,last_failure_error='protocol violation' WHERE id=?",(self.target,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'crashed','feature-reviewer',?,?,'crashed')",(self.target,self.now-20,self.now))
        kb._append_event(self.conn,self.target,'gave_up',{'retry_status':'review','protocol_violation':True});self.conn.commit()
        version=repair.amend(kb,self.conn,self.target)['version']
        repair.amend(kb,self.conn,self.target,expected_version=version,changes={'block_kind':'capability','skills':[]},reason='Input supplier: agent. Removed unavailable coordinator-only skill from failed review.')
        hold=monitor.recovery.read_board(self.conn,self.root,'testboard',monitor.recovery.helper_identity(self.root))[0]
        result=resume_recovered.resume_recovered(kb,self.conn,self.target,hold['version'],'Actual preload repair read back; resume reviewer without replenishing allowances')
        self.assertEqual('review',result['status'])
        row=self.conn.execute('SELECT consecutive_failures,max_retries,last_failure_error FROM tasks WHERE id=?',(self.target,)).fetchone()
        self.assertEqual((1,1,'protocol violation'),tuple(row))

    def test_skill_catalog_missing_disabled_and_role_scope(self):
        with patch.object(repair,'available_skills',return_value={'systematic-debugging'}):
            for name in ('kanban-orchestration','disabled-skill'):
                with self.assertRaisesRegex(ValueError,'unavailable'):self.apply({'skills':[name]})
            self.apply({'skills':['systematic-debugging']})

    def test_one_measured_runtime_revision_without_resetting_retries(self):
        with self.assertRaises(ValueError):self.apply({'max_runtime_seconds':2700})
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'timed_out','head-coordinator',?,?,'timed_out')",(self.target,self.now-1000,self.now));self.conn.commit()
        evidence={'run_id':43,'remaining_work':'four exact recovered producers','expected_completion':'within2700s','stop_condition':'stop on first refusal or failure'}
        self.apply({'max_runtime_seconds':2700},runtime_evidence=evidence)
        task=kb.get_task(self.conn,self.target);self.assertEqual(2700,task.max_runtime_seconds);self.assertEqual(1,task.max_retries)
        with self.assertRaisesRegex(ValueError,'Only one'):self.apply({'max_runtime_seconds':3000},runtime_evidence=evidence)

    def test_adapter_exact_seams_idempotence_and_fail_closed(self):
        for name in EDITS:
            data=(native/name).read_text();after=adapt(name,data)
            self.assertEqual(after,adapt(name,after))
            with self.assertRaises(ValueError):adapt(name,'# incompatible source')

    def test_advertised_inspection_and_crash_classification_need_no_episode(self):
        from coordinator_repair_adapter import SCHEMA, PREVIOUS_INSPECTION
        from recovered_resume_adapter import adapt as resume_adapt
        scope={};exec(SCHEMA,scope);schema=scope['KANBAN_AMEND_SCHEMA']
        self.assertIn('Omit changes and expected_version',schema['description'])
        self.assertIn('without terminal_episode',schema['parameters']['properties']['changes']['description'])
        self.assertIn('not for crashed or timed_out',schema['parameters']['properties']['terminal_episode']['description'])
        # The exact installed predecessor must migrate, then remain idempotent.
        installed=(native/'tools/kanban_tools_schemas.py').read_text()
        current=adapt('tools/kanban_tools_schemas.py',installed)
        self.assertEqual(current,adapt('tools/kanban_tools_schemas.py',current.replace(SCHEMA,PREVIOUS_INSPECTION,1)))
        import tools.kanban_tools_schemas as schemas
        exec(compile(adapt('tools/kanban_tools_schemas.py',resume_adapt('tools/kanban_tools_schemas.py',installed)),
                     'fixture-schemas','exec'),schemas.__dict__)
        module=types.ModuleType('tools.fixture_inspect_crash')
        exec(compile(adapt('tools/kanban_tools.py',resume_adapt('tools/kanban_tools.py',
                     (native/'tools/kanban_tools.py').read_text())),'fixture-tools','exec'),module.__dict__)
        self.conn.execute("UPDATE tasks SET status='blocked',consecutive_failures=1,last_failure_error='protocol violation' WHERE id=?",(self.target,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'crashed','feature-reviewer',?,?,'crashed')",(self.target,self.now-20,self.now));self.conn.commit()
        before=self.dump()
        inspected=json.loads(module._handle_amend({'task_id':self.target}))
        self.assertRegex(inspected['version'],r'^[0-9a-f]{64}$')
        self.assertEqual(before,self.dump())
        applied=json.loads(module._handle_amend({'task_id':self.target,'expected_version':inspected['version'],
            'changes':{'block_kind':'capability'},'reason':'Input supplier: agent. Repaired the missing native terminal response guidance.'}))
        self.assertTrue(applied['applied'])
        row=self.conn.execute('SELECT status,block_kind,consecutive_failures,max_retries,last_failure_error FROM tasks WHERE id=?',(self.target,)).fetchone()
        self.assertEqual(('blocked','capability',1,1,'protocol violation'),tuple(row))
        self.assertEqual(before[1],self.dump()[1])  # Every historical run unchanged.
        self.assertEqual(before[3],self.dump()[3])  # Every prerequisite unchanged.

    def intake_target(self):
        self.target=kb.create_task(self.conn,title='Independent P2 readiness',body='Goal: One standalone readiness verdict.',
            assignee='feature-reviewer',parents=(self.actor,),tenant='continuous-improvement',
            workspace_kind='dir',workspace_path=str(self.work),max_runtime_seconds=900)
        self.assertEqual('todo',kb.get_task(self.conn,self.target).status)
        # Native creation inherits the coordinator origin session, including the
        # actual unstarted pcops P2. Retain it; no claim or run is fabricated.
        self.conn.execute('UPDATE tasks SET session_id=? WHERE id=?',('creator-origin-session',self.target));self.conn.commit()

    def intake(self,**kwargs):
        version=repair.amend(kb,self.conn,self.target)['version']
        args={'expected_version':version,'changes':{'tenant':'verification'},
              'verification_intake':'standalone',
              'reason':'Input supplier: agent. Authorized continuation: assessed P2 intake correction; preserve all routing gates.'}
        args.update(kwargs)
        return repair.amend(kb,self.conn,self.target,**args)

    def test_standalone_verification_intake_strengthens_guard_without_releasing_work(self):
        self.intake_target();before=self.dump()
        result=self.intake()
        self.assertTrue(result['applied'])
        task=self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone()
        old=before[0];after=self.dump()
        for original,current in zip(old,after[0]):
            expected=dict(original)
            if original['id']==self.target:expected['tenant']='verification'
            self.assertEqual(expected,current)
        self.assertEqual(before[1],after[1]);self.assertEqual(before[3],after[3])
        self.assertEqual(before[2],after[2][:-1])
        event=after[2][-1]
        self.assertEqual('coordinator_verification_intake',event['kind'])
        proof=json.loads(event['payload'])
        self.assertEqual(self.actor,proof['actor_task'])
        self.assertEqual({'tenant':'continuous-improvement'},proof['before'])
        self.assertEqual({'tenant':'verification'},proof['after'])
        self.assertEqual('todo',task['status'])
        spec=importlib.util.spec_from_file_location('intake_guard',source/'review-verdict-guard.py')
        guard=importlib.util.module_from_spec(spec);spec.loader.exec_module(guard)
        self.assertTrue(guard.verification(task,self.conn))
        self.assertFalse(guard.native_review(self.conn,task))
        payload={'tool_name':'kanban_complete','tool_input':{'board':'testboard','task_id':self.target}}
        self.assertEqual('block',guard.guard(payload,self.root)['action'])
        # Even valid verdict metadata cannot bypass a retained rejected parent.
        self.conn.execute("UPDATE tasks SET status='done',assignee='feature-reviewer',tenant='verification' WHERE id=?",(self.actor,))
        self.conn.execute("UPDATE task_runs SET profile='feature-reviewer',status='done',outcome='completed',ended_at=?,metadata=? WHERE id=42",
            (self.now,json.dumps({'verdict':'request-changes','revision':'a'*40,'checks':[{'command':'independent check','exit_code':0}],'requested_changes':['Keep the product held.']})))
        self.conn.commit()
        payload['tool_input']['metadata']={'verdict':'accept','revision':'b'*40,'checks':[{'command':'read actual P2 inputs','exit_code':0}]}
        blocked=guard.guard(payload,self.root)
        self.assertEqual('block',blocked['action'])
        self.assertIn('Review '+self.actor+' requested changes',blocked['message'])

    def test_verification_intake_refusals_are_atomic(self):
        self.intake_target()
        for changes in ({'tenant':'verification'},{'tenant':'verification','body':'Changed scope'}):
            before=self.dump()
            with self.assertRaises(ValueError):self.intake(changes=changes,verification_intake=None)
            self.assertEqual(before,self.dump())
        for column,value in (('status','ready'),('assignee','standard-implementer'),('assignee','project-auditor'),
                ('tenant','review-question'),('tenant','verification'),('block_kind','needs_input'),
                ('started_at',self.now),('worker_started_at','prior'),
                ('consecutive_failures',1),('max_runtime_seconds',None),('workspace_kind','scratch')):
            old=self.conn.execute('SELECT '+column+' FROM tasks WHERE id=?',(self.target,)).fetchone()[0]
            self.conn.execute('UPDATE tasks SET '+column+'=? WHERE id=?',(value,self.target));self.conn.commit()
            before=self.dump()
            with self.subTest(column=column,value=value),self.assertRaises(ValueError):self.intake()
            self.assertEqual(before,self.dump())
            self.conn.execute('UPDATE tasks SET '+column+'=? WHERE id=?',(old,self.target));self.conn.commit()
        for kind,payload in (('claimed',{}),('spawned',{}),('review_requested',{}),('blocked',{}),('unblocked',{})):
            kb._append_event(self.conn,self.target,kind,payload);self.conn.commit();before=self.dump()
            with self.subTest(event=kind),self.assertRaises(ValueError):self.intake()
            self.assertEqual(before,self.dump())
            self.conn.execute('DELETE FROM task_events WHERE task_id=? AND kind=?',(self.target,kind));self.conn.commit()
        body=self.conn.execute('SELECT body FROM tasks WHERE id=?',(self.target,)).fetchone()[0]
        self.conn.execute("UPDATE tasks SET body='ASK: owner decision' WHERE id=?",(self.target,));self.conn.commit()
        before=self.dump()
        with self.assertRaises(ValueError):self.intake()
        self.assertEqual(before,self.dump())
        self.conn.execute('UPDATE tasks SET body=? WHERE id=?',(body,self.target));self.conn.commit()
        created=self.conn.execute("SELECT id,payload FROM task_events WHERE task_id=? AND kind='created'",(self.target,)).fetchone()
        payload=json.loads(created['payload']);payload['workflow']={'version':1,'review':'native-review-v1','plan_author':'owner'}
        self.conn.execute('UPDATE task_events SET payload=? WHERE id=?',(json.dumps(payload),created['id']));self.conn.commit()
        before=self.dump()
        with self.assertRaises(ValueError):self.intake()
        self.assertEqual(before,self.dump())
        self.conn.execute('UPDATE task_events SET payload=? WHERE id=?',(created['payload'],created['id']));self.conn.commit()
        self.conn.execute("INSERT INTO task_runs(task_id,profile,status,outcome,started_at,ended_at) VALUES(?,'feature-reviewer','scheduled','scheduled',?,?)",(self.target,self.now,self.now));self.conn.commit()
        before=self.dump()
        with self.assertRaises(ValueError):self.intake()
        self.assertEqual(before,self.dump())

    def test_native_intake_migration_forwarding_and_explicit_creation_tenant(self):
        from coordinator_repair_adapter import SCHEMA,PREVIOUS_INTAKE_SCHEMA,HANDLER,PREVIOUS_INTAKE_HANDLER
        from recovered_resume_adapter import adapt as resume_adapt
        import tools.kanban_tools_schemas as schemas
        tools=adapt('tools/kanban_tools.py',resume_adapt('tools/kanban_tools.py',(native/'tools/kanban_tools.py').read_text()))
        schema_source=adapt('tools/kanban_tools_schemas.py',resume_adapt('tools/kanban_tools_schemas.py',(native/'tools/kanban_tools_schemas.py').read_text()))
        self.assertEqual(tools,adapt('tools/kanban_tools.py',tools.replace(HANDLER,PREVIOUS_INTAKE_HANDLER,1)))
        self.assertEqual(schema_source,adapt('tools/kanban_tools_schemas.py',schema_source.replace(SCHEMA,PREVIOUS_INTAKE_SCHEMA,1)))
        exec(compile(schema_source,'fixture-schemas','exec'),schemas.__dict__)
        module=types.ModuleType('tools.fixture_verification_intake')
        exec(compile(tools,'fixture-tools','exec'),module.__dict__)
        # Exercise the actual native create handler's ambient-tenant behavior.
        common={'board':'testboard','assignee':'feature-reviewer','parents':[self.actor],
                'workspace_kind':'dir','workspace_path':str(self.work),'max_runtime_seconds':900}
        with patch.dict(os.environ,{'HERMES_TENANT':'continuous-improvement'}):
            inherited=json.loads(module._handle_create({**common,'title':'Inherited verifier'}))
            explicit=json.loads(module._handle_create({**common,'title':'Explicit verifier','tenant':'verification'}))
        self.assertNotIn('error',inherited);self.assertNotIn('error',explicit)
        inherited_id=inherited['task_id'];explicit_id=explicit['task_id']
        self.assertEqual('continuous-improvement',kb.get_task(self.conn,inherited_id).tenant)
        self.assertEqual('verification',kb.get_task(self.conn,explicit_id).tenant)
        self.conn.execute("UPDATE tasks SET tenant='continuous-improvement' WHERE id=?",(self.actor,));self.conn.commit()
        with patch.dict(os.environ):
            os.environ.pop('HERMES_TENANT',None)
            parent_inherited=json.loads(module._handle_create({**common,'title':'Parent inherited verifier'}))
        self.assertNotIn('error',parent_inherited)
        self.assertEqual('continuous-improvement',kb.get_task(self.conn,parent_inherited['task_id']).tenant)
        before=[tuple(r) for r in self.conn.execute('SELECT * FROM task_links ORDER BY parent_id,child_id')]
        inspected=json.loads(module._handle_amend({'task_id':inherited_id}))
        applied=json.loads(module._handle_amend({'task_id':inherited_id,'expected_version':inspected['version'],
            'changes':{'tenant':'verification'},'verification_intake':'standalone',
            'reason':'Input supplier: agent. Authorized continuation: explicit standalone verdict intake.'}))
        self.assertTrue(applied.get('applied'),applied)
        self.assertEqual(before,[tuple(r) for r in self.conn.execute('SELECT * FROM task_links ORDER BY parent_id,child_id')])
        self.assertEqual('todo',kb.get_task(self.conn,inherited_id).status)
        self.assertEqual(0,self.conn.execute('SELECT count(*) FROM task_runs WHERE task_id=?',(inherited_id,)).fetchone()[0])
        self.assertEqual(0,self.conn.execute("SELECT count(*) FROM task_events WHERE task_id=? AND kind='review_requested'",(inherited_id,)).fetchone()[0])

    def test_verification_intake_exact_cas_and_closed_evidence(self):
        self.intake_target()
        for args in ({'expected_version':'0'*64},{'verification_intake':True},
                     {'verification_intake':{'tenant':'verification'}},
                     {'reason':'Input supplier: agent.'},
                     {'changes':{'tenant':'verification','body':'different scope'}},
                     {'terminal_episode':{'run_id':43,'event_id':1}},
                     {'workspace_rebind':{'workspace_kind':'dir','workspace_path':str(self.work)}}):
            before=self.dump()
            with self.subTest(args=args),self.assertRaises(ValueError):self.intake(**args)
            self.assertEqual(before,self.dump())
        self.intake();before=self.dump()
        with self.assertRaises(ValueError):self.intake()
        self.assertEqual(before,self.dump())

    def test_terminal_episode_seam_is_closed_migrated_and_forwarded(self):
        from coordinator_repair_adapter import SCHEMA
        seam={};exec(SCHEMA,seam);schema=seam['KANBAN_AMEND_SCHEMA']
        episode=schema['parameters']['properties']['terminal_episode']
        self.assertEqual({'terminal_episode','workspace_rebind','verification_intake'},set(schema['parameters']['properties'])-
                         {'board','task_id','expected_version','changes','reason','runtime_evidence'})
        self.assertEqual({'run_id','event_id'},set(episode['properties']))
        self.assertEqual(['run_id','event_id'],episode['required'])
        self.assertFalse(episode['additionalProperties'])
        self.assertNotIn('terminal_episode',schema['parameters']['required'])
        self.assertIn('exactly',schema['description'])
        # Both branches carry the same evidence contract in the advertised schema.
        self.assertIn('both the containment and the same-kind reaffirmation',
                      schema['description'])
        tools=adapt('tools/kanban_tools.py',(native/'tools/kanban_tools.py').read_text())
        self.assertEqual(1,tools.count('def _handle_amend('))
        self.assertEqual(1,tools.count('registry.register(name="kanban_amend"'))
        self.assertIn('terminal_episode=args.get("terminal_episode")',tools)
        schemas=adapt('tools/kanban_tools_schemas.py',(native/'tools/kanban_tools_schemas.py').read_text())
        self.assertEqual(1,schemas.count('"terminal_episode"'))
        self.assertIn('"terminal_episode"',schemas)
        from recovered_resume_adapter import adapt as resume_adapt
        # Install the adapted schema module first: the native wrapper validates
        # tool arguments against the registered schema, so this test must not
        # inherit another test's injection.
        import tools.kanban_tools_schemas as seam_schemas
        exec(compile(adapt('tools/kanban_tools_schemas.py',resume_adapt('tools/kanban_tools_schemas.py',
                     (native/'tools/kanban_tools_schemas.py').read_text())),'fixture-schemas','exec'),
             seam_schemas.__dict__)
        module=types.ModuleType('tools.fixture_terminal_episode')
        exec(compile(adapt('tools/kanban_tools.py',resume_adapt('tools/kanban_tools.py',
                     (native/'tools/kanban_tools.py').read_text())),'fixture-tools','exec'),module.__dict__)
        episode=self.episode(43)
        inspected=json.loads(module._handle_amend({'task_id':self.target}))
        applied=json.loads(module._handle_amend({'task_id':self.target,'expected_version':inspected['version'],
            'changes':{'block_kind':'capability'},'reason':self.containment_reason(),'terminal_episode':episode}))
        self.assertTrue(applied['applied'])
        self.assertEqual('capability',kb.get_task(self.conn,self.target).block_kind)
        before=self.dump()
        refused=json.loads(module._handle_amend({'task_id':self.target,'expected_version':applied['version'],
            'changes':{'block_kind':'capability'},'reason':self.containment_reason(),
            'terminal_episode':{'run_id':43,'event_id':episode['event_id'],'note':'not closed'}}))
        self.assertIn('error',refused)
        self.assertEqual(before,self.dump())

    def test_workspace_rebind_seam_is_closed_migrated_and_forwarded(self):
        from coordinator_repair_adapter import SCHEMA,PREVIOUS_REBIND,PREVIOUS,LEGACY,HANDLER,PREVIOUS_HANDLER,LEGACY_HANDLER
        seam={};exec(SCHEMA,seam);schema=seam['KANBAN_AMEND_SCHEMA']
        rebind=schema['parameters']['properties']['workspace_rebind']
        self.assertEqual({'workspace_kind','workspace_path'},set(rebind['properties']))
        self.assertEqual(['workspace_kind','workspace_path'],rebind['required'])
        self.assertFalse(rebind['additionalProperties'])
        self.assertEqual(['dir'],rebind['properties']['workspace_kind']['enum'])
        self.assertNotIn('workspace_rebind',schema['parameters']['required'])
        self.assertIn('workspace-prep receipt',schema['description'])
        self.assertLessEqual({'workspace_kind','workspace_path'},
                             set(schema['parameters']['properties']['changes']['properties']))
        # Qualify the installed bytes, then construct exact predecessor fixtures
        # from the canonical current seam. The installed runtime may already be
        # current; never require a downgrade to make its own regression pass.
        installed_tools=(native/'tools/kanban_tools.py').read_text()
        installed_schemas=(native/'tools/kanban_tools_schemas.py').read_text()
        current_tools=adapt('tools/kanban_tools.py',installed_tools)
        current_schemas=adapt('tools/kanban_tools_schemas.py',installed_schemas)
        self.assertEqual(1,current_tools.count(HANDLER))
        self.assertEqual(1,current_schemas.count(SCHEMA))
        self.assertEqual(current_tools,adapt('tools/kanban_tools.py',current_tools))
        self.assertEqual(current_schemas,adapt('tools/kanban_tools_schemas.py',current_schemas))
        self.assertIn('never-started TODO',schema['description'])
        self.assertEqual(current_schemas,adapt('tools/kanban_tools_schemas.py',
                                              current_schemas.replace(SCHEMA,PREVIOUS_REBIND,1)))
        tools=current_tools.replace(HANDLER,PREVIOUS_HANDLER,1)
        schemas=current_schemas.replace(SCHEMA,PREVIOUS,1)
        self.assertEqual(1,tools.count(PREVIOUS_HANDLER));self.assertEqual(1,schemas.count(PREVIOUS))
        migrated=adapt('tools/kanban_tools.py',tools)
        self.assertEqual(current_tools,migrated)
        self.assertEqual(1,migrated.count('workspace_rebind=args.get("workspace_rebind")'))
        self.assertEqual(1,migrated.count('def _handle_amend('))
        self.assertEqual(migrated,adapt('tools/kanban_tools.py',tools.replace(PREVIOUS_HANDLER,LEGACY_HANDLER,1)))
        migrated_schemas=adapt('tools/kanban_tools_schemas.py',schemas)
        self.assertEqual(current_schemas,migrated_schemas)
        self.assertEqual(1,migrated_schemas.count('"workspace_rebind"'))
        self.assertEqual(migrated_schemas,adapt('tools/kanban_tools_schemas.py',schemas.replace(PREVIOUS,LEGACY,1)))
        # The registered schema validates the real call, so only a closed object
        # reaches the handler and a rejected call changes nothing.
        from recovered_resume_adapter import adapt as resume_adapt
        import tools.kanban_tools_schemas as seam_schemas
        exec(compile(adapt('tools/kanban_tools_schemas.py',resume_adapt('tools/kanban_tools_schemas.py',schemas)),
                     'fixture-schemas','exec'),seam_schemas.__dict__)
        module=types.ModuleType('tools.fixture_workspace_rebind')
        exec(compile(adapt('tools/kanban_tools.py',resume_adapt('tools/kanban_tools.py',tools)),
                     'fixture-tools','exec'),module.__dict__)
        self.hold()
        target=self.root/'attested-workspace';target.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(target)}
        inspected=json.loads(module._handle_amend({'task_id':self.target}))
        applied=json.loads(module._handle_amend({'task_id':self.target,'expected_version':inspected['version'],
            'changes':dict(binding),'reason':'Independent workspace-prep receipt recorded in the thread',
            'workspace_rebind':binding}))
        self.assertTrue(applied['applied'])
        self.assertEqual(str(target),kb.get_task(self.conn,self.target).workspace_path)
        before=self.dump()
        refused=json.loads(module._handle_amend({'task_id':self.target,'expected_version':applied['version'],
            'changes':dict(binding,extra='no'),'reason':'Not a closed object',
            'workspace_rebind':dict(binding,extra='no')}))
        self.assertIn('error',refused)
        self.assertEqual(before,self.dump())
        self.assertEqual(installed_tools,(native/'tools/kanban_tools.py').read_text())
        self.assertEqual(installed_schemas,(native/'tools/kanban_tools_schemas.py').read_text())

    def containment_reason(self):
        return ('Input supplier: agent. Repair evidence: the missing plan section was restored and read back; '
                'containment only, unchanged review scope.')

    def rebind(self, workspace, *, changes=None, rebind=None, reason=None):
        version=repair.amend(kb,self.conn,self.target)['version']
        binding=rebind or {'workspace_kind':'dir','workspace_path':str(workspace)}
        return repair.amend(kb,self.conn,self.target,expected_version=version,
                            changes=changes if changes is not None else dict(binding),
                            reason=reason or 'Adopt the attested recovery workspace for this held card',
                            workspace_rebind=binding)

    def refuse_rebind(self, regex, changes, rebind, **kwargs):
        version=repair.amend(kb,self.conn,self.target)['version']
        with self.assertRaisesRegex(ValueError,regex):
            repair.amend(kb,self.conn,self.target,expected_version=version,changes=changes,
                         reason='Adopt the attested recovery workspace for this held card',
                         workspace_rebind=rebind,**kwargs)

    def test_workspace_rebind_records_one_preimage_event_and_preserves_the_sealed_hold(self):
        self.conn.execute("UPDATE tasks SET skills='[]' WHERE id=?",(self.target,));self.conn.commit()
        self.hold()
        target=self.root/'attested-workspace';target.mkdir()
        before=self.dump();version=repair.amend(kb,self.conn,self.target)['version']
        spent=self.holds();self.assertEqual(1,len(spent))
        result=self.rebind(target)
        self.assertTrue(result['applied']);self.assertNotEqual(version,result['version'])
        after=self.dump()
        was={r['id']:r for r in before[0]}[self.target];now={r['id']:r for r in after[0]}[self.target]
        self.assertEqual(dict(was,workspace_kind='dir',workspace_path=str(target)),now)
        self.assertEqual(before[1],after[1])           # no run created, mutated or ended
        self.assertEqual(before[2],after[2][:-1])      # exactly one appended native event
        self.assertEqual(before[3],after[3])           # links untouched
        added=after[2][-1];payload=json.loads(added['payload'])
        self.assertEqual('coordinator_workspace_rebind',added['kind'])
        self.assertEqual('static-directory-rebind',payload['branch'])
        self.assertEqual({'workspace_kind':'scratch','workspace_path':was['workspace_path']},payload['before'])
        self.assertEqual({'workspace_kind':'dir','workspace_path':str(target)},payload['after'])
        self.assertEqual((version,42,self.actor,'testboard'),
                         (payload['expected_version'],payload['actor_run'],payload['actor_task'],payload['board']))
        self.assertIn('before release',payload['attestation_required'])
        # The hold stays sealed: same status/kind/counters and no fresh attempt.
        self.assertEqual(('blocked','capability',was['consecutive_failures'],was['max_retries']),
                         (now['status'],now['block_kind'],now['consecutive_failures'],now['max_retries']))
        # The binding is part of the hold's exact evidence, so the pre-rebind
        # version is spent: only a re-inspected hold may be released.
        current=self.current_hold()
        self.assertEqual('directory',current['workspace_identity']['state'])
        self.assertNotEqual(spent[0]['version'],current['version'])
        with self.assertRaisesRegex(ValueError,'changed'):
            resume_recovered.resume_recovered(kb,self.conn,self.target,spent[0]['version'],
                                              'Stale pre-rebind hold cannot release')
        self.assertEqual('ready',resume_recovered.resume_recovered(
            kb,self.conn,self.target,current['version'],
            'Independent receipt recorded in the thread; resume the unchanged hold')['status'])
        final=self.dump()
        expected={r['id']:r for r in after[0]}
        expected[self.target]=dict(expected[self.target],status='ready')
        self.assertEqual(expected,{r['id']:r for r in final[0]})
        released={r['id']:r for r in final[0]}[self.target]
        self.assertEqual((str(target),'capability'),(released['workspace_path'],released['block_kind']))
        self.assertEqual(['unblocked'],[e['kind'] for e in final[2][len(after[2]):]])

    def test_workspace_rebind_refuses_missing_primary_relative_and_bundled_targets(self):
        self.hold()
        good=self.root/'good';good.mkdir()
        other=self.root/'other';other.mkdir()
        linked=self.root/'linked';linked.symlink_to(good,target_is_directory=True)
        primary=self.root/'primary';primary.mkdir();(primary/'.git').mkdir()
        worktree=self.root/'worktree';worktree.mkdir();(worktree/'.git').write_text('gitdir: /elsewhere\n')
        # A real bare repository keeps HEAD/config/objects/refs at its own root,
        # so the working-tree .git check alone accepted it.
        bare=self.root/'bare';subprocess.run(['git','init','--bare',str(bare)],check=True,
                                             capture_output=True)
        self.assertEqual('true',subprocess.run(['git','-C',str(bare),'rev-parse','--is-bare-repository'],
                         check=True,capture_output=True,text=True).stdout.strip())
        inside=self.root/'canonical';inside.mkdir();(inside/'inner').mkdir()
        alias=self.root/'alias';alias.symlink_to(inside,target_is_directory=True)
        before=self.dump();holds=self.holds()
        def binding(path,kind='dir'):
            return {'workspace_kind':kind,'workspace_path':str(path)}
        good_binding=binding(good)
        cases=(('missing directory','existing canonical absolute directory',binding(self.root/'missing')),
               ('relative path','existing canonical absolute directory',
                {'workspace_kind':'dir','workspace_path':'relative/workspace'}),
               ('noncanonical path','existing canonical absolute directory',
                {'workspace_kind':'dir','workspace_path':str(good)+'/./'}),
               ('symlinked directory','existing canonical absolute directory',binding(linked)),
               ('symlinked ancestor','existing canonical absolute directory',
                binding(alias/'inner')),
               ('primary checkout','PRIMARY',binding(primary)),
               ('worktree root','PRIMARY',binding(worktree)),
               ('bare repository root','PRIMARY',binding(bare)),
               ('worktree binding','Only a static directory',binding(good,'worktree')),
               ('open object','closed object',dict(good_binding,branch_name='wt/x')))
        for name,expected,rebind in cases:
            with self.subTest(case=name):
                self.refuse_rebind(expected,{'workspace_kind':'dir','workspace_path':str(good)}
                                   if name=='open object' else dict(rebind),rebind)
                self.assertEqual(before,self.dump());self.assertEqual(holds,self.holds())
        with self.subTest(case='changes disagree with the closed object'):
            self.refuse_rebind('exactly its own two fields',binding(other),good_binding)
            self.assertEqual(before,self.dump())
        with self.subTest(case='bundled with another amendment'):
            self.refuse_rebind('exactly its own two fields',dict(good_binding,priority=5),good_binding)
            self.assertEqual(before,self.dump())
        with self.subTest(case='binding without its closed rebind evidence'):
            self.refuse_rebind('closed rebind evidence',dict(good_binding),None)
            self.assertEqual(before,self.dump())
        with self.subTest(case='inspection carries no binding'):
            self.refuse_rebind('Inspection takes no amendment evidence',None,good_binding)
            self.assertEqual(before,self.dump())
        with self.subTest(case='binding never rides a terminal episode'):
            self.refuse_rebind('separate amendments',{'block_kind':'capability'},good_binding,
                               terminal_episode={'run_id':43,'event_id':1})
            self.assertEqual(before,self.dump())
        self.conn.execute("UPDATE tasks SET status='ready' WHERE id=?",(self.target,));self.conn.commit()
        before=self.dump()
        with self.subTest(case='ready card is not parked'):
            self.refuse_rebind('parked technical',dict(good_binding),good_binding)
            self.assertEqual(before,self.dump())
        self.conn.execute("UPDATE tasks SET status='triage',block_kind=NULL WHERE id=?",
                          (self.target,));self.conn.commit();before=self.dump()
        with self.subTest(case='untyped triage cannot adopt a recovery workspace'):
            self.refuse_rebind('parked capability hold',dict(good_binding),good_binding)
            self.assertEqual(before,self.dump())
        self.conn.execute("UPDATE tasks SET status='blocked',block_kind='needs_input' WHERE id=?",
                          (self.target,));self.conn.commit();before=self.dump()
        with self.subTest(case='owner gate stays an owner gate'):
            self.refuse_rebind('parked technical',dict(good_binding),good_binding)
            self.assertEqual(before,self.dump())

    def test_workspace_rebind_accepts_every_parked_status(self):
        self.conn.execute("UPDATE tasks SET skills='[]' WHERE id=?",(self.target,));self.conn.commit()
        target=self.root/'attested-workspace';target.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(target)}
        for status in ('todo','triage','scheduled','blocked'):
            with self.subTest(status=status):
                self.conn.execute("UPDATE tasks SET status=?,block_kind='capability',workspace_kind='scratch',"
                                  "workspace_path=NULL WHERE id=?",(status,self.target));self.conn.commit()
                version=repair.amend(kb,self.conn,self.target)['version']
                self.assertTrue(repair.amend(kb,self.conn,self.target,expected_version=version,
                    changes=dict(binding),reason='Adopt the attested recovery workspace for this held card',
                    workspace_rebind=binding)['applied'])
                row=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
                self.assertEqual((status,'capability','dir',str(target),0),
                                 (row['status'],row['block_kind'],row['workspace_kind'],
                                  row['workspace_path'],row['consecutive_failures']))

    def test_never_started_todo_can_receive_initial_workspace_without_releasing_parents(self):
        self.conn.execute("UPDATE tasks SET status='todo',skills='[]' WHERE id=?",(self.target,))
        self.conn.execute('INSERT INTO task_links(parent_id,child_id) VALUES(?,?)',(self.actor,self.target))
        self.conn.commit()
        directory=self.root/'unprovisioned';directory.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(directory)}
        before=self.dump()
        version=repair.amend(kb,self.conn,self.target)['version']
        result=repair.amend(kb,self.conn,self.target,expected_version=version,changes=dict(binding),
                           workspace_rebind=binding,reason='Supply missing initial source binding; open review prerequisite retained')
        self.assertTrue(result['applied'])
        after=self.dump()
        expected={row['id']:row for row in before[0]}
        expected[self.target]=dict(expected[self.target],**binding)
        self.assertEqual(expected,{row['id']:row for row in after[0]})
        self.assertEqual(before[1],after[1])
        self.assertEqual(before[3],after[3])
        self.assertEqual(['coordinator_workspace_rebind'],[row['kind'] for row in after[2][len(before[2]):]])
        self.assertEqual(('todo',None),tuple(self.conn.execute('SELECT status,block_kind FROM tasks WHERE id=?',(self.target,)).fetchone()))

    def test_initial_binding_never_retypes_gates_or_rebinds_previous_execution(self):
        self.conn.execute("UPDATE tasks SET status='todo',skills='[]' WHERE id=?",(self.target,))
        self.conn.commit()
        directory=self.root/'unprovisioned';directory.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(directory)}
        for assignment in ("workspace_path='/previous/source'", "workspace_kind='dir'",
                           "started_at=1", "block_kind='dependency'", "body='ASK: preserve owner gate'"):
            with self.subTest(assignment=assignment):
                old=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
                self.conn.execute('UPDATE tasks SET '+assignment+' WHERE id=?',(self.target,));self.conn.commit()
                before=self.dump()
                self.refuse_rebind('parked capability hold',dict(binding),binding)
                self.assertEqual(before,self.dump())
                self.conn.execute('UPDATE tasks SET workspace_path=?,workspace_kind=?,started_at=?,block_kind=?,body=? WHERE id=?',
                                  (old['workspace_path'],old['workspace_kind'],old['started_at'],old['block_kind'],old['body'],self.target))
                self.conn.commit()
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,outcome,started_at,ended_at) VALUES(43,?,'spawn_failed','feature-reviewer','spawn_failed',1,2)",(self.target,));self.conn.commit()
        before=self.dump()
        self.refuse_rebind('parked capability hold',dict(binding),binding)
        self.assertEqual(before,self.dump())

    def test_administrative_schedule_does_not_prevent_initial_source_binding(self):
        self.conn.execute("UPDATE tasks SET status='todo',skills='[]' WHERE id=?",(self.target,));self.conn.commit()
        self.assertTrue(kb.schedule_task(self.conn,self.target,reason='Park for source preparation'))
        run=self.conn.execute('SELECT * FROM task_runs WHERE task_id=?',(self.target,)).fetchone()
        self.assertEqual(('scheduled','scheduled',None,None),
                         (run['status'],run['outcome'],run['worker_pid'],run['claim_lock']))
        directory=self.root/'unprovisioned';directory.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(directory)}
        before=self.dump()
        version=repair.amend(kb,self.conn,self.target)['version']
        self.assertTrue(repair.amend(kb,self.conn,self.target,expected_version=version,
            changes=dict(binding),workspace_rebind=binding,
            reason='Initial source preparation after administrative parking')['applied'])
        after=self.dump()
        self.assertEqual(before[1],after[1])
        self.assertEqual(before[3],after[3])
        self.assertEqual(('scheduled',None),tuple(self.conn.execute('SELECT status,block_kind FROM tasks WHERE id=?',(self.target,)).fetchone()))

    def test_administrative_parking_cannot_hide_a_prior_native_claim(self):
        self.conn.execute("UPDATE tasks SET status='todo',skills='[]' WHERE id=?",(self.target,));self.conn.commit()
        self.assertTrue(kb.schedule_task(self.conn,self.target,reason='Park for source preparation'))
        kb._append_event(self.conn,self.target,'claimed',{'run_id':43})
        self.conn.commit()
        directory=self.root/'unprovisioned';directory.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(directory)}
        before=self.dump()
        self.refuse_rebind('parked capability hold',dict(binding),binding)
        self.assertEqual(before,self.dump())

    def test_workspace_rebind_refuses_sha256_detached_bare_root(self):
        # Git can detach HEAD as a 64-hex SHA-256 object name. A detector keyed
        # to the SHA-1 40-hex form read that real repository root as an ordinary
        # static directory, so the PRIMARY refusal follows the repository layout
        # instead of one object format.
        self.hold()
        target=self.root/'sha256-primary.git'
        subprocess.run(['git','init','--bare','--object-format=sha256','--quiet',str(target)],
                       check=True,capture_output=True)
        def git(*args,input=None):
            return subprocess.check_output(['git','-C',str(target),'-c','user.name=Synthetic Fixture',
                '-c','user.email=fixture@example.invalid',*args],input=input,text=True).strip()
        tree=git('mktree',input='')
        commit=git('commit-tree',tree,'-m','Synthetic fixture only')
        git('update-ref','--no-deref','HEAD',commit)
        self.assertEqual(64,len(commit))
        self.assertEqual(commit,(target/'HEAD').read_text().strip())
        self.assertEqual('true',git('rev-parse','--is-bare-repository'))
        self.assertEqual('sha256',git('rev-parse','--show-object-format'))
        self.assertTrue(repair._bare_repository_root(str(target)))
        binding={'workspace_kind':'dir','workspace_path':str(target)}
        before=self.dump();holds=self.holds()
        version=repair.amend(kb,self.conn,self.target)['version']
        with self.assertRaisesRegex(ValueError,'PRIMARY'):
            repair.amend(kb,self.conn,self.target,expected_version=version,changes=dict(binding),
                         reason='Adopt the attested recovery workspace for this held card',
                         workspace_rebind=dict(binding))
        self.assertEqual(before,self.dump());self.assertEqual(holds,self.holds())
        self.assertEqual(version,repair.amend(kb,self.conn,self.target)['version'])
        self.assertEqual(0,self.conn.execute("SELECT COUNT(*) FROM task_events WHERE task_id=? "
                         "AND kind='coordinator_workspace_rebind'",(self.target,)).fetchone()[0])

    def test_workspace_rebind_is_single_use_and_never_replays(self):
        self.hold()
        target=self.root/'attested-workspace';target.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(target)}
        version=repair.amend(kb,self.conn,self.target)['version']
        self.rebind(target)
        after=self.dump()
        with self.assertRaisesRegex(ValueError,'changed'):
            repair.amend(kb,self.conn,self.target,expected_version=version,changes=dict(binding),
                         reason='Replay the consumed binding',workspace_rebind=binding)
        self.assertEqual(after,self.dump())
        self.assertEqual(1,self.conn.execute("SELECT COUNT(*) FROM task_events WHERE task_id=? "
                         "AND kind='coordinator_workspace_rebind'",(self.target,)).fetchone()[0])

    def test_workspace_rebind_consumed_version_survives_an_aba_round_trip(self):
        # A valid A -> B -> A round trip restores an earlier snapshot version
        # byte for byte, so comparing against the current snapshot alone let a
        # spent version authorize another rebind. The recorded consumption,
        # not the restored snapshot, decides.
        self.hold()
        first=self.root/'first-workspace';first.mkdir()
        second=self.root/'second-workspace';second.mkdir()
        def binding(path):
            return {'workspace_kind':'dir','workspace_path':str(path)}
        def inspect():
            return repair.amend(kb,self.conn,self.target)['version']
        def rebind(token,binding_value):
            return repair.amend(kb,self.conn,self.target,expected_version=token,
                                changes=dict(binding_value),workspace_rebind=dict(binding_value),
                                reason='Adopt the attested recovery workspace for this held card')
        a,b=binding(first),binding(second)
        self.assertTrue(rebind(inspect(),a)['applied'])
        spent=inspect()
        self.assertTrue(rebind(spent,b)['applied'])
        self.assertTrue(rebind(inspect(),a)['applied'])
        # The round trip really restored the consumed version, so the stale
        # request passes the current-snapshot comparison and only the durable
        # consumption can refuse it.
        self.assertEqual(spent,inspect())
        before=self.dump();holds=self.holds()
        with self.assertRaisesRegex(ValueError,'already consumed a workspace rebind'):
            rebind(spent,b)
        self.assertEqual(before,self.dump())      # task row, runs, events and links identical
        self.assertEqual(holds,self.holds())
        self.assertEqual(spent,inspect())         # the token stayed spent, never re-minted
        row=dict(self.conn.execute('SELECT workspace_kind,workspace_path,status,block_kind,'
                                   'consecutive_failures FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual(('dir',str(first),'blocked','capability',0),
                         (row['workspace_kind'],row['workspace_path'],row['status'],
                          row['block_kind'],row['consecutive_failures']))
        self.assertEqual(3,self.conn.execute("SELECT COUNT(*) FROM task_events WHERE task_id=? "
                         "AND kind='coordinator_workspace_rebind'",(self.target,)).fetchone()[0])
        # Consumption is per token, not a permanent lock: a genuinely fresh
        # inspection after another amendment can record a later rebind.
        self.assertTrue(self.apply({'priority':1})['applied'])
        fresh=inspect();self.assertNotEqual(spent,fresh)
        self.assertTrue(rebind(fresh,b)['applied'])
        row=dict(self.conn.execute('SELECT workspace_path FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual(str(second),row['workspace_path'])

    def test_workspace_rebind_refuses_the_binding_the_card_already_holds(self):
        # A capability card can already name the requested directory (an earlier
        # recorded binding, or a coordinator-prepared hold). Recording it again
        # would append an event outside the snapshot CAS and hand back the same
        # version, so one expected_version could be replayed indefinitely.
        self.conn.execute("UPDATE tasks SET skills='[]' WHERE id=?",(self.target,));self.conn.commit()
        target=self.root/'attested-workspace';target.mkdir()
        binding={'workspace_kind':'dir','workspace_path':str(target)}
        self.hold()
        with kb.write_txn(self.conn):
            self.conn.execute("UPDATE tasks SET workspace_kind='dir',workspace_path=? WHERE id=?",
                              (str(target),self.target))
        before=self.dump();version=repair.amend(kb,self.conn,self.target)['version']
        row=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual(('dir',str(target),'capability','blocked'),
                         (row['workspace_kind'],row['workspace_path'],row['block_kind'],row['status']))
        for attempt in ('stored binding is not a new amendment','identical replay keeps the version'):
            with self.subTest(attempt=attempt):
                with self.assertRaisesRegex(ValueError,'already holds'):
                    repair.amend(kb,self.conn,self.target,expected_version=version,
                                 changes=dict(binding),
                                 reason='Adopt the attested recovery workspace for this held card',
                                 workspace_rebind=binding)
                self.assertEqual(before,self.dump())
                self.assertEqual(version,repair.amend(kb,self.conn,self.target)['version'])
        self.assertEqual(0,self.conn.execute("SELECT COUNT(*) FROM task_events WHERE task_id=? "
                         "AND kind='coordinator_workspace_rebind'",(self.target,)).fetchone()[0])
        # A genuinely different directory still records normally on this version.
        other=self.root/'other-workspace';other.mkdir()
        other_binding={'workspace_kind':'dir','workspace_path':str(other)}
        applied=repair.amend(kb,self.conn,self.target,expected_version=version,changes=dict(other_binding),
                             reason='Adopt the attested recovery workspace for this held card',
                             workspace_rebind=other_binding)
        self.assertTrue(applied['applied']);self.assertNotEqual(version,applied['version'])
        row=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual(('dir',str(other),'capability','blocked'),
                         (row['workspace_kind'],row['workspace_path'],row['block_kind'],row['status']))
        self.assertEqual(1,self.conn.execute("SELECT COUNT(*) FROM task_events WHERE task_id=? "
                         "AND kind='coordinator_workspace_rebind'",(self.target,)).fetchone()[0])


    def test_actual_native_tool_visibility_and_handler(self):
        from recovered_resume_adapter import adapt as resume_adapt
        import tools.kanban_tools_schemas as schemas
        exec(compile(adapt('tools/kanban_tools_schemas.py',resume_adapt('tools/kanban_tools_schemas.py',(native/'tools/kanban_tools_schemas.py').read_text())),'fixture-schemas','exec'),schemas.__dict__)
        module=types.ModuleType('tools.fixture_coordinator_repair')
        exec(compile(adapt('tools/kanban_tools.py',resume_adapt('tools/kanban_tools.py',(native/'tools/kanban_tools.py').read_text())),'fixture-tools','exec'),module.__dict__)
        self.assertTrue(module._check_kanban_amend_mode())
        inspected=json.loads(module._handle_amend({'task_id':self.target}))
        self.assertIn('version',inspected)
        applied=json.loads(module._handle_amend({'task_id':self.target,'expected_version':inspected['version'],'changes':{'skills':[]},'reason':'Remove invalid role preload'}))
        self.assertTrue(applied['applied'])
        with delegated_child_context():
            self.assertFalse(module._check_kanban_amend_mode())
            self.assertIn('error',json.loads(module._handle_amend({'task_id':self.target})))
        with patch.dict(os.environ,{'HERMES_PROFILE':'standard-implementer'}):
            self.assertFalse(module._check_kanban_amend_mode())
            self.assertIn('error',json.loads(module._handle_amend({'task_id':self.target})))

    def test_actual_assignee_catalog_disabled_skill_and_malicious_workspace(self):
        (self.root/'hermes-agent').symlink_to(native,target_is_directory=True)
        profile=self.root/'profiles/feature-reviewer';profile.mkdir(parents=True)
        (profile/'config.yaml').write_text('skills:\n  disabled: [disabled-skill]\n')
        for name in ('available-skill','disabled-skill'):
            directory=profile/'skills'/name;directory.mkdir(parents=True)
            (directory/'SKILL.md').write_text('---\nname: '+name+'\ndescription: Fixture skill\n---\nInstructions.\n')
        attack=self.work/'tools';attack.mkdir()
        (attack/'__init__.py').write_text('raise RuntimeError("workspace package executed")')
        (attack/'skills_tool.py').write_text('raise RuntimeError("workspace skill module executed")')
        interpreters=[str(native/'.venv/bin/python')]
        launcher=native/'.hermes/bin/hermes'
        if launcher.is_file():
            # The actual gateway uses a bare managed interpreter, not .venv.
            # Its installed dependency generation needs passive activation.
            runtime=json.loads(subprocess.check_output([str(launcher),'--print-runtime-command'],text=True))
            interpreters.append(runtime[0])
        for interpreter in dict.fromkeys(interpreters):
            with self.subTest(interpreter=interpreter),patch.object(repair.sys,'executable',interpreter):
                names=repair.available_skills(self.root,'feature-reviewer',str(self.work))
                self.assertIn('available-skill',names);self.assertNotIn('disabled-skill',names)
                self.assertNotIn('kanban-orchestration',names)

    def test_catalog_timeout_is_a_capability_hold_not_dispatch_exception(self):
        import subprocess
        spec=importlib.util.spec_from_file_location('fixture_policy',source/'worker-policy.py')
        policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
        with patch.object(repair,'available_skills',side_effect=subprocess.TimeoutExpired('catalog',20)):
            self.assertIn('catalog unavailable',policy.reason(self.conn,self.target))

    def test_catalog_refuses_pending_publication_without_runtime_config_recovery(self):
        fixture=self.root/'catalog-native';fixture.mkdir()
        state=fixture/'install-state';state.mkdir()
        pending=state/'publication.json';pending.write_text('{"pending":"preserve exactly"}')
        config=fixture/'config.yaml';config.write_text('preserve_config: true\n')
        modules={
            'pm/__init__.py':'',
            'pm/environments.py':'''def owning_home_root(native): return None
def install_state_dir(native): return native/'install-state'
def committed_venv(native): return None
def site_packages(environment): return environment
def venv_python_version(environment): return None
def activate_dependencies(native):
    from hermes_cli.runtime_state import recover_publication
    recover_publication(native)
''',
            'hermes_cli/__init__.py':'',
            'hermes_cli/runtime_state.py':'''from contextlib import contextmanager
@contextmanager
def runtime_lock(native,timeout=None): yield True
def lease_generation(environment): return lambda:None
def recover_publication(native):
    (native/'config.yaml').write_text('UNAUTHORIZED RECOVERY')
    (native/'install-state/publication.json').unlink()
''',
            'hermes_constants.py':'def set_hermes_home_override(home): return None\ndef reset_hermes_home_override(token): pass\n',
            'tools/__init__.py':'',
            'tools/skills_tool.py':'def _find_all_skills(): return [{"name":"fixture-skill"}]\n',
        }
        for relative,code in modules.items():
            path=fixture/relative;path.parent.mkdir(parents=True,exist_ok=True);path.write_text(code)
        args=[sys.executable,'-I','-B','-c',repair.CATALOG_PROGRAM,str(fixture)]
        result=subprocess.run(args,capture_output=True,text=True,timeout=10)
        self.assertNotEqual(0,result.returncode)
        self.assertEqual('{"pending":"preserve exactly"}',pending.read_text())
        self.assertEqual('preserve_config: true\n',config.read_text())
        pending.unlink()
        result=subprocess.run(args,capture_output=True,text=True,timeout=10)
        self.assertEqual(0,result.returncode,result.stderr);self.assertEqual(['fixture-skill'],json.loads(result.stdout))
        self.assertEqual('preserve_config: true\n',config.read_text())

    def test_final_native_catalog_failure_clears_prepared_claim_and_checks_actual_workspace(self):
        from worker_runtime_adapter import adapt as dispatch_adapt
        module=types.ModuleType('hermes_cli.fixture_repair_dispatch')
        sys.modules[module.__name__]=module;self.addCleanup(lambda:sys.modules.pop(module.__name__,None))
        exec(compile(dispatch_adapt('kanban_db_dispatch.py',(native/'hermes_cli/kanban_db_dispatch.py').read_text()),'fixture-dispatch','exec'),module.__dict__)
        spec=importlib.util.spec_from_file_location('fixture_final_policy',source/'worker-policy.py')
        policy=importlib.util.module_from_spec(spec);spec.loader.exec_module(policy)
        import hermes_cli
        sys.modules['hermes_cli.nixhomeserver_worker_policy']=policy
        self.addCleanup(lambda:sys.modules.pop('hermes_cli.nixhomeserver_worker_policy',None))
        prepared=self.root/'prepared';prepared.mkdir()
        self.conn.execute("UPDATE tasks SET status='ready',workspace_kind='dir',workspace_path=? WHERE id=?",(str(prepared),self.target));self.conn.commit()
        row=self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone()
        original=policy.reason;calls=[]
        def reason(db,tid,assignee=None):
            calls.append(dict(db.execute('SELECT status,workspace_path FROM tasks WHERE id=?',(tid,)).fetchone()))
            return None if len(calls)==1 else original(db,tid,assignee)
        observed=[]
        def catalog(root,profile,workspace):
            observed.append(workspace)
            return set()
        result=module.DispatchResult()
        with patch.object(hermes_cli,'nixhomeserver_worker_policy',policy,create=True),patch.object(module,'_profile_exists_fn',return_value=lambda _:True),patch.object(policy,'reason',side_effect=reason),patch.object(repair,'available_skills',side_effect=catalog):
            consumed=module._dispatch_lane_task(self.conn,row,'feature-reviewer',result,lane='ready',dry_run=False,ttl_seconds=None,board='testboard',failure_limit=3,spawn_fn=lambda *a: self.fail('Missing skill spawned worker'),per_profile_caps=None,per_profile_running={})
        self.assertFalse(consumed);self.assertEqual([str(prepared)],observed,(result,calls,[dict(r) for r in self.conn.execute('SELECT kind,payload FROM task_events WHERE task_id=?',(self.target,))]))
        task=dict(self.conn.execute('SELECT * FROM tasks WHERE id=?',(self.target,)).fetchone())
        self.assertEqual('blocked',task['status']);self.assertIsNone(task['claim_lock']);self.assertIsNone(task['claim_expires'])
        run=self.conn.execute('SELECT outcome,ended_at FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',(self.target,)).fetchone()
        self.assertEqual('blocked',run['outcome']);self.assertIsNotNone(run['ended_at'])

    def test_monitor_preview_no_writes_and_excludes_running_or_owner(self):
        self.hold()
        actions=monitor.tick(self.root,dry_run=True,now=self.now)
        self.assertEqual(1,len(actions));self.assertFalse((self.root/'runtime').exists())
        self.conn.execute("UPDATE tasks SET status='running' WHERE id=?",(self.target,));self.conn.commit()
        self.assertEqual([],monitor.tick(self.root,dry_run=True,now=self.now))

    def test_monitor_dedup_crash_retry_backoff_escalation_and_material_wake(self):
        self.hold()
        created={};calls=[]
        def create(board,*args):
            calls.append(args);key=args[args.index('--idempotency-key')+1]
            created.setdefault(key,{'id':'t_fixture_'+str(len(created))})
            return created[key]
        with patch.object(monitor,'atomic_write',side_effect=OSError('interrupted')):
            with self.assertRaises(OSError):monitor.tick(self.root,now=10000,create=create)
        monitor.tick(self.root,now=10000,create=create);self.assertEqual(1,len(created))
        self.assertEqual([],monitor.tick(self.root,now=10299,create=create))
        monitor.tick(self.root,now=10300,create=create)
        monitor.tick(self.root,now=11200,create=create)
        action=monitor.tick(self.root,now=14800,create=create);self.assertTrue(action[0]['audit'])
        self.assertEqual([],monitor.tick(self.root,now=30000,create=create))
        kb.add_comment(self.conn,self.target,author='head-coordinator',body='Another holding comment')
        self.assertEqual([],monitor.tick(self.root,now=30000,create=create))
        kb.edit_task(self.conn,self.target,body='Actual changed source input')
        # Changed input remains usable by the existing qualified recovery owner;
        # it cannot buy another automatic controller after the episode audit.
        count=len(created)
        self.assertEqual([],monitor.tick(self.root,now=30000,create=create))
        self.assertEqual(count,len(created))

    def test_monitor_semantic_downstream_wait_and_native_open_dedup(self):
        child=kb.create_task(self.conn,title='Corrective producer',assignee='standard-implementer',triage=True,workspace_kind='scratch')
        kb.link_tasks(self.conn,self.target,child)
        self.conn.execute("UPDATE tasks SET status='todo',body=? WHERE id=?",('Wait for exact result from '+child,self.target));self.conn.commit()
        actions=monitor.tick(self.root,dry_run=True,now=self.now)
        self.assertEqual('possible-dependency-deadlock',actions[0]['issue']['kind'])
        kb.create_task(self.conn,title='Already queued',assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
        self.assertEqual([],monitor.tick(self.root,dry_run=True,now=self.now))

    def test_monitor_consumer_mentions_do_not_commission_recovery(self):
        child=kb.create_task(self.conn,title='Consumer',assignee='head-coordinator',triage=True,workspace_kind='scratch')
        kb.link_tasks(self.conn,self.target,child)
        bodies=[
            'Goal: Accept or reject actual scheduled feature tracker maintenance.\n'
            'Change: Verify installed exact revision and real scheduler receipts; plan slice 4.\n'
            'Notes:\n- Parent supplies immutable plan, approval, exact hashes and job identity.\n'
            '- CI-FTP-001; coordinator '+child+' stays held until explicit verdict.',
            'Wait for upstream input; consumer '+child+' stays held until this verdict.',
            'Wait for upstream input. Consumer '+child+' needs this result.',
            'Do not wait for exact result from '+child,
            'No longer blocked on '+child,
            'Await upstream input\nConsumer '+child+' stays held.',
        ]
        for body in bodies:
            with self.subTest(body=body):
                self.conn.execute("UPDATE tasks SET status='todo',body=? WHERE id=?",(body,self.target));self.conn.commit()
                self.assertEqual([],monitor.tick(self.root,dry_run=True,now=self.now))
                with patch.object(monitor.recovery,'helper_identity',return_value={'changed':'helper'}):
                    self.assertEqual([],monitor.tick(self.root,dry_run=True,now=self.now))
        self.hold()
        self.assertEqual('technical-hold',monitor.observe(self.root,'testboard')[0]['kind'])

    def test_monitor_explicit_downstream_input_requests(self):
        child=kb.create_task(self.conn,title='Producer',assignee='standard-implementer',triage=True,workspace_kind='scratch')
        kb.link_tasks(self.conn,self.target,child)
        for body in ('Await result from '+child, 'Blocked on '+child+' output',
                     'Requires qualified input from '+child, 'Waiting for exact result from '+child):
            with self.subTest(body=body):
                self.conn.execute("UPDATE tasks SET status='todo',body=? WHERE id=?",(body,self.target));self.conn.commit()
                actions=monitor.tick(self.root,dry_run=True,now=self.now)
                self.assertEqual([child],actions[0]['issue']['semantic_candidates'])

    def test_real_blocked_recovery_owner_and_noisy_failure_do_not_replenish_attempts(self):
        self.hold()
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],assignee='head-coordinator',created_by=monitor.CREATOR,triage=True,workspace_kind='scratch',idempotency_key=args[args.index('--idempotency-key')+1])
            return {'id':tid}
        action=monitor.tick(self.root,now=10000,create=create)[0]
        entry=json.loads((self.root/'runtime/deadlock-intake/state.json').read_text())[action['issue']['key']]
        owner=entry['task_id']
        self.assertEqual([],monitor.tick(self.root,now=20000,create=create))
        self.conn.execute("INSERT INTO task_runs(task_id,status,profile,started_at,ended_at,outcome) VALUES(?,'crashed','head-coordinator',10000,10005,'crashed')",(owner,));self.conn.commit()
        self.assertEqual(2,monitor.tick(self.root,now=20000,create=create)[0]['attempt'])
        # Identical target failure with volatile provenance is not new input.
        self.conn.execute("INSERT INTO task_runs(task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(?,'crashed','feature-reviewer',1,2,'crashed',?)",(self.target,json.dumps({'run_id':44,'pid':12345})));self.conn.commit()
        self.assertEqual(action['issue']['version'],monitor.observe(self.root,'testboard')[0]['version'])

    def test_installed_helper_change_wakes_exhausted_semantic_episode(self):
        self.hold();first=monitor.observe(self.root,'testboard')[0]['version']
        helper=self.root/'hermes-agent/hermes_cli/nixhomeserver_coordinator_repair.py';helper.parent.mkdir(parents=True)
        helper.write_text('# repaired helper implementation\n')
        self.assertNotEqual(first,monitor.observe(self.root,'testboard')[0]['version'])

    def test_parked_acknowledgment_expires_but_actual_remedy_writer_is_preserved(self):
        owner=kb.create_task(self.conn,title='Recovery owner',assignee='head-coordinator',created_by=monitor.CREATOR,triage=True,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='ready' WHERE id=?",(owner,));self.conn.commit()
        kb.block_task(self.conn,owner,reason='Input supplier: agent. Waiting without supplied repair',kind='capability')
        self.assertTrue(monitor.previous_owner_active(self.root,'testboard',owner,self.now+100))
        self.assertFalse(monitor.previous_owner_active(self.root,'testboard',owner,self.now+1000))
        self.assertFalse(monitor.previous_owner_active(self.root,'testboard',owner,self.now+100,material_changed=True))
        remedy=kb.create_task(self.conn,title='Actual implementation remedy',assignee='standard-implementer',triage=True,workspace_kind='scratch')
        kb.link_tasks(self.conn,remedy,owner)
        self.conn.execute("UPDATE tasks SET status='blocked' WHERE id=?",(remedy,));self.conn.commit()
        self.assertFalse(monitor.previous_owner_active(self.root,'testboard',owner,self.now+1000))
        self.conn.execute("UPDATE tasks SET status='running',worker_pid=12345 WHERE id=?",(remedy,));self.conn.commit()
        self.assertTrue(monitor.previous_owner_active(self.root,'testboard',owner,self.now+1000,material_changed=True))

    def test_volatile_capability_reason_does_not_reset_attempt_episode(self):
        self.hold();first=monitor.observe(self.root,'testboard')[0]['version']
        with kb.write_txn(self.conn):
            kb._append_event(self.conn,self.target,'blocked',{'kind':'capability','reason':'Input supplier: agent. pid 24502 run 53 elapsed905 log /tmp/another-scratch/receipt not alive'})
        self.assertEqual(first,monitor.observe(self.root,'testboard')[0]['version'])

    def test_old_queued_owner_cannot_expire_and_parked_retry_only_resumes_same_owner(self):
        self.hold();created=[]
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
            created.append((tid,args[args.index('--body')+1]));return {'id':tid}
        first=monitor.tick(self.root,now=self.now,create=create)[0]
        self.assertEqual([],monitor.tick(self.root,now=self.now+10000,create=create))
        owner=created[0][0]
        kb.block_task(self.conn,owner,reason='Input supplier: agent. Missing owner capability',kind='capability')
        next_action=monitor.tick(self.root,now=self.now+10000,create=create)[0]
        self.assertEqual(owner,next_action['issue']['recovery_owner'])
        self.assertIn('Scope: testboard/'+owner+' only',created[1][1])
        self.assertIn('Do not execute the original repair here',created[1][1])
        self.assertIn('guarded-resume that SAME owner',created[1][1])
        controller=created[1][0]
        # Preserve A even after controller B completes. Completion of B must
        # never transfer root repair ownership away from queued A.
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(controller,))
        self.conn.execute("UPDATE tasks SET status='ready' WHERE id=?",(owner,));self.conn.commit()
        self.assertEqual([],monitor.tick(self.root,now=self.now+20000,create=create))
        self.assertEqual(2,len(created))
        self.conn.execute("UPDATE tasks SET status='blocked' WHERE id=?",(owner,));self.conn.commit()
        another=monitor.tick(self.root,now=self.now+20000,create=create)[0]
        self.assertEqual(owner,another['issue']['recovery_owner'])
        self.assertIn('Scope: testboard/'+owner+' only',created[2][1])
        # A dependency-blocked owner remains queued even after its parent lands.
        self.conn.execute("UPDATE tasks SET status='todo' WHERE id=?",(owner,));self.conn.commit()
        self.assertTrue(monitor.previous_owner_active(self.root,'testboard',owner,self.now+10000))

    def feature(self, body='Goal: Requested search improvements.\nStable key: testboard/search'):
        tid=kb.create_task(self.conn,title='[FEATURE TRACKER] Search',body=body,assignee='head-coordinator',triage=True,workspace_kind='scratch')
        self.conn.execute('UPDATE tasks SET created_at=? WHERE id=?',(self.now-3*86400,tid));self.conn.commit()
        return tid

    def test_feature_tracker_orphan_is_intake_only_and_recent_demand_waits(self):
        from feature_flow import observe_features
        tracker=self.feature()
        issue=observe_features(self.conn,'testboard',self.now)[0]
        self.assertEqual(tracker,issue['task_id']);self.assertEqual('feature-delivery-gap',issue['kind'])
        self.assertEqual('triage',kb.get_task(self.conn,tracker).status)
        self.conn.execute('UPDATE tasks SET created_at=? WHERE id=?',(self.now,tracker));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))

    def test_feature_explicit_producer_suppresses_but_context_reference_does_not(self):
        from feature_flow import observe_features
        unrelated=kb.create_task(self.conn,title='Unrelated old context',assignee='standard-implementer',workspace_kind='scratch')
        tracker=self.feature('Goal: Search. Context: '+unrelated)
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        producer=kb.create_task(self.conn,title='Search first slice',body='Feature tracker: testboard:'+tracker,assignee='standard-implementer',workspace_kind='scratch')
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(producer,));self.conn.commit()
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_stalled_feature_owner_reconciled_and_routing_churn_does_not_reset_inputs(self):
        from feature_flow import observe_features
        tracker=self.feature();initial=observe_features(self.conn,'testboard',self.now)[0]['version']
        route=kb.create_task(self.conn,title='Old feature routing',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',triage=True,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET created_at=?,status='scheduled' WHERE id=?",(self.now-4*86400,route));self.conn.commit()
        issue=observe_features(self.conn,'testboard',self.now)[0]
        self.assertEqual([route],issue['existing_owners']);self.assertEqual(initial,issue['version'])
        kb.add_comment(self.conn,tracker,author='aging-escalation',body='Still waiting; new timestamp')
        self.assertEqual(initial,observe_features(self.conn,'testboard',self.now)[0]['version'])
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(route,));self.conn.commit()
        self.assertEqual(initial,observe_features(self.conn,'testboard',self.now)[0]['version'])

    def test_feature_disposition_requires_exact_scope_and_independent_evidence(self):
        from feature_flow import observe_features
        tracker=self.feature();version=observe_features(self.conn,'testboard',self.now)[0]['version']
        review=kb.create_task(self.conn,title='Accepted requested plan',assignee='feature-reviewer',triage=True,workspace_kind='scratch')
        route=kb.create_task(self.conn,title='Groundwater plan delivered',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',triage=True,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='done' WHERE id IN (?,?)",(route,review))
        disposition={'tracker':tracker,'evidence_version':version,'state':'delivered_scope','evidence_task_id':review}
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(43,?,'done','head-coordinator',?,?,'completed',?)",(route,self.now-10,self.now,json.dumps({'feature_delivery':disposition})))
        self.conn.commit()
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Independent planning verdict '+review)
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(44,?,'done','feature-reviewer',?,?,'completed',?)",(review,self.now-20,self.now-15,json.dumps({'verdict':'accept','revision':'exact-plan-sha','checks':[{'command':'sha256sum accepted-plan','exit_code':0}]})));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        kb.edit_task(self.conn,tracker,body='Goal: Now implement a selected new requirement.')
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_feature_and_technical_intake_alternate_after_eligibility_and_survive_restart(self):
        self.hold();technical=monitor.observe(self.root,'testboard',self.now)[0]
        feature=dict(technical,key='testboard:t_feature:feature-delivery-gap',task_id='t_feature',kind='feature-delivery-gap',priority=-10)
        created=[]
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
            created.append(tid);return {'id':tid}
        with patch.object(monitor,'observe',return_value=[technical,feature]):
            self.assertEqual('technical-hold',monitor.tick(self.root,now=self.now,create=create)[0]['issue']['kind'])
            # Ready owner blocks only its own candidate; feature is eligible.
            self.assertEqual('feature-delivery-gap',monitor.tick(self.root,now=self.now+1000,create=create)[0]['issue']['kind'])
            journal=json.loads((self.root/'runtime/deadlock-intake/state.json').read_text())
            self.assertEqual('feature',journal['_fairness']['testboard'])
            self.assertEqual([],monitor.tick(self.root,now=self.now+2000,create=create))
            self.assertEqual(2,len(created))
            # Completing the technical controller leaves that class eligible;
            # feature remains queued and must not consume a turn or duplicate.
            self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(created[0],));self.conn.commit()
            self.assertEqual('technical-hold',monitor.tick(self.root,now=self.now+3000,create=create)[0]['issue']['kind'])

    def test_feature_fairness_is_not_consumed_by_dry_run_or_failed_creation(self):
        self.feature()
        def fail(*args):raise RuntimeError('native create unavailable')
        with self.assertRaises(RuntimeError):monitor.tick(self.root,now=self.now,create=fail)
        self.assertFalse((self.root/'runtime/deadlock-intake/state.json').exists())
        self.assertEqual('feature-delivery-gap',monitor.tick(self.root,dry_run=True,now=self.now)[0]['issue']['kind'])
        self.assertFalse((self.root/'runtime/deadlock-intake/state.json').exists())

    def test_feature_owner_gate_and_actual_legacy_writer_are_preserved(self):
        from feature_flow import observe_features
        tracker=self.feature()
        gate=kb.create_task(self.conn,title='Real owner requirement',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',workspace_kind='scratch')
        kb.block_task(self.conn,gate,kind='needs_input',reason='Input supplier: owner. Physical calibration fact')
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        self.conn.execute("UPDATE tasks SET status='done' WHERE id=?",(gate,));self.conn.commit()
        writer=kb.create_task(self.conn,title='Legacy writer',assignee='standard-implementer',workspace_kind='scratch')
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Actual source owner '+writer)
        self.conn.execute("UPDATE tasks SET status='running',worker_pid=123 WHERE id=?",(writer,));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))

    def test_failed_feature_reconciliation_uses_existing_owner_retry_without_48h_suppression(self):
        tracker=self.feature();created=[]
        def create(board,*args):
            tid=kb.create_task(self.conn,title=args[1],body=args[args.index('--body')+1],assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
            created.append(tid);return {'id':tid}
        action=monitor.tick(self.root,now=self.now,create=create)[0]
        owner=created[0]
        self.conn.execute("UPDATE tasks SET status='blocked' WHERE id=?",(owner,))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome) VALUES(43,?,'crashed','head-coordinator',?,?,'crashed')",(owner,self.now,self.now+900));self.conn.commit()
        retry=monitor.tick(self.root,now=self.now+1000,create=create)[0]
        self.assertEqual(action['issue']['version'],retry['issue']['version'])
        self.assertEqual(owner,retry['issue']['recovery_owner'])
        self.assertIn('Do not execute the original repair here',kb.get_task(self.conn,created[1]).body)

    def test_feature_material_owner_inputs_and_receipts_wake_but_routine_chatter_does_not(self):
        from feature_flow import inspect_feature
        tracker=self.feature();initial=inspect_feature(self.conn,'testboard',tracker)['evidence_version']
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Still waiting; unchanged routing')
        self.assertEqual(initial,inspect_feature(self.conn,'testboard',tracker)['evidence_version'])
        kb.add_comment(self.conn,tracker,author='desktop',body='Use the installed sensor variant and private telemetry first.')
        answered=inspect_feature(self.conn,'testboard',tracker)['evidence_version'];self.assertNotEqual(initial,answered)
        self.conn.execute("INSERT INTO task_attachments(task_id,filename,stored_path,size,uploaded_by,created_at) VALUES(?,'new-receipt.json','/fixture/receipt',17,'head-coordinator',?)",(tracker,self.now));self.conn.commit()
        self.assertNotEqual(answered,inspect_feature(self.conn,'testboard',tracker)['evidence_version'])

    def test_fresh_material_input_reconciles_owner_gate_without_clearing_it(self):
        from feature_flow import observe_features
        tracker=self.feature()
        gate=kb.create_task(self.conn,title='Owner physical input',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',workspace_kind='scratch')
        kb.block_task(self.conn,gate,kind='needs_input',reason='Input supplier: owner. Installed hardware fact')
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        comment=kb.add_comment(self.conn,tracker,author='owner',body='Actual hardware fact supplied.')
        self.conn.execute('UPDATE task_comments SET created_at=? WHERE task_id=? AND author=?',(self.now+10,tracker,'owner'));self.conn.commit()
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now+20)))
        self.assertEqual('needs_input',kb.get_task(self.conn,gate).block_kind)
        self.assertEqual('blocked',kb.get_task(self.conn,gate).status)

    def test_disposition_cannot_use_bare_accept_wrong_profile_or_nonverification_question(self):
        from feature_flow import observe_features,inspect_feature
        tracker=self.feature()
        review=kb.create_task(self.conn,title='Question, not a verification',assignee='feature-reviewer',tenant='review-question',workspace_kind='scratch')
        route=kb.create_task(self.conn,title='Reconciliation',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',workspace_kind='scratch')
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Evidence '+review)
        self.conn.execute("UPDATE tasks SET status='done' WHERE id IN (?,?)",(route,review));self.conn.commit()
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(43,?,'done','head-coordinator',?,?,'completed','{}')",(route,self.now-10,self.now))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(44,?,'done','feature-reviewer',?,?,'completed','{}')",(review,self.now-10,self.now));self.conn.commit()
        for tenant,profile,meta in [('verification','feature-reviewer',{'verdict':'accept'}),('review-question','feature-reviewer',{'verdict':'accept','revision':'sha','checks':[{'command':'check','exit_code':0}]}),('verification','standard-implementer',{'verdict':'accept','revision':'sha','checks':[{'command':'check','exit_code':0}]})]:
            self.conn.execute('UPDATE tasks SET tenant=? WHERE id=?',(tenant,review))
            self.conn.execute('UPDATE task_runs SET profile=?,metadata=? WHERE id=44',(profile,json.dumps(meta)));self.conn.commit()
            current=inspect_feature(self.conn,'testboard',tracker)['evidence_version']
            self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=43',(json.dumps({'feature_delivery':{'tracker':tracker,'evidence_version':current,'state':'delivered_scope','evidence_task_id':review}}),));self.conn.commit()
            self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_assessed_deferral_binds_actual_auditor_scope_and_new_inputs_wake_it(self):
        from feature_flow import inspect_feature,observe_features
        tracker=self.feature()
        auditor=kb.create_task(self.conn,title='Finite mechanism assessment',body='Feature tracker: testboard:'+tracker,assignee='project-auditor',created_by=monitor.CREATOR,workspace_kind='scratch')
        route=kb.create_task(self.conn,title='Feature disposition',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='done' WHERE id IN (?,?)",(auditor,route))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(43,?,'done','project-auditor',?,?,'completed','{}')",(auditor,self.now-10,self.now))
        self.conn.execute("INSERT INTO task_runs(id,task_id,status,profile,started_at,ended_at,outcome,metadata) VALUES(44,?,'done','head-coordinator',?,?,'completed','{}')",(route,self.now-10,self.now));self.conn.commit()
        inspected=inspect_feature(self.conn,'testboard',tracker)
        disposition={'tracker':tracker,'evidence_version':inspected['evidence_version'],'state':'assessed_defer','evidence_task_id':auditor,'wake_condition':'Exact byte-preserving broker proposal supplied'}
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=44',(json.dumps({'feature_delivery':disposition}),));self.conn.commit()
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        assessment={'tracker':tracker,'scope_sha256':inspected['scope_sha256'],'outcome':'defer','missing_inputs':['Broker input contract'],'supplier':'agent','wake_condition':disposition['wake_condition']}
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=43',(json.dumps({'feature_assessment':assessment,'revision':'assessment-sha','checks':[{'command':'bounded-probe','exit_code':0}]}),));self.conn.commit()
        actual=inspect_feature(self.conn,'testboard',tracker)['evidence_version']
        self.assertNotEqual(inspected['evidence_version'],actual)
        disposition['evidence_version']=actual
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=44',(json.dumps({'feature_delivery':disposition}),));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        assessment['missing_inputs']=['New bounded probe result']
        self.conn.execute('UPDATE task_runs SET metadata=? WHERE id=43',(json.dumps({'feature_assessment':assessment}),));self.conn.commit()
        self.assertNotEqual(actual,inspect_feature(self.conn,'testboard',tracker)['evidence_version'])
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))
        kb.add_comment(self.conn,tracker,author='head-coordinator',body='Feature input: the missing broker proposal is now supplied.')
        self.assertEqual(1,len(observe_features(self.conn,'testboard',self.now)))

    def test_public_feature_inspector_returns_current_version_while_reconciliation_active(self):
        from feature_flow import inspect_feature,observe_features
        tracker=self.feature()
        route=kb.create_task(self.conn,title='Active reconciliation',body='Feature tracker: testboard:'+tracker,assignee='head-coordinator',created_by=monitor.CREATOR,workspace_kind='scratch')
        self.conn.execute("UPDATE tasks SET status='running',worker_pid=345 WHERE id=?",(route,));self.conn.commit()
        self.assertEqual([],observe_features(self.conn,'testboard',self.now))
        count=self.conn.execute('SELECT COUNT(*) FROM task_events').fetchone()[0]
        run=subprocess.run([sys.executable,str(source/'feature_flow.py'),'--inspect','testboard:'+tracker],capture_output=True,text=True,check=True)
        self.assertEqual(inspect_feature(self.conn,'testboard',tracker)['evidence_version'],json.loads(run.stdout)['evidence_version'])
        self.assertEqual(count,self.conn.execute('SELECT COUNT(*) FROM task_events').fetchone()[0])
        self.assertEqual('running',kb.get_task(self.conn,route).status)

    def test_recovery_files_only_updates_helpers_and_preserves_all_cron_state(self):
        spec=importlib.util.spec_from_file_location('fixture_recovery_installer',source/'install-deadlock-recovery.py')
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        jobs_file=self.root/'cron/jobs.json';jobs_file.parent.mkdir()
        jobs_file.write_text(json.dumps({'jobs':[
            {'id':'legacy','name':installer.NAME,'enabled':False,'schedule':{'minutes':5}},
            {'id':'supervisor','name':'hermes fleet supervisor','enabled':True,'schedule':{'minutes':5}},
            {'id':'unrelated','enabled':False,'history':['retained']}
        ]},indent=2)+'\n')
        cadence=self.root/'state/fleet/cadence.json';cadence.parent.mkdir(parents=True)
        cadence.write_text('{"technical-recovery":{"interval":300,"last_run":123}}\n')
        before={p:p.read_bytes() for p in (jobs_file,cadence)}
        target=self.root/'scripts/deadlock_recovery.py';target.parent.mkdir()
        target.write_text('# previously installed helper\n')
        with patch.object(installer.subprocess,'run',side_effect=AssertionError('cron must not run')):
            self.assertEqual(1,installer.install(self.root,check=True,files_only=True))
            self.assertEqual('# previously installed helper\n',target.read_text())
            self.assertEqual(0,installer.install(self.root,files_only=True))
            self.assertEqual((source/target.name).read_bytes(),target.read_bytes())
            for name in ('feature_flow.py','review-verdict-guard.py','capability_recovery.py','hermes_common.py','review-taskforce.py'):
                self.assertEqual((source/name).read_bytes(),(target.parent/name).read_bytes())
            self.assertEqual(0,installer.install(self.root,check=True,files_only=True))
            self.assertEqual(0,installer.install(self.root,files_only=True))
        self.assertEqual(before,{p:p.read_bytes() for p in before})
        backups=list((self.root/'backups/deadlock-recovery').rglob('*'))
        self.assertTrue(any(p.is_file() and p.read_text()=='# previously installed helper\n' for p in backups))

    def test_recovery_files_only_does_not_require_or_parse_cron_registry(self):
        spec=importlib.util.spec_from_file_location('fixture_recovery_installer',source/'install-deadlock-recovery.py')
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        jobs_file=self.root/'cron/jobs.json'
        with patch.object(installer.subprocess,'run',side_effect=AssertionError('cron must not run')):
            self.assertEqual(0,installer.install(self.root,files_only=True))
            self.assertFalse(jobs_file.exists())
            jobs_file.parent.mkdir();jobs_file.write_text('unavailable cron registry\n')
            self.assertEqual(0,installer.install(self.root,check=True,files_only=True))
            self.assertEqual('unavailable cron registry\n',jobs_file.read_text())

    def test_recovery_cron_installer_create_edit_resume_readback_and_idempotence(self):
        spec=importlib.util.spec_from_file_location('fixture_recovery_installer',source/'install-deadlock-recovery.py')
        installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(installer)
        jobs_file=self.root/'cron/jobs.json';jobs_file.parent.mkdir();jobs_file.write_text('{"jobs":[]}')
        calls=[]
        def run(argv,**kwargs):
            calls.append(argv)
            jobs=json.loads(jobs_file.read_text())['jobs']
            if 'resume' in argv:
                jobs[0]['enabled']=True
            else:
                record={'id':'abcd1234','name':installer.NAME,'schedule':{'minutes':5},'script':'deadlock_recovery.py','no_agent':True,'workdir':str(source.parent.parent),'deliver':'local','enabled':True}
                jobs[:]=[record]
            jobs_file.write_text(json.dumps({'jobs':jobs}))
        self.assertEqual(1,installer.install(self.root,True));self.assertFalse(calls)
        with patch.object(installer.subprocess,'run',side_effect=run):
            self.assertEqual(0,installer.install(self.root));self.assertEqual(1,len(calls))
            self.assertEqual(0,installer.install(self.root,True));self.assertEqual(0,installer.install(self.root));self.assertEqual(1,len(calls))
            jobs=json.loads(jobs_file.read_text());jobs['jobs'][0]['enabled']=False;jobs['jobs'][0]['schedule']['minutes']=60;jobs_file.write_text(json.dumps(jobs))
            self.assertEqual(0,installer.install(self.root));self.assertEqual(3,len(calls))
        with patch.object(installer.subprocess,'run',return_value=None):
            jobs=json.loads(jobs_file.read_text());jobs['jobs'][0]['schedule']['minutes']=60;jobs_file.write_text(json.dumps(jobs))
            with self.assertRaisesRegex(ValueError,'readback differs'):installer.install(self.root)

class TerminalEpisodeInstallerTest(unittest.TestCase):
    """The installer migrates both amend seams and preserves unrelated bytes."""

    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='coordinator-install-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        for name in ('tools/kanban_tools.py','tools/kanban_tools_schemas.py','hermes_cli/kanban_db.py'):
            target=self.root/'hermes-agent'/name;target.parent.mkdir(parents=True,exist_ok=True)
            target.write_text((native/name).read_text())
        (self.root/'hermes-agent/hermes_cli/nixhomeserver_worker_origin.py').write_text(
            (source/'worker_origin.py').read_text())
        canonical=self.root/'hermes-agent/cron/nixhomeserver_capability_recovery.py'
        canonical.parent.mkdir();canonical.write_text((source/'capability_recovery.py').read_text())
        # Unrelated dirty and untracked bytes, incl. the preserved result links,
        # must survive check, install and readback untouched.
        self.unrelated={'result-1':b'/nix/store/untracked-result-one\n',
                        'result-2':b'/nix/store/untracked-result-two\n',
                        'hermes-agent/tools/unrelated-note.txt':b'unrelated dirty note\n',
                        'kanban/boards/testboard/kanban.db':b'unrelated board bytes\n'}
        for name,content in self.unrelated.items():
            path=self.root/name;path.parent.mkdir(parents=True,exist_ok=True);path.write_bytes(content)
        spec=importlib.util.spec_from_file_location('terminal_episode_installer',source/'install-recovered-resume.py')
        self.installer=importlib.util.module_from_spec(spec);spec.loader.exec_module(self.installer)

    def test_install_migrates_terminal_episode_seam_and_preserves_unrelated_bytes(self):
        self.assertEqual(1,self.installer.install(self.root,True))
        self.assertEqual(0,self.installer.install(self.root))
        self.assertEqual(0,self.installer.install(self.root,True))
        self.assertEqual(0,self.installer.install(self.root))
        for name,content in self.unrelated.items():
            self.assertEqual(content,(self.root/name).read_bytes())
        installed=(self.root/'hermes-agent/tools/kanban_tools.py').read_text()
        self.assertEqual(1,installed.count('def _handle_amend('))
        self.assertEqual(1,installed.count('registry.register(name="kanban_amend"'))
        self.assertIn('terminal_episode=args.get("terminal_episode")',installed)
        schemas=(self.root/'hermes-agent/tools/kanban_tools_schemas.py').read_text()
        self.assertEqual(1,schemas.count('"terminal_episode"'))
        self.assertIn('"terminal_episode"',schemas)
        self.assertEqual((source/'coordinator_repair.py').read_text(),
                         (self.root/'hermes-agent/hermes_cli/nixhomeserver_coordinator_repair.py').read_text())
        self.assertEqual((source/'resume_recovered.py').read_text(),
                         (self.root/'hermes-agent/hermes_cli/nixhomeserver_resume_recovered.py').read_text())

unittest.main(argv=['coordinator-repair'],verbosity=2)
PY
