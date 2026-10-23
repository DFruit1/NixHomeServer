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
            reason=args.get("reason"), runtime_evidence=args.get("runtime_evidence"),
            terminal_episode=args.get("terminal_episode"),
            workspace_rebind=args.get("workspace_rebind")))


'''
# Exact installed predecessors. The terminal-episode seam gains the rebind
# argument in place; the older pre-episode seam migrates straight to the current
# handler. Migration replaces one exact literal, so an installed native is
# upgraded instead of duplicated and any other text fails closed.
PREVIOUS_HANDLER = '''@_kanban_handler("kanban_amend")
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
            reason=args.get("reason"), runtime_evidence=args.get("runtime_evidence"),
            terminal_episode=args.get("terminal_episode")))


'''
LEGACY_HANDLER = '''@_kanban_handler("kanban_amend")
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
PREVIOUS_INTAKE_HANDLER = HANDLER
HANDLER = HANDLER.replace('workspace_rebind=args.get("workspace_rebind")))',
    'workspace_rebind=args.get("workspace_rebind"), verification_intake=args.get("verification_intake")))', 1)
PREVIOUS_HANDLERS = (PREVIOUS_INTAKE_HANDLER, PREVIOUS_HANDLER, LEGACY_HANDLER)
SCHEMA = '''KANBAN_AMEND_SCHEMA = {
    "name": "kanban_amend",
    "description": "Native head-coordinator only: inspect version, amend parked technical body/priority/skills/runtime or classify an untyped failed blocked card as capability. An optional terminal_episode {run_id,event_id} classifies one untyped blocked containment or reaffirms one reclaimed capability episode, valid only with changes exactly {block_kind:capability}; both the containment and the same-kind reaffirmation need the agent/model supplier line plus 'Repair evidence:' or 'Authorized continuation:' evidence, and a reaffirmation must match this run's native claim, reclaim and prior release chronology. An optional workspace_rebind {workspace_kind:'dir',workspace_path} alone records one existing canonical absolute directory that is not a repository, worktree or bare repository root for a parked capability hold, valid only with changes exactly {workspace_kind,workspace_path}; it must change the stored binding, consumes the exact version, appends the binding and its preimage, and never types, releases or re-arms the hold, and an independent workspace-prep receipt in the card thread is still required before release. Exact CAS and supplier evidence required. Never releases work or resets retries; use versioned guarded recovery afterwards.",
    "parameters": {"type":"object", "properties": {
        "board":{"type":"string"}, "task_id":{"type":"string"},
        "expected_version":{"type":"string"},
        "changes":{"type":"object", "properties": {
            "body":{"type":"string"}, "priority":{"type":"integer"},
            "skills":{"type":"array","items":{"type":"string"}},
            "block_kind":{"type":"string","enum":["capability"]},
            "workspace_kind":{"type":"string","enum":["dir"]},
            "workspace_path":{"type":"string"},
            "max_runtime_seconds":{"type":"integer"}}, "additionalProperties":False},
        "reason":{"type":"string"},
        "runtime_evidence":{"type":"object", "properties": {
            "run_id":{"type":"integer"}, "remaining_work":{"type":"string"},
            "expected_completion":{"type":"string"}, "stop_condition":{"type":"string"}},
            "required":["run_id","remaining_work","expected_completion","stop_condition"], "additionalProperties":False},
        "terminal_episode":{"type":"object", "properties": {
            "run_id":{"type":"integer"}, "event_id":{"type":"integer"}},
            "required":["run_id","event_id"], "additionalProperties":False},
        "workspace_rebind":{"type":"object", "properties": {
            "workspace_kind":{"type":"string","enum":["dir"]},
            "workspace_path":{"type":"string"}},
            "required":["workspace_kind","workspace_path"], "additionalProperties":False}},
        "required":["task_id"], "additionalProperties":False}}


'''
# Preserve the exact installed schema while extending only initial provisioning.
PREVIOUS_REBIND = SCHEMA
SCHEMA = SCHEMA.replace('for a parked capability hold, valid only',
    'for a parked capability hold or a never-started TODO/administratively scheduled scratch task with no path or execution, valid only', 1)

# Keep the exact previous advertised seam for atomic, drift-checked migration.
# These descriptions distinguish inspection, ordinary failed-run classification
# and the two special terminal episodes; the native authority is unchanged.
PREVIOUS_INSPECTION = SCHEMA
SCHEMA = SCHEMA.replace('Native head-coordinator only: inspect version,',
    'Native head-coordinator only. Inspect with task_id alone. Omit changes and expected_version to return the read-only version; there is no CLI version command. For a mutation use that exact expected_version, changes and reason. For an untyped blocked crashed/timed_out/spawn_failed/gave_up run, use changes {block_kind:capability} without terminal_episode and an Input supplier: agent or model/provider reason. Never guess versions from body hashes or use kanban_comment as the tool transport. Native head-coordinator only: inspect version,', 1)
SCHEMA = SCHEMA.replace('"expected_version":{"type":"string"}',
    '"expected_version":{"type":"string","description":"Omit for read-only inspection. For mutation copy version from the immediately preceding task_id-only inspection; this is not recovery_version."}', 1)
SCHEMA = SCHEMA.replace('"changes":{"type":"object", "properties": {',
    '"changes":{"type":"object", "description":"Omit for read-only inspection. Ordinary failed-run classification uses block_kind capability without terminal_episode; preserve counters and typed gates.", "properties": {', 1)
SCHEMA = SCHEMA.replace('"terminal_episode":{"type":"object", "properties": {',
    '"terminal_episode":{"type":"object", "description":"Only for an untyped native blocked containment or existing capability reclaimed gave_up episode; not for crashed or timed_out failed-run classification. Omit for inspection and ordinary failed-run classification.", "properties": {', 1)

# Retain the inspection-only predecessor for exact migration, never a downgrade.
PREVIOUS_INTAKE_SCHEMA = SCHEMA
SCHEMA = SCHEMA.replace('Never releases work or resets retries;',
    'verification_intake standalone, with changes exactly {tenant:verification}, strengthens only an untouched TODO feature-reviewer inherited continuous-improvement card after durable directory/runtime preparation. It refuses all prior runs, claims, review provenance, typed gates and structured workflows; preserve every prerequisite and record actual preimage/actor without a synthetic handoff. Never releases work or resets retries;', 1)
SCHEMA = SCHEMA.replace('"block_kind":{"type":"string","enum":["capability"]},',
    '"block_kind":{"type":"string","enum":["capability"]},\n            "tenant":{"type":"string","enum":["verification"]},', 1)
SCHEMA = SCHEMA.replace('"workspace_rebind":{"type":"object", "properties": {',
    '"verification_intake":{"type":"string","enum":["standalone"]},\n        "workspace_rebind":{"type":"object", "properties": {', 1)

# The seam installed before typed-timeout reaffirmation. Migration replaces one
# exact literal, so an installed native is upgraded instead of duplicated and
# the verification_intake/workspace_rebind seams survive the upgrade.
PREVIOUS_TIMEOUT_SCHEMA = SCHEMA
SCHEMA = SCHEMA.replace('reaffirms one reclaimed capability episode',
    'reaffirms one reclaimed or elapsed-limit timed-out capability episode', 1)
SCHEMA = SCHEMA.replace('existing capability reclaimed gave_up episode',
    'existing capability reclaimed or elapsed-limit timed_out gave_up episode', 1)
SCHEMA = SCHEMA.replace('reclaim and prior release chronology.',
    'reclaim and prior release chronology, or -- for an elapsed-limit timeout -- its native claim, '
    'run-scoped timed_out event over the cap and prior release chronology.', 1)

# Keep the exact pre-clarification schema so installation migrates atomically.
PREVIOUS_SUPPLIER_SCHEMA = SCHEMA
SCHEMA = SCHEMA.replace('Never releases work or resets retries;',
    'A terminal_episode may also clarify the absent supplier of the current same-kind capability TRIAGE block_loop_detected episode: latest finished blocked run, exact run-bound latest event, integer recurrences matching the task and reaching its integer limit. The old reason must have no supplier marker, including malformed or ambiguous text. The new reason must have exactly one canonical Input supplier: agent or model/provider marker and substantive Repair evidence: naming delivery actually verified by the coordinator; Authorized continuation alone is insufficient. This appends one classification event and preserves every task field, history, phase, counter, budget and review gate. Never releases work or resets retries;', 1)
SCHEMA = SCHEMA.replace('Only for an untyped native blocked containment or existing capability reclaimed or elapsed-limit timed_out gave_up episode;',
    'Only for an untyped native blocked containment, existing capability reclaimed or elapsed-limit timed_out gave_up episode, or current same-kind capability TRIAGE block_loop_detected supplier clarification;', 1)

# The seam installed before the workspace-rebind branch: one exact literal
# migration, so an installed native is upgraded instead of duplicated.
PREVIOUS = '''KANBAN_AMEND_SCHEMA = {
    "name": "kanban_amend",
    "description": "Native head-coordinator only: inspect version, amend parked technical body/priority/skills/runtime or classify an untyped failed blocked card as capability. An optional terminal_episode {run_id,event_id} classifies one untyped blocked containment or reaffirms one reclaimed capability episode, valid only with changes exactly {block_kind:capability}; both the containment and the same-kind reaffirmation need the agent/model supplier line plus 'Repair evidence:' or 'Authorized continuation:' evidence, and a reaffirmation must match this run's native claim, reclaim and prior release chronology. Exact CAS and supplier evidence required. Never releases work or resets retries; use versioned guarded recovery afterwards.",
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
            "required":["run_id","remaining_work","expected_completion","stop_condition"], "additionalProperties":False},
        "terminal_episode":{"type":"object", "properties": {
            "run_id":{"type":"integer"}, "event_id":{"type":"integer"}},
            "required":["run_id","event_id"], "additionalProperties":False}},
        "required":["task_id"], "additionalProperties":False}}


'''
# The oldest seam a native may still carry: pre-episode, pre-block_kind.
LEGACY = '''KANBAN_AMEND_SCHEMA = {
    "name": "kanban_amend",
    "description": "Native head-coordinator only: inspect a card version, then amend parked technical body, priority, skills or finite runtime using exact CAS. Never releases work or resets retries. Record superseded evidence and use normal guarded resume afterwards.",
    "parameters": {"type":"object", "properties": {
        "board":{"type":"string"}, "task_id":{"type":"string"},
        "expected_version":{"type":"string"},
        "changes":{"type":"object", "properties": {
            "body":{"type":"string"}, "priority":{"type":"integer"},
            "skills":{"type":"array","items":{"type":"string"}},
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
    if name == 'tools/kanban_tools.py' and text.count(HANDLER) != 1:
        for previous in PREVIOUS_HANDLERS:
            if text.count(previous) == 1:
                text = text.replace(previous, HANDLER, 1)
                break
    if name == 'tools/kanban_tools_schemas.py' and SCHEMA not in text:
        for variant in (PREVIOUS_SUPPLIER_SCHEMA, PREVIOUS_TIMEOUT_SCHEMA, PREVIOUS_INTAKE_SCHEMA, PREVIOUS_INSPECTION,
                        PREVIOUS_REBIND, PREVIOUS, LEGACY):
            if text.count(variant) == 1:
                text = text.replace(variant, SCHEMA, 1)
                break
    for before, after in EDITS[name]:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native amendment source drift; reconcile before installation')
        text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
