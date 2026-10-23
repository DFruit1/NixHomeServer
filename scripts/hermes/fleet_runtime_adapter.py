"""Source-checked native seams for the structured fleet contract.

Keep this separate from policy adapters: one owner supplies each exact edit,
and incompatible native versions refuse before any installation writes.
"""

EDITS = {
    'kanban_db.py': (
        ('    completion_contract: Optional[str] = None,\n) -> str:',
         '    completion_contract: Optional[str] = None,\n    workflow: Optional[dict] = None,\n) -> str:'),
        ('    completion_contract = validate_contract(completion_contract)\n',
         '    completion_contract = validate_contract(completion_contract)\n'
         '    from hermes_cli import nixhomeserver_fleet_contract as fleet_contract\n'
         '    if workflow is not None:\n'
         '        workflow = fleet_contract.validate(workflow)\n'
         '        fleet_contract.validate_board(conn, workflow)\n'
         '        body = fleet_contract.render(body, workflow)\n'
         '        if workflow.get("review") and assignee in {"feature-reviewer", "project-auditor"}:\n'
         '            raise ValueError("Implementation workflow cannot be assigned to its independent verifier")\n'),
        ('                        "creator_task_id": creator_task_id,\n',
         '                        "creator_task_id": creator_task_id,\n'
         '                        **({"workflow": workflow} if workflow is not None else {}),\n'),
        ('    fire_lifecycle_hook: bool = True, force: bool = False,\n) -> bool:',
         '    fire_lifecycle_hook: bool = True, force: bool = False,\n'
         '    delivery: Optional[dict] = None,\n) -> bool:'),
        ('        if acceptance is not None and not record_acceptance(conn, task_id, acceptance):\n',
         '        from hermes_cli import nixhomeserver_fleet_contract as fleet_contract\n'
         '        metadata = fleet_contract.completion_metadata(conn, task_id, metadata, delivery)\n'
         '        if acceptance is not None and not record_acceptance(conn, task_id, acceptance):\n'),
        ('    metadata = redact_review_value(metadata)\n',
         '    metadata = redact_review_value(metadata)\n'
         '    from hermes_cli import nixhomeserver_fleet_contract as fleet_contract\n'
         '    metadata = fleet_contract.review_metadata(conn, task_id, metadata)\n'),
        ('            reviewer = _canonical_assignee(reviewer)\n',
         '            reviewer = _canonical_assignee(reviewer)\n'
         '            metadata = fleet_contract.review_metadata(conn, task_id, metadata)\n'
         '            if fleet_contract.load(conn, task_id) is not None:\n'
         '                from hermes_cli.nixhomeserver_fleet_workflow import validate_handoff_metadata\n'
         '                validate_handoff_metadata(metadata)\n'),
        ('"DELETE FROM task_events WHERE created_at < ? AND kind != \'decomposed\' AND task_id IN "',
         '"DELETE FROM task_events WHERE created_at < ? AND kind != \'decomposed\' "\n'
         '            "AND NOT (kind IN (\'created\',\'review_requested\',\'claimed\',\'changes_requested\') "\n'
         '            "AND task_id IN (SELECT task_id FROM task_events WHERE kind=\'created\' "\n'
         '            "AND json_type(payload, \'$.workflow\') IS NOT NULL)) AND task_id IN "'),
    ),
    'tools/kanban_tools.py': (
        ('            conn, title=str(title).strip(), body=args.get("body"), assignee=str(assignee),\n',
         '            conn, title=str(title).strip(), body=args.get("body"), assignee=str(assignee),\n'
         '            workflow=args.get("workflow"),\n'),
        ('                created_cards=created_cards, expected_run_id=_worker_run_id(tid))\n',
         '                created_cards=created_cards, expected_run_id=_worker_run_id(tid),\n'
         '                delivery=args.get("delivery"))\n'),
        ('            "task": _fields(task, _TASK_FIELDS),\n',
         '            "task": _fields(task, _TASK_FIELDS),\n'
         '            "workflow": __import__("hermes_cli.nixhomeserver_fleet_contract", fromlist=["load"]).load(conn, tid),\n'),
    ),
}

SCHEMAS = '''
# Structured fleet inputs; the native transaction validates the same contract.
KANBAN_CREATE_SCHEMA["parameters"]["properties"]["workflow"] = {
    "type": "object", "additionalProperties": False,
    "description": "Immutable workflow contract. Body markers are generated. Name the truthful plan author and exact requested feature scope.",
    "properties": {
        "version": {"type": "integer", "enum": [1]},
        "review": {"type": "string", "enum": ["native-review-v1"]},
        "plan_author": {"type": "string"},
        "feature": {"type": "object", "additionalProperties": False,
            "properties": {"tracker": {"type": "string"}, "scope": {"type": "string"},
                "role": {"type": "string", "enum": ["producer", "delivery", "documentary-closure"]},
                "stage": {"type": "string", "enum": ["accepted", "integrated"]}},
            "required": ["tracker", "scope", "role"]},
        "requirements": {"type": "object", "additionalProperties": False,
            "properties": {"tools": {"type": "array", "items": {"type": "string"}},
                "imports": {"type": "array", "items": {"type": "string"}},
                "source_revision": {"type": "string"},
                "review": {"type": "object", "additionalProperties": False,
                    "properties": {"tools": {"type": "array", "items": {"type": "string"}},
                        "imports": {"type": "array", "items": {"type": "string"}}}}}}},
    "required": ["version"]}
KANBAN_COMPLETE_SCHEMA["parameters"]["properties"]["delivery"] = {
    "type": "object", "additionalProperties": False,
    "description": "Complete the contracted scope from actual independent accepted evidence. Native completion rechecks current evidence_version in its transaction; it never grants live activation.",
    "properties": {"state": {"type": "string", "enum": ["delivered_scope"]},
        "expected_version": {"type": "string"}, "evidence_task_id": {"type": "string"}},
    "required": ["state", "expected_version", "evidence_task_id"]}
'''


def adapt(name, text):
    if name == 'tools/kanban_tools_schemas.py':
        if SCHEMAS not in text:
            text = text.rstrip() + '\n' + SCHEMAS
    else:
        for before, after in EDITS[name]:
            if text.count(after) == 1:
                continue
            if text.count(before) != 1:
                raise ValueError('Native structured-workflow adapter source drift: ' + name)
            text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
