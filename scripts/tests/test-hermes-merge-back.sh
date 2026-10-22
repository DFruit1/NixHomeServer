#!/usr/bin/env bash
# Regression test for scripts/hermes/worktree-merge-back.py.
#
# Why this needs pinning
# ----------------------
# The helper is the coordinator's merge-back instrument and it runs git state
# transitions unattended-from-a-card. Its dangerous edges are pinned here:
# a merge that silently succeeded without content, a merge of rejected or
# unreviewed work, an auto-resolved conflict, a broken master after a failed
# validation, a disposition that suppresses a finding without being on record,
# and a push the helper was never authorized to make.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$TESTS_REPO_ROOT/scripts/hermes/worktree-merge-back.py"

fail() { echo "❌ $1" >&2; exit 1; }
pass() { echo "  ✅ $1"; }

[[ -f "$HELPER" ]] || fail "worktree-merge-back.py is missing"

fixture="$(mktemp -d /tmp/hermes-merge-back.XXXXXX)"
trap 'rm -rf "$fixture"' EXIT

root="$fixture/hermes"
board_dir="$root/kanban/boards/testboard"
mkdir -p "$board_dir" "$root/scripts"
repo="$fixture/project"

# Board with the full tasks schema the helper reads.
sqlite3 "$board_dir/kanban.db" <<'SQL'
CREATE TABLE tasks (
  id TEXT PRIMARY KEY, title TEXT, assignee TEXT, status TEXT,
  created_at INTEGER, started_at INTEGER, workspace_path TEXT,
  branch_name TEXT, completed_at INTEGER, project_id TEXT,
  claim_lock TEXT, block_kind TEXT, block_recurrences INTEGER DEFAULT 0,
  consecutive_failures INTEGER DEFAULT 0
);
CREATE TABLE task_comments (id INTEGER PRIMARY KEY, task_id TEXT, body TEXT, author TEXT);
CREATE TABLE task_events (id INTEGER PRIMARY KEY, task_id TEXT, kind TEXT, payload TEXT);
CREATE TABLE task_links (parent_id TEXT, child_id TEXT);
CREATE TABLE task_runs (id INTEGER PRIMARY KEY, task_id TEXT, profile TEXT, status TEXT, outcome TEXT, metadata TEXT);
SQL
printf '{"slug": "testboard", "default_workdir": "%s"}\n' "$repo" >"$board_dir/board.json"

# The project checkout the board works in. Has no validate-repo.sh of its own,
# so the validation leg reports 'skipped' in receipts.
mkdir -p "$repo"
git -C "$repo" init --quiet --initial-branch master 2>/dev/null || git -C "$repo" init --quiet
printf 'base\n' >"$repo/base.txt"; git -C "$repo" add base.txt
git -C "$repo" commit -m base --quiet
git -C "$repo" config user.email test@fixture
git -C "$repo" config user.name test

# A stub CLI that records comments exactly like the native kanban tool would,
# without involving a live board engine: the helper's disposition write path
# is the thing under test, and the recorded row must carry head-coordinator.
mkdir -p "$fixture/bin"
cat >"$fixture/bin/hermes" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
# helper invokes: hermes kanban --board <slug> comment <task> <message>
[[ "${1:-}" == kanban && "${2:-}" == --board && "${4:-}" == comment ]] || exit 64
db="$HERMES_KANBAN_HOME/kanban/boards/$3/kanban.db"
task="$5" msg="$6"
sqlite3 "$db" "INSERT INTO task_comments (task_id, body, author)
  SELECT '$task', '$msg', 'head-coordinator';"
echo "commented $task"
EOF
chmod +x "$fixture/bin/hermes"

mb() { HERMES_ROOT="$root" HERMES_BOARD=testboard HERMES_BIN="$fixture/bin/hermes" \
  python3 -B "$HELPER" "$@"; }

card() {
  local id="$1" title="$2" branch="$3" status="${4:-done}"
  sqlite3 "$board_dir/kanban.db" "INSERT INTO tasks
    (id,title,assignee,status,completed_at,branch_name) VALUES
    ('$id','$title','standard-implementer','$status',$(date +%s),'$branch');"
  review "$id" "$branch"
}

review() {
  python3 -B - "$board_dir/kanban.db" "$repo" "$1" "$2" <<'PYREVIEW'
import json, sqlite3, subprocess, sys
path, repo, task, branch = sys.argv[1:]
revision = subprocess.check_output(['git','-C',repo,'rev-parse',branch],text=True).strip()
with sqlite3.connect(path) as db:
    db.execute('INSERT OR IGNORE INTO tasks(id,status,assignee) VALUES (?, ?, ?)',
               (task+'_review','done','feature-reviewer'))
    db.execute('INSERT INTO task_links VALUES (?,?)', (task,task+'_review'))
    db.execute('INSERT INTO task_runs(task_id,profile,status,outcome,metadata) VALUES (?, ?, ?, ?, ?)',
               (task+'_review','feature-reviewer','done','completed',json.dumps({
                 'verdict':'accept','revision':revision,
                 'checks':[{'command':'fixture review','exit_code':0}]})))
PYREVIEW
}

make_branch() { # id, one commit per printf-pair
  local id="$1"; shift
  git -C "$repo" checkout --quiet -b "wt/$id"
  local p
  for p in "$@"; do printf '%s\n' "$p" >"$repo/$id.txt"; git -C "$repo" add "$id.txt"; git -C "$repo" commit -m "$id $p" --quiet; done
  git -C "$repo" checkout --quiet master
}

echo "▶ worktree merge-back helper"

# --- list, plan, merge, idempotence ------------------------------------------

make_branch t_ok one two
card t_ok "accepted work" wt/t_ok

out=$(mb --list)
grep -q '^UNMERGED_ACCEPTED_WORK t_ok branch=wt/t_ok commits=2 card=done$' <<<"$out" ||
  fail "did not list the accepted unmerged branch: $out"
pass "lists the accepted unmerged branch"

out=$(mb --plan wt/t_ok)
grep -q '"status": "clean-plan"' <<<"$out" || fail "plan did not classify a clean branch: $out"
grep -q '"commits_unapplied": 2' <<<"$out" || fail "plan lost the commit census: $out"
pass "plans a clean branch with its commit census"

sqlite3 "$board_dir/kanban.db" "UPDATE task_runs SET metadata='{}' WHERE task_id='t_ok_review';"
out=$(mb --merge wt/t_ok 2>&1) && code=0 || code=$?
[[ "$code" == 2 ]] || fail "done status alone authorized an unreviewed merge: $out"
pass "done status alone never authorizes a merge"
review t_ok wt/t_ok

out=$(mb --merge wt/t_ok) || fail "clean merge exited nonzero: $out"
git -C "$repo" merge-base --is-ancestor wt/t_ok master || fail "the branch commits did not reach master"
git -C "$repo" show --format='%P' -s master | grep -q ' ' ||
  fail "the merge was not a non-ff merge commit"
out=$(mb --merge wt/t_ok)
grep -q '"status": "already_integrated"' <<<"$out" || fail "a second merge re-merged: $out"
pass "merges once, then reports already integrated"

# The next list is quiet for the branched card.
[[ -z "$(mb --list)" ]] || fail "list still reported the merged branch"
pass "list goes quiet once merged"

# --- refusals -----------------------------------------------------------------

git -C "$repo" checkout --quiet -b feature 2>/dev/null || true
make_branch t_d detached-but-done
card t_d "done card, detached checkout" wt/t_d "done"
git -C "$repo" checkout --quiet master 2>/dev/null
git -C "$repo" checkout --detach --quiet
out=$(mb --merge wt/t_d 2>&1 || true)
grep -q 'MERGE_BACK_REFUSED NOT_ON_MASTER' <<<"$out" || fail "no clear refusal off master: $out"
git -C "$repo" checkout --quiet master || git -C "$repo" checkout --quiet -f master
pass "refuses to merge when the checkout is not on master"

make_branch t_open fastwait
card t_open "open card" wt/t_open open
open_receipt=$(mb --merge wt/t_open 2>&1 || true)
grep -q 'MERGE_BACK_REFUSED NO_ACCEPTED_CARD' <<<"$open_receipt" || fail "an open card merge was not refused: $open_receipt"
pass "refuses to merge a card that is not done or archived"

printf 'dirt\n' >"$repo/dirt.txt"
out=$(mb --merge wt/t_d 2>&1 || true)
grep -q 'MERGE_BACK_REFUSED UNCLEAN_WORKTREE' <<<"$out" || fail "dirty repository was silent: $out"
rm -f "$repo/dirt.txt"
pass "refuses to merge a dirty worktree"

# --- conflict evidence, never auto-resolution --------------------------------

make_branch t_conf payload
card t_conf "conflicting accepted fix" wt/t_conf
printf 'master-side\n' >"$repo/t_conf.txt"
git -C "$repo" add t_conf.txt; git -C "$repo" commit -m 'master side of t_conf' --quiet

# fastwait fix: no wait, t_conf's branch must conflict on the same path:
git -C "$repo" checkout --quiet wt/t_conf
printf 'branch-side\n' >"$repo/t_conf.txt"
git -C "$repo" add t_conf.txt; git -C "$repo" commit -m 'branch side of t_conf' --quiet
git -C "$repo" checkout --quiet master

review t_conf wt/t_conf
out=$(mb --merge wt/t_conf) && code=0 || code=$?
[[ "$code" == 3 ]] || fail "conflict merge exited $code: $out"
grep -q '"status": "conflict"' <<<"$out" || fail "conflict receipt missing: $out"
grep -q 't_conf.txt' <<<"$out" || fail "conflict receipt names no file: $out"
[[ -z "$(git -C "$repo" status --porcelain)" ]] || fail "a conflicted merge left the worktree dirty"
git -C "$repo" merge-base --is-ancestor wt/t_conf master && fail "a conflicted branch reached master anyway"
pass "reports conflicts with files and leaves master untouched"

out=$(mb --plan wt/t_conf)
grep -q '"status": "conflict-plan"' <<<"$out" || fail "plan missed the conflict: $out"
pass "plans a conflict with file evidence"

# --- disposition via the native comment path ---------------------------------

out=$(mb --dispose wt/t_conf --reason 'superseded by the composition route; keep worktree evidence only')
grep -q '"status": "disposed"' <<<"$out" || fail "dispose refused: $out"
sqlite3 "$board_dir/kanban.db" "SELECT body FROM task_comments WHERE author='head-coordinator';" |
  grep -q '^merge-back disposition: superseded by the composition route; keep worktree evidence only' ||
  fail "the disposition comment is not on record"
list_after="$(mb --list)"
grep -q 't_conf' <<<"$list_after" && fail "list still reports the dispositioned branch: $list_after"
pass "records a disposition and silences the finding"

# Missing reason is refused rather than recorded blank.
if mb --dispose wt/t_ok >/dev/null 2>&1; then fail "dispose without reason was accepted"; fi
pass "refuses a disposition without a reason"

# --- no push, no remote touching ---------------------------------------------

[[ -z "$(git -C "$repo" remote)" ]] || fail "the helper created a remote"
pass "never touches remote state"

echo "▶ merge acceptance and queue regressions"

python3 -B - "$HELPER" "$fixture" <<'PY'
from contextlib import closing, redirect_stdout
import importlib.util
import io
import json
from pathlib import Path
import sqlite3
import subprocess
import sys
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('merge_back', sys.argv[1])
mb = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mb)
SCRATCH = Path(sys.argv[2])

class AuthorityTest(unittest.TestCase):
    def setUp(self):
        self.root = SCRATCH / self._testMethodName
        self.repo = self.root / 'repo'
        self.repo.mkdir(parents=True)
        self.path = self.root / 'kanban/boards/nixhomeserver/kanban.db'
        self.path.parent.mkdir(parents=True)
        self.db = sqlite3.connect(self.path)
        self.addCleanup(self.db.close)
        self.db.executescript('''CREATE TABLE tasks(id TEXT,title TEXT,status TEXT,assignee TEXT,branch_name TEXT);
            CREATE TABLE task_runs(id INTEGER PRIMARY KEY,task_id TEXT,profile TEXT,status TEXT,outcome TEXT,metadata TEXT);
            CREATE TABLE task_links(parent_id TEXT,child_id TEXT);
            CREATE TABLE task_comments(id INTEGER,task_id TEXT,author TEXT,body TEXT);
            CREATE TABLE task_events(id INTEGER PRIMARY KEY,task_id TEXT,kind TEXT,payload TEXT);''')
        self.git('init', '--quiet', '--initial-branch=master')
        self.git('config','user.name','fixture')
        self.git('config','user.email','fixture@example.invalid')
        (self.repo / 'base').write_text('base')
        self.git('add','base'); self.git('commit','-qm','base')
        self.sha = self.branch('one')

    def git(self,*args):
        return subprocess.check_output(['git','-C',str(self.repo),*args],text=True).strip()

    def branch(self,name):
        self.git('checkout','-qb','wt/'+name)
        (self.repo / name).write_text(name)
        self.git('add',name); self.git('commit','-qm',name)
        sha = self.git('rev-parse','HEAD')
        self.git('checkout','-q','master')
        self.db.execute('INSERT INTO tasks VALUES (?,?,?,?,?)',('t_'+name,name,'done','standard-implementer','wt/'+name))
        self.db.execute('INSERT INTO tasks VALUES (?,?,?,?,NULL)',('t_'+name+'_review','review','done','feature-reviewer'))
        self.db.execute('INSERT INTO task_links VALUES (?,?)',('t_'+name,'t_'+name+'_review'))
        self.run_review(name, sha)
        return sha

    def run_review(self,name,sha,**extra):
        metadata = {'verdict':'accept','revision':sha,'checks':[{'command':'fixture test','exit_code':0}],**extra}
        self.db.execute('INSERT INTO task_runs(task_id,profile,status,outcome,metadata) VALUES (?, ?, ?, ?, ?)',
            ('t_'+name+'_review','feature-reviewer','done','completed',json.dumps(metadata)))
        self.db.commit()

    def merge(self):
        self.db.commit()
        return mb.merge_step(self.root,self.repo,'wt/one')

    def test_plan_can_inspect_open_review_without_authorizing_effects(self):
        self.db.execute("UPDATE tasks SET status='review' WHERE id='t_one'")
        self.db.execute("UPDATE tasks SET status='running' WHERE id='t_one_review'")
        self.db.execute('DELETE FROM task_runs')
        self.db.commit()
        before_db = self.path.read_bytes()
        before_head = self.git('rev-parse','HEAD')
        plan = io.StringIO()
        with redirect_stdout(plan):
            self.assertEqual(0,mb.plan_backlog(self.root,self.repo,'wt/one'))
        receipt = json.loads(plan.getvalue().removeprefix('RECEIPT '))
        self.assertEqual(('clean-plan','review','t_one'),
                         (receipt['status'],receipt['card_status'],receipt['task_id']))
        self.assertEqual(before_db,self.path.read_bytes())
        self.assertEqual(before_head,self.git('rev-parse','HEAD'))
        self.assertEqual('',self.git('status','--porcelain'))
        with self.assertRaisesRegex(mb.Refused,'NO_ACCEPTED_CARD'):
            self.merge()
        with self.assertRaisesRegex(mb.Refused,'NO_ACCEPTED_CARD'):
            mb.merge_queue(self.root,self.repo,[('wt/one',self.sha)],1)
        with patch.object(mb,'resolve_repo',return_value=self.repo):
            with self.assertRaisesRegex(mb.Refused,'NO_ACCEPTED_CARD'):
                mb.dispose(self.root,'nixhomeserver','wt/one','not yet accepted')

    def test_plan_refuses_ambiguous_ownership_even_when_one_owner_is_open(self):
        self.db.execute('INSERT INTO tasks VALUES (?,?,?,?,?)',
                        ('t_duplicate','same branch','running','standard-implementer','wt/one'))
        self.db.commit()
        with self.assertRaisesRegex(mb.Refused,'AMBIGUOUS_CARD_OWNER'):
            mb.plan_backlog(self.root,self.repo,'wt/one')
        with self.assertRaisesRegex(mb.Refused,'AMBIGUOUS_CARD_OWNER'):
            self.merge()

    def test_rejects_missing_rejected_stale_or_failing_checks(self):
        for extra in ({'verdict':'request-changes'}, {'revision':'0'*40}, {'checks':[]},
                      {'checks':[{'command':'fixture','exit_code':False}]},
                      {'checks':[{'command':'fixture','exit_code':1}]}):
            with self.subTest(extra=extra):
                self.run_review('one',self.sha,**extra)
                with self.assertRaises(mb.Refused): self.merge()
        self.assertEqual('base',self.git('log','-1','--format=%s'))

    def test_rejects_latest_failed_run_or_self_review_or_unlinked_review(self):
        for statement in ("UPDATE task_runs SET status='failed'",
                          "UPDATE tasks SET assignee='feature-reviewer' WHERE id='t_one'",
                          "DELETE FROM task_links"):
            self.db.execute('SAVEPOINT invalid')
            self.db.execute(statement)
            self.db.commit()
            with self.assertRaises(mb.Refused): self.merge()
            if 'DELETE' in statement:
                self.db.execute("INSERT INTO task_links VALUES ('t_one','t_one_review')")
            else:
                self.db.execute("UPDATE task_runs SET status='done'")
                self.db.execute("UPDATE tasks SET assignee='standard-implementer' WHERE id='t_one'")

    def test_native_same_card_review_and_auditor_are_supported(self):
        self.db.execute('DELETE FROM task_links')
        metadata = json.loads(self.db.execute('SELECT metadata FROM task_runs').fetchone()[0])
        metadata['independence'] = {'plan_author':False,'implementer':False}
        self.db.execute("UPDATE task_runs SET task_id='t_one',profile='project-auditor',metadata=?",
                        (json.dumps(metadata),))
        self.db.execute("UPDATE tasks SET assignee='project-auditor' WHERE id='t_one'")
        self.db.execute("INSERT INTO task_events(task_id,kind,payload) VALUES ('t_one','review_requested',?)",
            (json.dumps({'implementer':'standard-implementer','reviewer':'project-auditor'}),))
        code, receipt = self.merge()
        self.assertEqual(0,code)
        self.assertEqual('merged',receipt['status'])

    def test_newer_rejection_on_another_linked_review_blocks_old_accept(self):
        self.db.execute("INSERT INTO tasks VALUES ('t_other','review','done','project-auditor',NULL)")
        self.db.execute("INSERT INTO task_links VALUES ('t_one','t_other')")
        self.db.execute("INSERT INTO task_runs(task_id,profile,status,outcome,metadata) VALUES ('t_other','project-auditor','done','completed',?)",
            (json.dumps({'verdict':'request-changes','revision':self.sha,'checks':[{'command':'test','exit_code':0}]}),))
        with self.assertRaises(mb.Refused): self.merge()

    def test_queue_is_pinned_bounded_and_stops_on_failed_validation(self):
        two = self.branch('two'); three = self.branch('three')
        pins = [('wt/one',self.sha),('wt/two',two),('wt/three',three)]
        with patch.object(mb,'validate_step',side_effect=['pass','fail']):
            code, receipt = mb.merge_queue(self.root,self.repo,pins,3)
        self.assertEqual(3,code)
        self.assertEqual(2,len(receipt['results']))
        self.assertEqual('reverted',receipt['results'][1]['status'])
        self.assertFalse((self.repo/'two').exists())
        self.assertFalse((self.repo/'three').exists())
        self.assertTrue((self.repo/'one').exists())
        self.assertEqual('',self.git('status','--porcelain'))

    def test_queue_refuses_changed_tip_and_duplicate_or_excess_candidates(self):
        for pins, limit in ([('wt/one','0'*40)],1), ([('wt/one',self.sha)]*2,2), ([('wt/one',self.sha)],0):
            with self.subTest(pins=pins,limit=limit), self.assertRaises(mb.Refused):
                mb.merge_queue(self.root,self.repo,pins,limit)
        self.assertEqual('base',self.git('log','-1','--format=%s'))

    def test_queue_rechecks_tip_and_master_between_candidates(self):
        two = self.branch('two')
        def mutate(_repo):
            self.git('update-ref','refs/heads/wt/two',self.sha)
            return 'pass'
        with patch.object(mb,'validate_step',side_effect=mutate):
            code, receipt = mb.merge_queue(self.root,self.repo,[('wt/one',self.sha),('wt/two',two)],2)
        self.assertEqual(2,code)
        self.assertEqual(1,len(receipt['results']))
        self.assertFalse((self.repo/'two').exists())

    def test_auditor_requires_explicit_independence(self):
        self.db.execute("UPDATE tasks SET assignee='project-auditor' WHERE id='t_one_review'")
        self.db.execute("UPDATE task_runs SET profile='project-auditor'")
        with self.assertRaises(mb.Refused): self.merge()
        metadata = json.loads(self.db.execute('SELECT metadata FROM task_runs').fetchone()[0])
        for independence in ({'plan_author':True,'implementer':False},
                             {'plan_author':False,'implementer':0}):
            metadata['independence'] = independence
            self.db.execute('UPDATE task_runs SET metadata=?',(json.dumps(metadata),))
            with self.assertRaises(mb.Refused): self.merge()

    def test_queue_completes_all_pins_and_stops_on_conflicts(self):
        two = self.branch('two')
        code, result = mb.merge_queue(self.root,self.repo,[('wt/one',self.sha),('wt/two',two)],2)
        self.assertEqual((0,'queue_complete'),(code,result['status']))
        self.assertTrue((self.repo/'one').exists())
        self.assertTrue((self.repo/'two').exists())
        three = self.branch('three'); four = self.branch('four')
        (self.repo/'three').write_text('conflicting master writer')
        self.git('add','three'); self.git('commit','-qm','master conflict')
        before = self.git('rev-parse','HEAD')
        code, result = mb.merge_queue(self.root,self.repo,[('wt/three',three),('wt/four',four)],2)
        self.assertEqual((3,'conflict'),(code,result['results'][0]['status']))
        self.assertEqual(before,self.git('rev-parse','HEAD'))
        self.assertFalse((self.repo/'four').exists())
        self.assertEqual('',self.git('status','--porcelain'))

    def test_preserves_unrelated_writer_and_dirty_worktree_after_validation(self):
        def write(_repo):
            (self.repo/'unrelated').write_text('preserve me')
            return 'fail'
        with patch.object(mb,'validate_step',side_effect=write):
            code, receipt = self.merge()
        self.assertEqual((3,'integration_changed'),(code,receipt['status']))
        self.assertEqual('preserve me',(self.repo/'unrelated').read_text())
        self.assertTrue((self.repo/'one').exists())

    def test_common_directory_lock_prevents_other_merge_invocations(self):
        with mb.integration_lock(self.repo):
            with self.assertRaises(mb.Refused): self.merge()
        self.assertEqual('base',self.git('log','-1','--format=%s'))

    def test_board_reads_are_read_only(self):
        before = self.path.read_bytes()
        with mb.read_board(self.root,'nixhomeserver') as db:
            with self.assertRaises(sqlite3.OperationalError):
                db.execute("UPDATE tasks SET status='open'")
        self.assertEqual(before,self.path.read_bytes())

    def test_acceptance_revoked_during_validation_stops_and_reverts(self):
        def revoke(_repo):
            self.run_review('one',self.sha,verdict='request-changes')
            return 'pass'
        with patch.object(mb,'validate_step',side_effect=revoke):
            code, receipt = self.merge()
        self.assertEqual(3,code)
        self.assertEqual('reverted',receipt['status'])
        self.assertFalse((self.repo/'one').exists())

    def test_previously_merged_candidate_requires_validation_before_success(self):
        self.git('merge','--no-ff','--no-edit',self.sha)
        before = self.git('rev-parse','HEAD')
        with patch.object(mb,'validate_step',return_value='fail') as validate:
            code, receipt = self.merge()
        self.assertEqual((3,'integration_unverified'),(code,receipt['status']))
        validate.assert_called_once()
        self.assertEqual(before,self.git('rev-parse','HEAD'))
        self.assertTrue((self.repo/'one').exists())

    def test_previously_merged_candidate_rechecks_acceptance_and_master(self):
        self.git('merge','--no-ff','--no-edit',self.sha)
        def revoke(_repo):
            self.run_review('one',self.sha,verdict='request-changes')
            return 'pass'
        with patch.object(mb,'validate_step',side_effect=revoke):
            code, receipt = self.merge()
        self.assertEqual((3,'integration_unverified'),(code,receipt['status']))
        self.run_review('one',self.sha)
        def change_master(_repo):
            (self.repo/'other').write_text('unrelated committed writer')
            self.git('add','other'); self.git('commit','-qm','unrelated writer')
            return 'pass'
        with patch.object(mb,'validate_step',side_effect=change_master):
            code, receipt = self.merge()
        self.assertEqual((3,'integration_unverified'),(code,receipt['status']))
        self.assertEqual('unrelated committed writer',(self.repo/'other').read_text())
        with patch.object(mb,'validate_step',return_value='pass') as validate:
            code, receipt = self.merge()
        self.assertEqual((0,'already_integrated'),(code,receipt['status']))
        validate.assert_called_once()

    def test_reverted_exact_tip_cannot_report_already_integrated(self):
        with patch.object(mb,'validate_step',return_value='fail'):
            self.assertEqual('reverted',self.merge()[1]['status'])
        before = self.git('rev-parse','master')
        with self.assertRaisesRegex(mb.Refused,'RECONSTRUCTION_REQUIRED'):
            self.merge()
        self.assertEqual(before,self.git('rev-parse','master'))
        self.assertFalse((self.repo/'one').exists())

    def test_reverted_work_remains_visible_to_list_and_plan(self):
        with patch.object(mb,'validate_step',return_value='fail'):
            self.merge()
        listing = io.StringIO()
        with redirect_stdout(listing):
            mb.list_backlog(self.root,self.repo)
        self.assertIn('UNMERGED_REVERTED_WORK t_one',listing.getvalue())
        plan = io.StringIO()
        with redirect_stdout(plan):
            mb.plan_backlog(self.root,self.repo,'wt/one')
        self.assertIn('"status": "reconstruction-required"',plan.getvalue())

    def test_repair_on_old_reverted_branch_requires_composition_before_queue(self):
        with patch.object(mb,'validate_step',return_value='fail'):
            self.merge()
        self.git('checkout','-q','wt/one')
        (self.repo/'repair').write_text('delta without restored feature')
        self.git('add','repair'); self.git('commit','-qm','repair delta')
        repaired = self.git('rev-parse','HEAD')
        self.git('checkout','-q','master')
        self.run_review('one',repaired)
        before = self.git('rev-parse','HEAD')
        with self.assertRaisesRegex(mb.Refused,'RECONSTRUCTION_REQUIRED'):
            mb.merge_queue(self.root,self.repo,[('wt/one',repaired)],1)
        self.assertEqual(before,self.git('rev-parse','HEAD'))
        self.assertFalse((self.repo/'repair').exists())
        self.assertFalse((self.repo/'one').exists())

    def test_reviewed_composition_from_rollback_master_can_restore_feature(self):
        with patch.object(mb,'validate_step',return_value='fail'):
            self.merge()
        rollback = self.git('rev-parse','HEAD')
        self.assertIn('Hermes-Merge-Back-Rollback: '+self.sha,self.git('log','-1','--format=%B'))
        self.git('checkout','-qb','wt/composition')
        self.git('cherry-pick',self.sha)
        composed = self.git('rev-parse','HEAD')
        self.git('checkout','-q','master')
        self.db.execute('INSERT INTO tasks VALUES (?,?,?,?,?)',
                        ('t_composition','composition','done','standard-implementer','wt/composition'))
        self.db.execute('INSERT INTO tasks VALUES (?,?,?,?,NULL)',
                        ('t_composition_review','review','done','feature-reviewer'))
        self.db.execute('INSERT INTO task_links VALUES (?,?)',('t_composition','t_composition_review'))
        self.run_review('composition',composed)
        with patch.object(mb,'validate_step',return_value='pass'):
            code, receipt = mb.merge_queue(self.root,self.repo,[('wt/composition',composed)],1)
        self.assertEqual((0,'merged'),(code,receipt['results'][0]['status']))
        self.assertEqual('one',(self.repo/'one').read_text())
        self.git('merge-base','--is-ancestor',rollback,'master')

    def test_validation_exception_restores_master_without_rewriting_history(self):
        with patch.object(mb,'validate_step',side_effect=subprocess.TimeoutExpired('gate',1800)):
            code, receipt = self.merge()
        self.assertEqual(3,code)
        self.assertEqual('reverted',receipt['status'])
        self.assertFalse((self.repo/'one').exists())
        self.assertEqual(4,int(self.git('rev-list','--count','HEAD')))

unittest.main(argv=['authority-tests'])
PY

echo "▶ worktree merge-back: all checks passed"
