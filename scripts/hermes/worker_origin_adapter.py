"""Version-checked native session-origin seam; preserve all unrelated source."""

EDITS = (
    ('            self._session_db.create_session(\n',
     '            from hermes_cli import nixhomeserver_worker_origin\n'
     '            self._session_db.create_session(\n'),
    ('origin_json=_gateway_origin_json(self), parent_session_id=self._parent_session_id,',
     'origin_json=nixhomeserver_worker_origin.session_origin(self, _gateway_origin_json(self)), '
     'parent_session_id=self._parent_session_id,'),
)


def adapt(text):
    for before, after in EDITS:
        if text.count(after) == 1:
            continue
        if text.count(before) != 1:
            raise ValueError('Native worker-origin adapter source drift; reconcile before installation')
        text = text.replace(before, after, 1)
    compile(text, 'run_agent.py', 'exec')
    return text


LOCAL_BEFORE = '        if not _IS_WINDOWS:\n            with contextlib.suppress(ProcessLookupError):\n'
LOCAL_AFTER = ('        from hermes_cli import nixhomeserver_worker_origin\n'
               '        nixhomeserver_worker_origin.record_launch(proc)\n' + LOCAL_BEFORE)


def adapt_local(text):
    # Replace only the reviewed local terminal Popen seam. The helper publishes
    # both negative terminal proof and existing worker/delegate receipts BEFORE
    # releasing the shell. Migrate the earlier post-launch-only seam explicitly.
    text = text.replace(LOCAL_AFTER, LOCAL_BEFORE)
    before = '        proc = subprocess.Popen(\n            args, text=True, env=_make_run_env(self.env), encoding="utf-8", errors="replace",'
    after = ('        from hermes_cli import nixhomeserver_worker_origin\n'
             '        proc = nixhomeserver_worker_origin.popen_terminal(\n'
             '            args, text=True, env=_make_run_env(self.env), encoding="utf-8", errors="replace",')
    if text.count(after) == 1 and text.count(before) == 0 and text.count(LOCAL_BEFORE) == 1:
        compile(text, 'tools/environments/local.py', 'exec')
        return text
    if text.count(before) != 1 or text.count(LOCAL_BEFORE) != 1:
        raise ValueError('Native terminal launch adapter source drift; reconcile before installation')
    text = text.replace(before, after, 1)
    compile(text, 'tools/environments/local.py', 'exec')
    return text
