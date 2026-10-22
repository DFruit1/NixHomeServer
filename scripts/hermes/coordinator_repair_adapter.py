"""Exact native tool seams for coordinator amendments; fail closed on drift."""

HANDLER = '''@_kanban_handler("kanban_amend")
def _handle_amend(args: dict, **kwargs):
    _reject_delegated_child_mutation("kanban_amend")
    from hermes_cli.nixhomeserver_coordinator_repair import amend
    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin
    actor = coordinator_origin()
    _check(actor is not None, "Native head-coordinator identity required")
    _check(args.get("board") in (None, actor["board"]), "Amend only the authenticated board")
    with _board(actor["board"]) as (kb, conn):
        return _ok(**amend(kb, conn, str(args.get("task_id", "")),
            expected_version=args.get("expected_version"), changes=args.get("changes"),
            reason=args.get("reason"), runtime_evidence=args.get("runtime_evidence")))


'''
SCHEMA = '''KANBAN_AMEND_SCHEMA = {
    "name": "kanban_amend",
    "description": "Native head-coordinator only: inspect version, amend parked technical body/priority/skills/runtime or classify an untyped failed blocked card as capability. Exact CAS and supplier evidence required. Never releases work or resets retries; use versioned guarded recovery afterwards.",
    "parameters": {"type":"object", "properties": {
        "board":{"type":"string"}, "task_id":{"type":"string"},
        "expected_version":{"type":"string"},
        "changes":{"type":"object", "properties": {
            "body":{"type":"string"}, "priority":{"type":"integer"},
            "skills":{"type":"array","items":{"type":"string"}},
            "block_kind":{"type":"string","enum":["capability"]},
            "max_runtime_seconds":{"type":"integer"}}, "additionalProperties":False},
        "reason":{"type":"string"},
        "runtime_evidence":{"type":"object", "properties": {
            "run_id":{"type":"integer"}, "remaining_work":{"type":"string"},
            "expected_completion":{"type":"string"}, "stop_condition":{"type":"string"}},
            "required":["run_id","remaining_work","expected_completion","stop_condition"], "additionalProperties":False}},
        "required":["task_id"], "additionalProperties":False}}


'''
EDITS = {
 'tools/kanban_tools.py': (
    ('    KANBAN_ATTACH_SCHEMA,', '    KANBAN_AMEND_SCHEMA, KANBAN_ATTACH_SCHEMA,'),
    ('# --- Registration (order preserved: it is the order tools appear in the schema) ---',
     HANDLER + '# --- Registration (order preserved: it is the order tools appear in the schema) ---'),
    ('                      check_fn=_gate)', '                      check_fn=_gate)\n\n'
     '@no_cache_check_fn\ndef _check_kanban_amend_mode():\n'
     '    from hermes_cli.nixhomeserver_resume_recovered import coordinator_origin\n'
     '    return coordinator_origin() is not None\n\n'
     'registry.register(name="kanban_amend", toolset="kanban", schema=KANBAN_AMEND_SCHEMA,\n'
     '                  handler=_handle_amend, emoji="✎", check_fn=_check_kanban_amend_mode)'),
 ),
 'tools/kanban_tools_schemas.py': (
    ('KANBAN_UNBLOCK_SCHEMA =', SCHEMA + 'KANBAN_UNBLOCK_SCHEMA ='),
 ),
}


def adapt(name, text):
    if name == 'tools/kanban_tools_schemas.py':
        legacy = SCHEMA.replace(
            'Native head-coordinator only: inspect version, amend parked technical body/priority/skills/runtime or classify an untyped failed blocked card as capability. Exact CAS and supplier evidence required. Never releases work or resets retries; use versioned guarded recovery afterwards.',
            'Native head-coordinator only: inspect a card version, then amend parked technical body, priority, skills or finite runtime using exact CAS. Never releases work or resets retries. Record superseded evidence and use normal guarded resume afterwards.'
        ).replace('            "block_kind":{"type":"string","enum":["capability"]},\n','')
        if text.count(legacy) == 1 and SCHEMA not in text:
            text=text.replace(legacy,SCHEMA,1)
    for before, after in EDITS[name]:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native amendment source drift; reconcile before installation')
        text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
