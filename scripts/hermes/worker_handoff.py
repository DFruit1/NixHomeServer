"""Verify native worker handoffs from receipts, not attempted tool calls.

Python glue is required by Hermes' Python turn loop. This policy only selects a
bounded continuation; native board transactions retain all mutation authority.
"""
import json


TERMINAL_TOOLS = frozenset({
    'kanban_complete', 'kanban_block', 'kanban_schedule',
    'kanban_request_review', 'kanban_request_changes',
})


def _field(value, name, default=None):
    return value.get(name, default) if isinstance(value, dict) else getattr(value, name, default)


def _object(value):
    if isinstance(value, str):
        try:
            value = json.loads(value)
        except (ValueError, TypeError):
            return None
    return value if isinstance(value, dict) else None


def session_handed_off(messages, *, task_id, board=None):
    """Require a correlated successful native result for this worker's card.

Omitted arguments retain the native dispatcher defaults. Explicit different
targets and error responses cannot suppress recovery. Tool messages may omit
their name; the assistant call ID still supplies the actual tool identity.
"""
    if not task_id:
        return False
    from agent.message_sanitization import coalesce_tool_call_id

    calls = {}
    for message in messages or ():
        if not isinstance(message, dict):
            continue
        if message.get('role') == 'assistant':
            for call in message.get('tool_calls') or ():
                function = _field(call, 'function', call)
                name = _field(function, 'name')
                call_id = coalesce_tool_call_id(call)
                arguments = _object(_field(function, 'arguments', {}))
                if isinstance(call_id, str) and call_id:
                    calls[call_id] = (name, arguments)
        elif message.get('role') == 'tool':
            result_id = coalesce_tool_call_id({'id': message.get('tool_call_id')})
            call = calls.pop(result_id, None)
            if call is None:
                continue
            name, arguments = call
            if name not in TERMINAL_TOOLS or arguments is None:
                continue
            if message.get('name') not in (None, '', name):
                continue
            if arguments.get('task_id') not in (None, '', task_id):
                continue
            if board and arguments.get('board') not in (None, '', board):
                continue
            receipt = _object(message.get('content'))
            if (receipt is None or receipt.get('ok') is not True
                    or receipt.get('error') or receipt.get('task_id') != task_id):
                continue
            if board and receipt.get('board') not in (None, '', board):
                continue
            return True
    return False


def handoff_nudge(task_id, board=None):
    """Name copyable native arguments and preserve every existing gate."""
    target = 'task_id=' + json.dumps(task_id)
    if board:
        target = 'board=' + json.dumps(board) + ', ' + target
    return (
        '[System: No successful native handoff is recorded for your assigned '
        'kanban task. A rejected call or plain-text promise leaves it running.\n\n'
        f'Use {target} on every handoff call. Read the latest tool error and '
        'current card; correct the demonstrated missing input or argument. '
        'Perform the actual native call in your next response.\n'
        f'- kanban_complete({target}, summary=...) only when the deliverable '
        'and its current acceptance contract are satisfied.\n'
        f'- kanban_request_review({target}, summary=..., reviewer=..., metadata=...) '
        'for implemented, validated changes requiring independent review.\n'
        f'- kanban_request_changes({target}, reason=...) for reviewer rework.\n'
        f'- kanban_block({target}, kind=..., reason=...) for a qualified blocker. '
        'A dependency block needs an actual open prerequisite linked before this card.\n'
        f'- kanban_schedule({target}, reason=...) for an allowed non-goal wait; '
        'record the exact prerequisite and material wake condition.\n\n'
        'Preserve review, goal-mode, provider and owner gates, task identity and '
        'retry budgets. Never remove a rejected review or invent an owner blocker '
        'to make a handoff succeed. Do not repeat unchanged failed operations.]'
    )
