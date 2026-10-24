#!/usr/bin/env python3
"""Exercise new record seams on the installed native source in a confined fixture."""
import json
import os
from pathlib import Path
import sys
import tempfile
from unittest.mock import patch

if os.environ.get('HERMES_FIXTURE_ACTIVE') != '1':
    raise SystemExit('Native card-record tests require the maintained confined fixture')
origin = json.loads(Path(os.environ['HERMES_FIXTURE_ORIGIN']).read_text())
assert Path(origin['suite']).name == 'test-hermes-card-records.sh'
source = Path(__file__).resolve().parents[1] / 'hermes'
native = Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2]
sys.path.insert(0, str(native))
import hermes_bootstrap
sys.path.insert(0, str(source))
from card_records_adapter import adapt

with tempfile.TemporaryDirectory(prefix='card-records-native-') as directory:
    scratch = Path(directory)
    overlay = scratch / 'overlay'
    overlay.mkdir()
    tools_overlay = scratch / 'tools'
    tools_overlay.mkdir()
    for relative in ('hermes_cli/kanban_db.py', 'hermes_cli/kanban.py', 'hermes_cli/kanban_parser.py',
                     'tools/kanban_tools.py', 'tools/kanban_tools_schemas.py'):
        text = (native / relative).read_text()
        changed = adapt(relative, text)
        assert adapt(relative, changed) == changed, relative + ' is not idempotent'
        target = tools_overlay if relative.startswith('tools/') else overlay
        (target / Path(relative).name).write_text(changed)
    (overlay / 'nixhomeserver_card_records.py').write_text((source / 'card_records.py').read_text())
    import hermes_cli
    hermes_cli.__path__.insert(0, str(overlay))
    import tools
    tools.__path__.insert(0, str(tools_overlay))
    from hermes_cli import kanban_db as kb
    from hermes_cli.kanban_db_connect import connect
    from hermes_cli import nixhomeserver_card_records as records
    from tools import kanban_tools as native_tools
    db = connect(scratch / 'board/kanban.db')
    try:
        tid = kb.create_task(db, title='Synthetic record evidence', assignee='head-coordinator',
                             workspace_kind='dir', workspace_path=str(scratch))
        before = kb.get_task(db, tid)
        state = records.inspect(db, tid)
        records.write(kb, db, tid, 'decision_owner', {'owner': 'head-coordinator'},
                      actor='head-coordinator', expected_version=state['version'])
        assert not kb.list_comments(db, tid)
        assert kb.get_task(db, tid).status == before.status
        assert 'decision_owner' in kb.build_worker_context(db, tid)
        assert 'Card records' in kb.build_worker_context(db, tid)
        # The API reads actual records, and does not accept caller-supplied authorship.
        import contextlib
        @contextlib.contextmanager
        def board(_):
            yield kb, db
        with patch.object(native_tools, '_board', board), \
             patch.object(native_tools, '_persisted_identity', return_value='head-coordinator'):
            result = json.loads(native_tools._handle_record({'task_id': tid}))
            assert result['records']['decision_owner']['value']['owner'] == 'head-coordinator', result
            result = json.loads(native_tools._handle_record({'task_id': tid, 'kind': 'decision_owner',
                'value': {'owner': 'pending-assessment'}, 'expected_version': result['version']}))
            assert result['records']['decision_owner']['value']['owner'] == 'pending-assessment', result
            assert not kb.list_comments(db, tid)
        with patch.object(native_tools, '_board', board), \
             patch.object(native_tools, '_persisted_identity', return_value='standard-implementer'):
            rejected = json.loads(native_tools._handle_record({'task_id': tid, 'kind': 'decision_owner',
                'value': {'owner': 'head-coordinator'}, 'expected_version': result['version']}))
            assert rejected.get('error'), rejected
        # Native retention keeps the operational record of a completed task.
        from fleet_runtime_adapter import adapt as fleet_adapt
        text = fleet_adapt('kanban_db.py', (native / 'hermes_cli/kanban_db.py').read_text())
        assert "kind NOT IN ('decomposed','task_record')" in text
    finally:
        db.close()
print('Native record API, context, idempotent adapters and retention passed')
