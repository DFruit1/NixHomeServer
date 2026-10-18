"""Small exact-anchor adapter for the installed Hermes cron execution seams."""

HEADER='    from cron import nixhomeserver_cron_policy as _inspection_policy\n'
EDITS={
    'cron/scheduler.py':(
        ('def run_job(\n',
         'def run_job(job: dict, **kwargs):\n'+HEADER+
         '    return _inspection_policy.run(_nixhomeserver_run_job, job, **kwargs)\n\n\n'
         'def _nixhomeserver_run_job(\n'),
        ('    def _abort_if_fire_claim_lost() -> None:\n',
         '    def _abort_if_fire_claim_lost() -> None:\n'
         '        from cron import nixhomeserver_cron_policy as _inspection_policy\n'
         '        _inspection_policy.enforce_deadline(agent)\n'),
        ('    pr = _cfg.get("provider_routing") or {}\n    return AIAgent(\n',
         '    pr = _cfg.get("provider_routing") or {}\n'+HEADER+'    agent = AIAgent(\n'),
        ('        max_iterations=setup.max_iterations,\n',
         '        **_inspection_policy.agent_kwargs(job, setup.max_iterations),\n'),
        ('        session_db=session_db,\n    )\n\n\nclass _FireAudit:',
         '        session_db=session_db,\n    )\n'
         '    return _inspection_policy.bind(agent, job)\n\n\nclass _FireAudit:'),
        ('        final_response = _final_response_from_result(result, job_id, job_name, AIAgent)\n',
         '        from cron import nixhomeserver_cron_policy as _inspection_policy\n'
         '        _inspection_policy.note_result(agent, result)\n'
         '        final_response = _final_response_from_result(result, job_id, job_name, AIAgent)\n'),
    ),
    'agent/tool_executor.py':(
        ('    hook-modified args applied. Hook failures never block."""\n    try:\n',
         '    hook-modified args applied. Hook failures never block."""\n'+HEADER+
         '    if budget_block := _inspection_policy.tool_block(agent, ref.call_id):\n'
         '        return budget_block, ref.args\n    try:\n'),
    ),
}


def adapt(name,text):
    for before,after in EDITS[name]:
        if text.count(after)==1:continue
        if text.count(before)!=1:raise ValueError('Native cron adapter source drift; reconcile before installing')
        text=text.replace(before,after,1)
    compile(text,name,'exec')
    return text
