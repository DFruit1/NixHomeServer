#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import json
from pathlib import Path
import sqlite3
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(sys.argv[1]) / 'scripts/hermes'))
import deadlock_recovery as recovery


class EpisodeTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='recovery-episodes-');self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name);self.board=self.root/'kanban/boards/test';self.board.mkdir(parents=True)
        (self.board/'board.json').write_text(json.dumps({'default_workdir':str(self.root)}))
        self.db=sqlite3.connect(self.board/'kanban.db');self.addCleanup(self.db.close)
        self.db.executescript('''CREATE TABLE tasks(id TEXT,status TEXT,created_at INTEGER,worker_pid INTEGER,claim_lock TEXT,
            assignee TEXT DEFAULT 'head-coordinator',tenant TEXT DEFAULT 'technical-recovery',body TEXT DEFAULT '');
          CREATE TABLE task_runs(id INTEGER,task_id TEXT,status TEXT,outcome TEXT,ended_at INTEGER,
            profile TEXT,metadata TEXT);
          CREATE TABLE task_events(id INTEGER,task_id TEXT,kind TEXT,payload TEXT);
          CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
          INSERT INTO tasks(id,status,created_at,worker_pid,claim_lock) VALUES('t_original','blocked',1,NULL,NULL);
          INSERT INTO task_runs(id,task_id,status,outcome,ended_at) VALUES(1,'t_original','failed','failed',2);''')
        self.db.commit();self.calls=[]
        self.issue=dict(key='test:t_original:failed-lifecycle',version='original-input',
                        task_id='t_original',kind='failed-lifecycle',priority=0)

    def create(self, board, *args):
        self.calls.append(args);tid='t_controller_'+str(len(self.calls))
        self.db.execute('INSERT INTO tasks(id,status,created_at,worker_pid,claim_lock) VALUES(?,?,?,?,?)',(tid,'done',100,None,None));self.db.commit()
        return {'id':tid}

    def tick(self, now, issues=None):
        with patch.object(recovery,'observe',return_value=[self.issue] if issues is None else issues):
            return recovery.tick(self.root,now=now,create=self.create)

    def state(self):
        return json.loads((self.root/'runtime/deadlock-intake/state.json').read_text())

    def failed_controller(self, board, *args):
        card=self.create(board,*args)
        self.db.execute("UPDATE tasks SET status='blocked' WHERE id=?",(card['id'],))
        self.db.execute('INSERT INTO task_runs(id,task_id,status,outcome,ended_at) VALUES(?,?,?,?,?)',
                        (100+len(self.calls),card['id'],'timed_out','timed_out',101))
        self.db.commit()
        return card

    def qualification(self, verdict='request-changes'):
        self.tick(100)
        self.db.execute("UPDATE tasks SET status='blocked' WHERE id='t_controller_1'")
        self.db.execute("INSERT INTO tasks(id,status,assignee,tenant,body) VALUES('t_review','done','project-auditor','verification','verdict: unknown')")
        self.db.execute("INSERT INTO task_links VALUES('t_review','t_controller_1')")
        meta=dict(verdict=verdict,revision='proposal-sha',checks=[dict(command='inspect proposal',exit_code=0)],
                  independence=dict(plan_author=False,implementer=False),
                  requested_changes=['Supply qualified allowance'],missing_inputs=['Allowance'])
        self.db.execute("INSERT INTO task_runs VALUES(10,'t_review','done','completed',200,'project-auditor',?)",(json.dumps(meta),))
        self.db.commit()

    def test_changed_fingerprint_preserves_rejected_qualification_hold_and_budget(self):
        self.qualification()
        before=self.state()[self.issue['key']]
        for version in ('attachment', 'helper', 'source-version'):
            self.assertEqual([],self.tick(10000,[{**self.issue,'version':version}]))
        after=self.state()[self.issue['key']]
        self.assertEqual(1,len(self.calls))
        self.assertEqual(before['versions'],after['versions'])
        self.assertEqual(before['episode_attempts'],after['episode_attempts'])
        self.assertEqual('awaiting_execution',after['execution']['state'])
        self.assertEqual('blocked',self.db.execute("SELECT status FROM tasks WHERE id='t_controller_1'").fetchone()[0])

    def test_qualified_accept_allows_supported_recovery_without_claiming_progress(self):
        self.qualification('accept')
        self.assertEqual(1,len(self.tick(10000,[{**self.issue,'version':'accepted-input'}])))
        self.assertEqual('awaiting_execution',self.state()[self.issue['key']]['execution']['state'])

    def test_queued_qualification_is_healthy_wait_without_terminal_result(self):
        self.qualification()
        self.db.execute("DELETE FROM task_runs WHERE task_id='t_review'")
        for status in ('ready', 'todo', 'review'):
            self.db.execute("UPDATE tasks SET status=? WHERE id='t_review'", (status,))
            self.db.commit()
            self.assertEqual([], self.tick(10000, [{**self.issue, 'version':status}]))
        self.assertEqual(1, len(self.calls))

    def test_replacement_acceptance_needs_the_native_gate_edge_transition(self):
        self.qualification()
        self.db.execute("INSERT INTO tasks(id,status,assignee,tenant,body) VALUES('t_fresh','done','project-auditor','verification','')")
        meta=dict(verdict='accept',revision='revised-proposal',checks=[dict(command='inspect revised proposal',exit_code=0)],
                  independence=dict(plan_author=False,implementer=False))
        self.db.execute("INSERT INTO task_runs VALUES(11,'t_fresh','done','completed',300,'project-auditor',?)",(json.dumps(meta),))
        self.db.execute("INSERT INTO task_links VALUES('t_fresh','t_controller_1')")
        self.db.commit()
        self.assertEqual([],self.tick(10000,[{**self.issue,'version':'new-accept'}]))
        # Model the supported guard's completed replacement-edge transition;
        # intake itself must never retire this rejection edge.
        self.db.execute("DELETE FROM task_links WHERE parent_id='t_review'")
        self.db.commit()
        self.assertEqual(1,len(self.tick(10000,[{**self.issue,'version':'qualified-replacement'}])))

    def test_latest_failed_review_attempt_is_visible_unknown_not_old_acceptance(self):
        self.qualification('accept')
        self.db.execute("INSERT INTO task_runs VALUES(11,'t_review','failed','failed',300,'project-auditor','{}')")
        self.db.commit()
        with self.assertRaisesRegex(ValueError,'no current completed verifier'):
            self.tick(10000,[{**self.issue,'version':'retry'}])
        self.assertEqual(1,len(self.calls))

    def test_unknown_and_malformed_qualification_are_not_missing_gates(self):
        self.qualification('unknown')
        self.assertEqual([],self.tick(10000,[{**self.issue,'version':'attachment'}]))
        self.db.execute("UPDATE task_runs SET metadata='[]' WHERE task_id='t_review'")
        self.db.commit()
        with self.assertRaises(ValueError):
            self.tick(20000,[{**self.issue,'version':'helper'}])
        self.assertEqual(1,len(self.calls))

    def test_rejection_does_not_suppress_corrective_implementation(self):
        self.qualification()
        self.db.execute("UPDATE tasks SET assignee='standard-implementer' WHERE id='t_controller_1'")
        self.db.commit()
        self.assertEqual(1,len(self.tick(10000,[{**self.issue,'version':'corrective-input'}])))

    def test_rejected_qualification_preserves_queued_and_active_owners(self):
        self.qualification()
        for status in ('ready','todo','review','running'):
            self.db.execute("UPDATE tasks SET status=? WHERE id='t_controller_1'",(status,))
            self.db.commit()
            self.assertEqual([],self.tick(10000,[{**self.issue,'version':status}]))
        self.assertEqual(1,len(self.calls))

    def test_generic_completed_parent_is_not_a_review_gate(self):
        self.qualification()
        self.db.execute("UPDATE tasks SET assignee='project-auditor',tenant='planning' WHERE id='t_review'")
        self.db.commit()
        self.assertEqual(1,len(self.tick(10000,[{**self.issue,'version':'changed'}])))

    def test_helper_versions_do_not_replenish_failed_owner_episode(self):
        actions=[]
        for n in range(6):
            issue={**self.issue,'version':'helper-version-'+str(n)}
            with patch.object(recovery,'observe',return_value=[issue]):
                actions.extend(recovery.tick(self.root,now=100+n*10000,create=self.failed_controller))
        self.assertEqual([False,False,False,True],[action['audit'] for action in actions])
        entry=self.state()[self.issue['key']]
        self.assertEqual('t_controller_1',entry['owner_task_id'])
        self.assertEqual('t_controller_4',entry['episode_audit_task_id'])
        self.assertEqual(1,entry['origin_run_id'])
        self.assertEqual('awaiting_execution',entry['execution']['state'])

    def test_completed_controller_gets_one_diagnosis_even_when_helpers_change(self):
        self.tick(100)
        self.assertTrue(self.tick(10000,[{**self.issue,'version':'changed-helper'}])[0]['audit'])
        self.assertEqual([],self.tick(20000,[{**self.issue,'version':'another-helper'}]))
        self.assertEqual(2,len(self.calls))

    def test_legacy_versions_escalate_once_without_erasing_attempts_or_active_owner(self):
        with patch.object(recovery,'observe',return_value=[self.issue]):
            recovery.tick(self.root,now=100,create=self.failed_controller)
        state=self.state();entry=state[self.issue['key']]
        entry.pop('episode_attempts',None)  # Installed journals predate this counter.
        entry['versions'].update({'legacy-'+str(n):{'attempts':2,'last_at':100,'task_id':'t_controller_1'}
                                  for n in range(16)})
        saved_versions=dict(entry['versions'])
        (self.root/'runtime/deadlock-intake/state.json').write_text(json.dumps(state))
        self.db.execute("UPDATE tasks SET status='running',worker_pid=123 WHERE id='t_controller_1'")
        self.db.commit()
        issue={**self.issue,'version':'latest-helper'}
        self.assertEqual([],self.tick(10000,[issue]))
        self.db.execute("UPDATE tasks SET status='blocked',worker_pid=NULL WHERE id='t_controller_1'")
        self.db.commit()
        self.assertTrue(self.tick(20000,[issue])[0]['audit'])
        entry=self.state()[self.issue['key']]
        self.assertEqual(saved_versions,{key:entry['versions'][key] for key in saved_versions})
        self.assertEqual([],self.tick(30000,[{**issue,'version':'yet-another-helper'}]))

    def test_successful_original_execution_reopens_an_audited_episode(self):
        self.tick(100);self.tick(401)
        self.db.execute("INSERT INTO task_runs(id,task_id,status,outcome,ended_at) VALUES(2,'t_original','done','completed',500)")
        self.db.execute("INSERT INTO task_runs(id,task_id,status,outcome,ended_at) VALUES(3,'t_original','failed','failed',600)")
        self.db.commit()
        action=self.tick(10000,[{**self.issue,'version':'real-recurrence'}])[0]
        self.assertFalse(action['audit'])
        entry=self.state()[self.issue['key']]
        self.assertEqual(3,entry['origin_run_id'])
        self.assertEqual(1,entry['episode_attempts'])
        self.assertNotIn('episode_audit_task_id',entry)
        self.assertEqual(1,len(entry['prior_episodes']))

    def test_selected_incident_keeps_its_own_budget_on_a_multi_issue_board(self):
        self.db.execute("INSERT INTO tasks(id,status,created_at,worker_pid,claim_lock) VALUES('t_other','blocked',1,NULL,NULL)")
        self.db.execute("INSERT INTO task_runs(id,task_id,status,outcome,ended_at) VALUES(2,'t_other','failed','failed',2)")
        self.db.commit()
        other=dict(self.issue,key='test:t_other:failed-lifecycle',task_id='t_other',priority=0)
        selected=dict(self.issue,priority=10)
        for own_count,other_count in ((3,0),(0,3)):
            with self.subTest(selected=own_count,last_observed=other_count):
                state={selected['key']:{'origin_run_id':1,'episode_attempts':own_count,'versions':{}},
                       other['key']:{'origin_run_id':2,'episode_attempts':other_count,'versions':{}}}
                journal=self.root/'runtime/deadlock-intake';journal.mkdir(parents=True,exist_ok=True)
                (journal/'state.json').write_text(json.dumps(state))
                action=self.tick(10000,[selected,other])[0]
                self.assertEqual(selected['task_id'],action['issue']['task_id'])
                self.assertEqual(own_count>=recovery.MAX_ATTEMPTS,action['audit'])
                state=self.state()
                self.assertEqual(own_count+1,state[selected['key']]['episode_attempts'])
                self.assertEqual(other_count,state[other['key']]['episode_attempts'])

    def test_controller_completion_is_not_recovery_and_unchanged_failure_gets_one_audit(self):
        self.tick(100)
        entry=self.state()[self.issue['key']]
        self.assertEqual('awaiting_execution',entry['execution']['state'])
        self.assertTrue(self.tick(401)[0]['audit'])
        self.assertEqual([],self.tick(1401));self.assertEqual(2,len(self.calls))
        self.assertEqual('awaiting_execution',recovery.execution_progress(self.root,'test','t_original',1)['state'])

    def test_detectors_and_classification_changes_share_owner(self):
        self.tick(100)
        self.assertEqual([],recovery.attach_observations(self.root,'test','board-health',
                                                        ['WORKER_FAILED_BLOCKED t_original']))
        changed={**self.issue,'kind':'technical-hold','key':'test:t_original:technical-hold'}
        self.tick(401,[changed])
        state=self.state();self.assertNotIn(changed['key'],state)
        self.assertEqual(['board-health','technical-recovery'],sorted(state[self.issue['key']]['detectors']))
        self.assertIn('WORKER_FAILED_BLOCKED',state[self.issue['key']]['detector_evidence']['board-health'])
        self.assertEqual(['OWNER_COMMENT_UNACTED t_original'],recovery.attach_observations(
            self.root,'test','board-health',['OWNER_COMMENT_UNACTED t_original']))
        entry=state[self.issue['key']];entry['execution']['state']='recovered'
        (self.root/'runtime/deadlock-intake/state.json').write_text(json.dumps(state))
        self.assertEqual(['WORKER_FAILED_BLOCKED t_original'],recovery.attach_observations(
            self.root,'test','board-health',['WORKER_FAILED_BLOCKED t_original']))

    def test_legacy_classification_keys_select_one_stable_entry(self):
        keys={'test:t_original:technical-hold':{'owner_task_id':'t_a'},
              'test:t_original:failed-lifecycle':{'owner_task_id':'t_b'}}
        first=recovery.incident_key(keys,'test',self.issue)
        self.assertEqual(first,recovery.incident_key(keys,'test',{
            **self.issue,'key':'test:t_original:technical-hold','kind':'technical-hold'}))

    def test_legacy_alias_queued_controller_keeps_ownership_after_old_owner_completes(self):
        self.tick(100);state=self.state()
        self.db.execute("INSERT INTO tasks(id,status,created_at,worker_pid,claim_lock) VALUES('t_old_owner','done',1,NULL,NULL)")
        self.db.execute("INSERT INTO tasks(id,status,created_at,worker_pid,claim_lock) VALUES('t_queued_controller','ready',1,NULL,NULL)")
        self.db.commit()
        state['test:t_original:technical-hold']={'owner_task_id':'t_old_owner',
                                               'task_id':'t_queued_controller','versions':{}}
        (self.root/'runtime/deadlock-intake/state.json').write_text(json.dumps(state))
        self.assertEqual([],self.tick(10000))
        self.assertEqual(1,len(self.calls))

    def test_only_actual_original_result_closes_episode_and_recurrence_retains_history(self):
        self.tick(100)
        self.db.execute("INSERT INTO task_runs(id,task_id,status,outcome,ended_at) VALUES(2,'t_original','running',NULL,NULL)");self.db.commit()
        self.assertEqual('awaiting_execution',recovery.execution_progress(self.root,'test','t_original',1)['state'])
        self.db.execute("UPDATE task_runs SET status='done',outcome='completed',ended_at=150 WHERE id=2")
        self.db.execute("INSERT INTO task_runs(id,task_id,status,outcome,ended_at) VALUES(3,'t_original','failed','failed',200)");self.db.commit()
        # Success followed by recurrence between polls must not be lost.
        changed={**self.issue,'version':'new-native-failure'}
        self.tick(500,[changed]);entry=self.state()[self.issue['key']]
        self.assertEqual(3,entry['origin_run_id'])
        self.assertEqual(1,len(entry['prior_episodes']))
        self.assertEqual(1,entry['versions']['original-input']['attempts'])
        self.assertEqual(1,entry['versions']['new-native-failure']['attempts'])


unittest.main(argv=[sys.argv[0]])
PY
