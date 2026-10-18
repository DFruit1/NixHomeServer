"""Install only reviewed native seams; refuse incompatible upstream revisions."""

EDITS = {
    'tools/kanban_tools.py': (
        ('    with _board(args.get("board")) as (kb, conn):\n'
         '        task = _existing_task(kb, conn, tid)\n        return json.dumps({',
         '    from hermes_cli.nixhomeserver_autonomy import evidence_board\n'
         '    with evidence_board(_board, args.get("board"), _persisted_identity()) as (kb, conn):\n'
         '        task = _existing_task(kb, conn, tid)\n        return json.dumps({'),
    ),
    'hermes_cli/fallback_config.py': (
        ('    return chain\n\n\ndef scoped_fallback_chain(',
         '    from hermes_cli.nixhomeserver_autonomy import allowed_fallbacks\n'
         '    from hermes_cli.profiles import current_profile_name\n'
         '    return allowed_fallbacks(chain, current_profile_name())\n\n\ndef scoped_fallback_chain('),
    ),
    'agent/agent_init.py': (
        ('    return [\n'
         '        f for f in fallback_model if isinstance(f, dict) and f.get("provider") and f.get("model")\n'
         '    ]\n',
         '    from hermes_cli.nixhomeserver_autonomy import allowed_fallbacks\n'
         '    from hermes_cli.profiles import current_profile_name\n'
         '    return allowed_fallbacks([\n'
         '        f for f in fallback_model if isinstance(f, dict) and f.get("provider") and f.get("model")\n'
         '    ], current_profile_name())\n'),
    ),
}


def adapt(name, text):
    for before, after in EDITS[name]:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native autonomy adapter source drift; reconcile before installation')
        text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
