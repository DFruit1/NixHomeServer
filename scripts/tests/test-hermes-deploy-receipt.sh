#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import base64
import copy
import importlib.util
import json
from pathlib import Path
import shutil
import sqlite3
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PROJECT=Path(sys.argv[1])
spec=importlib.util.spec_from_file_location('receipt',PROJECT/'scripts/hermes/deployment-receipt.py')
receipt=importlib.util.module_from_spec(spec)
spec.loader.exec_module(receipt)


class ReceiptTest(unittest.TestCase):
    def setUp(self):
        self.tmp=tempfile.TemporaryDirectory(prefix='nixhomeserver-hermes-deploy-receipt-')
        self.addCleanup(self.tmp.cleanup)
        self.root=Path(self.tmp.name)
        self.path=self.root/'kanban/boards/one/kanban.db'
        self.path.parent.mkdir(parents=True)
        self.db=sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.executescript('''CREATE TABLE tasks(id TEXT,status TEXT,assignee TEXT,tenant TEXT);
            CREATE TABLE task_runs(id INTEGER,task_id TEXT,profile TEXT,status TEXT,outcome TEXT,metadata TEXT);
            CREATE TABLE task_comments(id INTEGER,task_id TEXT,author TEXT,body TEXT);
            CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
            INSERT INTO tasks VALUES ('t_review','done','feature-reviewer','verification'),
              ('t_decision','running','head-coordinator',NULL);
            INSERT INTO task_links VALUES ('t_review','t_decision');''')
        self.scope={'schema_version':1,'kind':'nixos-whole-set','base_revision':'a'*40,
            'head_revision':'b'*40,'baseline_evidence':'prior deployment record',
            'source_hash':'sha256-'+base64.b64encode(bytes(32)).decode(),
            'hostname':'server','target':'operator@server','actions':['test','switch'],'inputs':{}}
        self.metadata={'verdict':'accept','revision':'b'*40,
            'checks':[{'command':'test-owned-slice','exit_code':0}], 'deployment_scope':self.scope}
        self.db.execute('INSERT INTO task_runs VALUES (7,?,?,?,?,?)',
            ('t_review','feature-reviewer','done','completed',json.dumps(self.metadata)))
        self.decision={'schema_version':1,'approved':True,'review_task':'t_review',
                       'review_run_id':7,'scope':copy.deepcopy(self.scope)}
        self.comment(self.decision)
        self.stamp=self.root/'tested.stamp'
        self.stamp.write_text('version=2\nsource_hash='+self.scope['source_hash']+
            '\ntoplevel=/nix/store/'+'0'*32+'-nixos-system-server\ndebug_validated=false\n')

    def comment(self, decision, author='head-coordinator'):
        i=self.db.execute('SELECT coalesce(max(id),0)+1 FROM task_comments').fetchone()[0]
        self.db.execute('INSERT INTO task_comments VALUES (?,?,?,?)',
                        (i,'t_decision',author,json.dumps({'deployment_decision':decision})))
        self.db.commit()

    def check(self, action='test', scope=None):
        self.db.commit()
        before=self.path.read_bytes()
        with patch.object(receipt,'capture_scope',return_value=copy.deepcopy(scope or self.scope)):
            result=receipt.check(self.root,'one','t_review','t_decision',PROJECT,action,{},self.stamp,
                                 hostname='server',target='operator@server')
        self.assertEqual(before,self.path.read_bytes())
        return result

    def test_accepted_scope_and_existing_stamp_are_machine_bound(self):
        self.assertEqual('reviewed',self.check()['stage'])
        result=self.check('switch')
        self.assertEqual('reviewed_and_tested',result['stage'])
        self.assertEqual(7,result['review_run_id'])
        self.assertIn('toplevel',result['tested'])

    def test_newer_failed_or_running_review_cannot_resurrect_old_acceptance(self):
        for status in ('running','failed','crashed'):
            self.db.execute('DELETE FROM task_runs WHERE id=8')
            self.db.execute('INSERT INTO task_runs VALUES (8,?,?,?,?,?)',
                ('t_review','feature-reviewer',status,None,'{}'))
            with self.assertRaises(ValueError): self.check()

    def test_recorded_run_profile_and_latest_decision_authorship_matter(self):
        self.db.execute("UPDATE task_runs SET profile='head-coordinator'")
        with self.assertRaises(ValueError): self.check()
        self.db.execute("UPDATE task_runs SET profile='feature-reviewer'")
        self.comment(self.decision,author='standard-implementer')
        with self.assertRaises(ValueError): self.check()

    def test_later_rejection_or_owner_comment_supersedes_approval(self):
        self.comment({**self.decision,'approved':False})
        with self.assertRaises(ValueError): self.check()
        self.comment(self.decision)
        self.db.execute("INSERT INTO task_comments VALUES (100,'t_decision','desktop','Stop; scope changed')")
        with self.assertRaises(ValueError): self.check()

    def test_changed_source_target_action_or_input_manifest_fails(self):
        for key,value in [('head_revision','c'*40),('target','operator@elsewhere'),
                          ('inputs',{'omitted':'f'*64}),('actions',['test'])]:
            with self.subTest(key=key):
                changed={**self.scope,key:value}
                with self.assertRaises(ValueError): self.check('switch',changed)
        with self.assertRaises(ValueError):
            receipt.check(self.root,'one','t_review','t_decision',PROJECT,'test',{},
                          hostname='server',target='operator@elsewhere')

    def test_rejection_bad_checks_missing_links_or_open_prerequisites_fail(self):
        for metadata in ({**self.metadata,'verdict':'request-changes','requested_changes':['fix']},
                         {**self.metadata,'checks':[{'command':'test','exit_code':1}]}):
            self.db.execute('UPDATE task_runs SET metadata=?',(json.dumps(metadata),))
            with self.assertRaises(ValueError): self.check()
        self.db.execute('UPDATE task_runs SET metadata=?',(json.dumps(self.metadata),))
        self.db.execute('DELETE FROM task_links')
        with self.assertRaises(ValueError): self.check()
        self.db.execute("INSERT INTO task_links VALUES ('t_review','t_decision')")
        self.db.execute("INSERT INTO task_links VALUES ('missing','t_decision')")
        with self.assertRaises(ValueError): self.check()

    def test_wrong_source_legacy_or_duplicate_stamp_fields_fail(self):
        original=self.stamp.read_text()
        for text in (original.replace('version=2','version=1'),original+'version=2\n',
                     original.replace(self.scope['source_hash'],'sha256-other')):
            self.stamp.write_text(text)
            with self.assertRaises(ValueError): self.check('switch')

    def test_mutable_inputs_reject_secret_targets_and_special_files(self):
        secret=self.root/'secrets/unencrypted/password'
        secret.parent.mkdir(parents=True); secret.write_text('do not read')
        alias=self.root/'innocent'; alias.symlink_to(secret)
        with self.assertRaises(ValueError): receipt.input_hashes({'input':alias})
        with self.assertRaises(ValueError): receipt.input_hashes({'input':self.root})
        normal=self.root/'metadata.json'; normal.write_text('{}')
        self.assertEqual(64,len(receipt.input_hashes({'input':normal})['input']))

    def test_input_stability_uses_nanoseconds_without_rejecting_access_time(self):
        normal=self.root/'metadata.json'; normal.write_text('{}')
        before=normal.stat()
        fields={name:getattr(before,name) for name in
                ('st_dev','st_ino','st_mode','st_size','st_mtime_ns','st_ctime_ns')}
        access_changed=SimpleNamespace(**fields,st_atime=before.st_atime+1)
        with patch.object(receipt.os,'fstat',side_effect=[before,access_changed]):
            self.assertEqual(64,len(receipt.input_hashes({'input':normal})['input']))
        changed=SimpleNamespace(**{**fields,'st_mtime_ns':before.st_mtime_ns+1})
        with patch.object(receipt.os,'fstat',side_effect=[before,changed]), self.assertRaises(ValueError):
            receipt.input_hashes({'input':normal})

    def test_scope_and_decision_json_reject_ambiguity(self):
        with self.assertRaises(ValueError): receipt.strict_json('{"approved":true,"approved":false}')
        with self.assertRaises(ValueError): receipt.strict_json('{"counter":NaN}')
        with self.assertRaises(ValueError): receipt.validate_scope({**self.scope,'unknown':True})
        with self.assertRaises(ValueError): receipt.validate_scope({**self.scope,'schema_version':True})
        with self.assertRaises(ValueError):
            receipt.check(self.root,'../escape','t_review','t_decision',PROJECT,'test',{},
                          hostname='server',target='operator@server')

    def test_escaped_rejection_key_cannot_resurrect_approval(self):
        body=json.dumps({'deployment_decision':{**self.decision,'approved':False}})
        body=body.replace('deployment_decision',r'\u0064eployment_decision')
        self.db.execute("INSERT INTO task_comments VALUES (100,'t_decision','head-coordinator',?)",(body,))
        with self.assertRaises(ValueError): self.check()

    def test_board_change_during_capture_invalidates_receipt(self):
        def capture(*args):
            self.comment({**self.decision,'approved':False})
            return self.scope
        with patch.object(receipt,'capture_scope',side_effect=capture), self.assertRaises(ValueError):
            receipt.check(self.root,'one','t_review','t_decision',PROJECT,'test',{},
                          hostname='server',target='operator@server')

    def test_absent_board_is_not_created(self):
        with self.assertRaises(sqlite3.Error):
            receipt.evidence(self.root,'missing','t_review','t_decision')
        self.assertFalse((self.root/'kanban/boards/missing/kanban.db').exists())

    def test_installed_script_uses_checkout_helpers(self):
        with patch.object(receipt,'SOURCE',self.root/'installed/scripts'):
            self.assertEqual(self.scope['source_hash'],receipt.tested_stamp(self.stamp,PROJECT)['source_hash'])

    def test_capture_hashes_canonical_extracted_archive_and_rejects_dirty_checkout(self):
        checkout=self.root/'checkout'; checkout.mkdir()
        helpers=checkout/'scripts/helpers'; helpers.mkdir(parents=True)
        for name in ('repo-common.sh','deploy-archive-cleanup.sh'):
            shutil.copyfile(PROJECT/'scripts/helpers'/name,helpers/name)
        (checkout/'tracked').write_text('reviewed content')
        (checkout/'.gitignore').write_text('ignored\n')
        (checkout/'ignored').write_text('local cache')
        git=lambda *args:receipt.command(['git','-C',str(checkout),*args])
        git('init','--quiet'); git('add','scripts/helpers','tracked','.gitignore')
        git('-c','user.name=Receipt test','-c','user.email=receipt@example.invalid','commit','--quiet','-m','Fixture')
        revision=git('rev-parse','HEAD')
        original=receipt.command
        def run(argv,**kwargs):
            if argv[:3]==['nix','hash','path']:
                tree=Path(argv[3])
                self.assertEqual('reviewed content',(tree/'tracked').read_text())
                self.assertFalse((tree/'.git').exists()); self.assertFalse((tree/'ignored').exists())
                return self.scope['source_hash']
            return original(argv,**kwargs)
        with patch.object(receipt,'SOURCE',self.root/'installed/scripts'), patch.object(receipt,'command',side_effect=run):
            snapshot=receipt.capture_scope(checkout,revision,'fixture','server','operator@server',['test'],{})
        self.assertEqual(revision,snapshot['head_revision'])
        git('update-index','--assume-unchanged','tracked')
        with self.assertRaises(ValueError):
            receipt.capture_scope(checkout,revision,'fixture','server','operator@server',['test'],{})
        git('update-index','--no-assume-unchanged','tracked')
        git('update-index','--skip-worktree','tracked')
        with self.assertRaises(ValueError):
            receipt.capture_scope(checkout,revision,'fixture','server','operator@server',['test'],{})
        git('update-index','--no-skip-worktree','tracked')
        (checkout/'tracked').write_text('unreviewed content')
        with self.assertRaises(ValueError):
            receipt.capture_scope(checkout,revision,'fixture','server','operator@server',['test'],{})


unittest.main(argv=['receipt'],verbosity=2)
PY
