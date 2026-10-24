"""Source-checked native write seams; unknown upstream versions fail closed."""

EDITS = {
    'file_tools.py': (
        ('        with ExitStack() as _lock:\n',
         '        with ExitStack() as _lock:\n'
         '            from hermes_cli.nixhomeserver_directory_claims_runtime import file_write\n'
         '            _lock.enter_context(file_write([path], task_id=task_id, session_id=session_id))\n'),
        ('        with ExitStack() as _locks:\n',
         '        with ExitStack() as _locks:\n'
         '            from hermes_cli.nixhomeserver_directory_claims_runtime import file_write\n'
         '            _locks.enter_context(file_write(_paths_to_check, task_id=task_id, session_id=session_id))\n'),
    ),
    'terminal_tool.py': (
        ('        verdict = _run_approval_guards(command, env_type, plan.config, force=force)\n',
         '        verdict = _run_approval_guards(command, env_type, plan.config, force=force)\n'
         '        if not _host_local:\n'
         '            from hermes_cli.nixhomeserver_directory_claims_runtime import terminal_command\n'
         '            command = terminal_command(command, cwd=cwd, workdir=workdir,\n'
         '                task_id=task_id, session_id=session_id, env_type=env_type)\n'),
    ),
}


def adapt(name, text):
    for before, after in EDITS[name]:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native directory-claim adapter source drift: ' + name)
        text = text.replace(before, after, 1)
    compile(text, name, 'exec')
    return text
