#!/usr/bin/env python3
"""Compare native background-review budgets using synthetic, inert learning tools.

Python glue exercises Hermes' actual fork and budget checks. No live memory,
skills, boards, plugins or messages are exposed; credentials remain in memory.
"""
import argparse
import contextlib
import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE))


def worker(args):
    os.environ['HERMES_HOME'] = str(args.root / 'profiles/head-coordinator')
    sys.path.insert(0, str(args.hermes_repo))
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        import hermes_bootstrap  # noqa: F401
        from hermes_cli.env_loader import load_hermes_dotenv
        load_hermes_dotenv()
        from hermes_cli.config import load_config_readonly
        from hermes_cli.runtime_provider import resolve_runtime_provider
        from hermes_constants import resolve_reasoning_config
        config=load_config_readonly()
        fallback=config['fallback_providers'][0]
        reasoning=resolve_reasoning_config(config,fallback['model'])
        runtime=resolve_runtime_provider(requested=fallback['provider'],target_model=fallback['model'])
        home=args.scratch/'home';home.mkdir()
        (home/'config.yaml').write_text(json.dumps({
            'model':{'default':fallback['model'],'provider':runtime['provider']},
            'tools':{'tool_search':{'enabled':'off'}},'logging':{'level':'ERROR'},
            'auxiliary':{'title_generation':{'model_upgrade_enabled':False}},
        }))
        os.environ['HERMES_HOME']=str(home)
        for name in list(sys.modules):
            if name.startswith(('hermes_cli','hermes_constants','agent.','tools.','model_tools','toolsets')):
                del sys.modules[name]
        os.chdir(args.scratch)
        from unittest.mock import patch
        import model_tools
        import run_agent
        from agent import background_review as review
        from behavior_fixtures import schema, TEXT
        definitions=[
            schema('memory','Save a durable user preference. This fixture supports add only.',
                   {'action':TEXT,'target':TEXT,'content':TEXT},['action','target','content']),
            schema('skills_list','List existing reusable procedures.',{}),
            schema('skill_view','Read an existing skill.',{'name':TEXT},['name']),
            schema('skill_manage','Create a reusable skill. Fixture supports create only.',
                   {'action':TEXT,'name':TEXT,'content':TEXT},['action','name','content']),
        ]
        actions=[]

        class FixtureAgent(run_agent.AIAgent):
            def __init__(self,**kwargs):
                kwargs.update(skip_context_files=True,skip_memory=True,skip_background_review=True,
                              load_soul_identity=False,checkpoints_enabled=False,save_trajectories=False,
                              run_budget_seconds=150,cwd=str(args.scratch),fallback_model=None)
                super().__init__(**kwargs)

            def _execute_tool_calls(self,message,messages,effective_task_id,api_call_count=0):
                for call in message.tool_calls:
                    name=call.function.name
                    try:arguments=json.loads(call.function.arguments)
                    except (TypeError,ValueError):arguments={}
                    allowed=(name=='skills_list' or
                             name=='memory' and arguments.get('action')=='add' or
                             name=='skill_manage' and arguments.get('action')=='create')
                    result={'success':True,'skills':[]} if allowed else {'error':'Unavailable fixture operation; do not retry'}
                    actions.append({'tool':name,'arguments':arguments,'success':allowed})
                    messages.append({'role':'tool','tool_call_id':call.id,'name':name,'content':json.dumps(result)})

        history=[]
        # Synthetic repetition tests a longer history without exposing real
        # conversations. Cache/cost differences here are not production estimates.
        length={'memory':4,'skill':100,'large-skill':180}[args.worker]
        for index in range(length):
            history.extend([{'role':'user','content':f'Temporary probe {index}: '+
                             'The fixture build completed; transient job identifiers and timings are not durable knowledge. '*20},
                            {'role':'assistant','content':'Recorded for this task only. No standing preference changed.'}])
        if args.worker=='memory':
            history.extend([{'role':'user','content':'Remember my standing preferences: always report temperatures in Celsius, and report missing telemetry as unknown rather than zero.'},
                            {'role':'assistant','content':'I will use those preferences in future reports.'}])
            prompt=review._MEMORY_REVIEW_PROMPT
        else:
            history.extend([{'role':'user','content':'The reusable lesson from our expiry fix is to run the failing boundary test BEFORE editing, then make the smallest fix, run the passing test, and preserve unrelated notes. Save that procedure as a skill for future bug fixes.'},
                            {'role':'assistant','content':'The failing expiry boundary was reproduced before editing; the focused test passed after the minimal fix and unrelated notes were preserved.'}])
            prompt=review._SKILL_REVIEW_PROMPT
        with patch.object(model_tools,'get_tool_definitions',return_value=definitions), \
             patch.object(run_agent,'AIAgent',FixtureAgent):
            parent=FixtureAgent(provider=runtime['provider'],model=runtime.get('model') or fallback['model'],
                api_key=runtime.get('api_key'),base_url=runtime.get('base_url'),
                requested_provider=runtime.get('requested_provider'),api_mode=runtime.get('api_mode'),
                request_overrides=runtime.get('request_overrides'),reasoning_config=reasoning,
                quiet_mode=True,platform='cli',max_iterations=16,max_tokens=4096)
            parent._cached_system_prompt='You are an assistant maintaining concise, durable memories and reusable skills. Never save transient task identifiers.'
            parent._memory_enabled=True
            parent._user_profile_enabled=False
            parent._session_db=None
            task={'max_input_tokens':args.budget} if args.budget else {}
            fork,_,routed=review.build_cache_parity_fork(parent,task,max_iterations=16)
            result=fork.run_conversation(user_message=prompt,conversation_history=history)
            usage=review._snapshot_review_usage(fork)
            effective_budget=fork._review_input_token_budget
            fork.release_clients();parent.release_clients()
        saved=' '.join(str(a['arguments'].get('content','')).lower() for a in actions if a['success'])
        if args.worker=='memory':
            retained=('celsius' in saved and 'unknown' in saved and 'zero' in saved
                      and any(a['tool']=='memory' and a['success'] for a in actions))
        else:
            retained=('before' in saved and 'test' in saved and 'preserv' in saved
                      and any(a['tool']=='skill_manage' and a['success'] for a in actions))
        forbidden=any(not a['success'] for a in actions)
        failed=isinstance(result,dict) and bool(result.get('failed') or result.get('error'))
        report={'status':'pass' if retained and not forbidden and not failed else 'fail',
                'model':parent.model,'reasoning':reasoning,'runtime_route':'configured_coordinator_fallback',
                'effective_budget':effective_budget,'native_fork':True,'routed':routed,
                'retained_lesson':retained,'denied_operations':sum(not a['success'] for a in actions),
                'usage':{k:v for k,v in usage.items() if k not in ('base_url','estimated_cost_usd')},
                'actions':actions}
        from agent.redact import redact_sensitive_text
        cleaned=redact_sensitive_text(json.dumps(report),force=True)
        key=runtime.get('api_key')
        if isinstance(key,str) and len(key)>8:cleaned=cleaned.replace(key,'[REDACTED]')
        return json.loads(cleaned)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true')
    parser.add_argument('--root', type=Path, default=Path.home()/'.hermes')
    parser.add_argument('--hermes-repo', type=Path, default=Path.home()/'.hermes/hermes-agent')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--case',action='append',choices=('memory','skill','large-skill'))
    parser.add_argument('--worker', choices=('memory', 'skill','large-skill'), help=argparse.SUPPRESS)
    parser.add_argument('--budget', type=int, default=0, help=argparse.SUPPRESS)
    parser.add_argument('--scratch', type=Path, help=argparse.SUPPRESS)
    args=parser.parse_args()
    if any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK', 'HERMES_KANBAN_RUN_ID',
                                      'HERMES_DELEGATED_CHILD_CONTEXT', 'HERMES_KANBAN_CLAIM_LOCK')):
        parser.error('Learning trials require the interactive operator; worker pins remain binding')
    if args.worker:
        try:
            result=worker(args)
        except (Exception,SystemExit) as exc:
            import traceback
            result={'case':args.worker,'budget':args.budget,'status':'error','error_type':type(exc).__name__,
                    'locations':[[Path(f.filename).name,f.lineno] for f in traceback.extract_tb(exc.__traceback__)]}
        print(json.dumps(result))
        return 0
    if not args.live:
        print('Opt in with --live: native default versus 48,000 aggregate input tokens; memory and skill fixtures.')
        return 0
    reports=[]
    with tempfile.TemporaryDirectory(prefix='hermes-learning-trial-') as directory:
        for case in args.case or ('memory','skill','large-skill'):
            for budget in (0,48000):
                scratch=Path(directory)/f'{case}-{budget}';scratch.mkdir()
                command=[str(args.hermes_repo/'.venv/bin/python'),'-B',str(Path(__file__).resolve()),
                         '--worker',case,'--budget',str(budget),'--scratch',str(scratch),
                         '--root',str(args.root.resolve()),'--hermes-repo',str(args.hermes_repo.resolve())]
                start=time.monotonic()
                try:
                    run=subprocess.run(command,capture_output=True,text=True,timeout=180)
                    report=json.loads(run.stdout) if run.returncode==0 else {'status':'error','error_type':'WorkerExit'}
                except (subprocess.TimeoutExpired,ValueError):
                    report={'status':'error','error_type':'TimeoutOrInvalidReport'}
                report.update(case=case,budget=budget,elapsed_seconds=round(time.monotonic()-start,2))
                reports.append(report)
                print(json.dumps(report),flush=True)
    if args.output:args.output.write_text(json.dumps(reports,indent=2)+'\n')
    return int(any(r['status']!='pass' for r in reports))


if __name__=='__main__':
    sys.exit(main())
