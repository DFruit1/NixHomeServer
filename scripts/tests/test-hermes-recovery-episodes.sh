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
        self.db.executescript('''CREATE TABLE tasks(id TEXT,status TEXT,created_at INTEGER,worker_pid INTEGER,claim_lock TEXT);
          CREATE TABLE task_runs(id INTEGER,task_id TEXT,status TEXT,outcome TEXT,ended_at INTEGER);
          CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
          INSERT INTO tasks VALUES('t_original','blocked',1,NULL,NULL);
          INSERT INTO task_runs VALUES(1,'t_original','failed','failed',2);''')
        self.db.commit();self.calls=[]
        self.issue=dict(key='test:t_original:failed-lifecycle',version='original-input',
                        task_id='t_original',kind='failed-lifecycle',priority=0)

    def create(self, board, *args):
        self.calls.append(args);tid='t_controller_'+str(len(self.calls))
        self.db.execute('INSERT INTO tasks VALUES(?,?,?,?,?)',(tid,'done',100,None,None));self.db.commit()
        return {'id':tid}

    def tick(self, now, issues=None):
        with patch.object(recovery,'observe',return_value=[self.issue] if issues is None else issues):
            return recovery.tick(self.root,now=now,create=self.create)

    def state(self):
        return json.loads((self.root/'runtime/deadlock-intake/state.json').read_text())

    def failed_controller(self, board, *args):
        card=self.create(board,*args)
        self.db.execute("UPDATE tasks SET status='blocked' WHERE id=?",(card['id'],))
        self.db.execute('INSERT INTO task_runs VALUES(?,?,?,?,?)',
                        (100+len(self.calls),card['id'],'timed_out','timed_out',101))
        self.db.commit()
        return card

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
        self.db.execute("INSERT INTO task_runs VALUES(2,'t_original','done','completed',500)")
        self.db.execute("INSERT INTO task_runs VALUES(3,'t_original','failed','failed',600)")
        self.db.commit()
        action=self.tick(10000,[{**self.issue,'version':'real-recurrence'}])[0]
        self.assertFalse(action['audit'])
        entry=self.state()[self.issue['key']]
        self.assertEqual(3,entry['origin_run_id'])
        self.assertEqual(1,entry['episode_attempts'])
        self.assertNotIn('episode_audit_task_id',entry)
        self.assertEqual(1,len(entry['prior_episodes']))

    def test_selected_incident_keeps_its_own_budget_on_a_multi_issue_board(self):
        self.db.execute("INSERT INTO tasks VALUES('t_other','blocked',1,NULL,NULL)")
        self.db.execute("INSERT INTO task_runs VALUES(2,'t_other','failed','failed',2)")
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
        self.db.execute("INSERT INTO tasks VALUES('t_old_owner','done',1,NULL,NULL)")
        self.db.execute("INSERT INTO tasks VALUES('t_queued_controller','ready',1,NULL,NULL)")
        self.db.commit()
        state['test:t_original:technical-hold']={'owner_task_id':'t_old_owner',
                                               'task_id':'t_queued_controller','versions':{}}
        (self.root/'runtime/deadlock-intake/state.json').write_text(json.dumps(state))
        self.assertEqual([],self.tick(10000))
        self.assertEqual(1,len(self.calls))

    def test_only_actual_original_result_closes_episode_and_recurrence_retains_history(self):
        self.tick(100)
        self.db.execute("INSERT INTO task_runs VALUES(2,'t_original','running',NULL,NULL)");self.db.commit()
        self.assertEqual('awaiting_execution',recovery.execution_progress(self.root,'test','t_original',1)['state'])
        self.db.execute("UPDATE task_runs SET status='done',outcome='completed',ended_at=150 WHERE id=2")
        self.db.execute("INSERT INTO task_runs VALUES(3,'t_original','failed','failed',200)");self.db.commit()
        # Success followed by recurrence between polls must not be lost.
        changed={**self.issue,'version':'new-native-failure'}
        self.tick(500,[changed]);entry=self.state()[self.issue['key']]
        self.assertEqual(3,entry['origin_run_id'])
        self.assertEqual(1,len(entry['prior_episodes']))
        self.assertEqual(1,entry['versions']['original-input']['attempts'])
        self.assertEqual(1,entry['versions']['new-native-failure']['attempts'])


unittest.main(argv=[sys.argv[0]])
PY
