#!/usr/bin/env python3
"""Exercise actual Hermes same-card handoff, rework and qualified completion."""
import argparse
import importlib.util
import os
from pathlib import Path
import sys

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--hermes-repo', type=Path, required=True)
parser.add_argument('--scratch', type=Path, required=True)
args = parser.parse_args()
root = args.scratch / 'home'
os.environ['HERMES_HOME'] = str(root)
os.environ['HERMES_ROOT'] = str(root)
os.environ['HERMES_KANBAN_WORKSPACES_ROOT'] = str(args.scratch / 'workspaces')
sys.path.insert(0, str(args.hermes_repo))
from hermes_cli import kanban_db as kb  # noqa: E402
from hermes_cli.kanban_db_connect import connect  # noqa: E402

source = Path(__file__).resolve().parents[1] / 'hermes'
sys.path.insert(0, str(source))
spec = importlib.util.spec_from_file_location('guard', source / 'review-verdict-guard.py')
guard = importlib.util.module_from_spec(spec)
spec.loader.exec_module(guard)
db_path = root / 'kanban/boards/test/kanban.db'
db_path.parent.mkdir(parents=True)
db = connect(db_path)
try:
    task_id = kb.create_task(db, title='Native lifecycle fixture', body='Workflow: native-review-v1',
                             assignee='standard-implementer', workspace_kind='dir',
                             workspace_path=str(args.scratch))
    claim = kb.claim_task(db, task_id)
    assert claim is not None
    handoff = {'revision': 'a' * 40, 'plan_author': 'owner',
               'checks': [{'command': 'fixture gate', 'exit_code': 0}]}
    assert kb.request_review(db, task_id, metadata=handoff,
                             reviewer='feature-reviewer', expected_run_id=claim.current_run_id)
    review = kb.claim_review_task(db, task_id)
    assert review is not None
    accepted = {**handoff, 'verdict': 'accept',
                'independence': {'plan_author': False, 'implementer': False}}
    payload = {'tool_name': 'kanban_complete', 'tool_input': {
        'board': 'test', 'task_id': task_id, 'metadata': accepted}}
    assert guard.guard(payload, root) == {}, guard.guard(payload, root)
    ok, implementer = kb.request_changes(db, task_id, reason='Synthetic correction',
                                        expected_run_id=review.current_run_id)
    assert ok and implementer == 'standard-implementer'
    claim = kb.claim_task(db, task_id)
    assert claim is not None
    assert guard.guard(payload, root).get('action') == 'block'
    handoff['revision'] = 'b' * 40
    assert kb.request_review(db, task_id, metadata=handoff, expected_run_id=claim.current_run_id)
    review = kb.claim_review_task(db, task_id)
    assert review is not None
    assert guard.guard(payload, root).get('action') == 'block'  # stale acceptance
    accepted['revision'] = 'b' * 40
    assert guard.guard(payload, root) == {}, guard.guard(payload, root)
    accepted['independence']['plan_author'] = True
    assert guard.guard(payload, root).get('action') == 'block'
    accepted['independence']['plan_author'] = False
    assert kb.complete_task(db, task_id, summary='Independently checked the fixture.', metadata=accepted, expected_run_id=review.current_run_id,
                            fire_lifecycle_hook=False)
    assert kb.get_task(db, task_id).status == 'done'
    assert len(db.execute('SELECT id FROM tasks').fetchall()) == 1
    print('PASS: native handoff, reviewer rejection, implementer rework, stale-verdict refusal and acceptance on one task')
finally:
    db.close()
