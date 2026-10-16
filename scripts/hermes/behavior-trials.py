#!/usr/bin/env python3
"""Opt-in model trials using Hermes AIAgent with inert fixture tool execution.

Reuses the isolated-agent pattern in Hermes evals/tool_search/tool_search_livetest.py.
Credentials are resolved normally in memory; no auth files are copied to scratch.
Python is glue for the existing Python runtime, not a new service/backend.
"""
import argparse
import contextlib
import hashlib
import io
import json
import os
import re
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time
import traceback

sys.path.insert(0, str(Path(__file__).resolve().parent))
from behavior_fixtures import CASES, Fixture, TOOLS

SOURCE = Path(__file__).resolve().parent
REPO = SOURCE.parents[1]
ROLES = {'head-coordinator': 'coordinator-role.md',
         'standard-implementer': 'standard-implementer.md',
         'feature-reviewer': 'feature-reviewer.md'}
DOCS = {'hermes-card-authoring.md': REPO / 'documentation/hermes-card-authoring.md',
        'hermes-skill-routing.md': SOURCE / 'instructions/skill-routing.md',
        'hermes-fleet-policy.md': SOURCE / 'taskforce/owner-blocker-authoring.md',
        'hermes-coordinator-reference.md': SOURCE / 'instructions/coordinator-reference.md',
        'hermes-owner-alerts.md': REPO / 'documentation/hermes-owner-alerts.md'}


def worker(args):
    """One fresh process per case: live provider resolution, then isolated runtime."""
    role, skills, _ = CASES[args.worker]
    profile = args.root / 'profiles' / role
    runtime_profile = args.runtime_profile or role
    os.environ['HERMES_HOME'] = str(args.root / 'profiles' / runtime_profile)
    sys.path.insert(0, str(args.hermes_repo))
    # Capture runtime diagnostics, which may contain provider payloads. Never
    # save/print these or exception messages; the report contains synthetic data.
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        # Hermes may relaunch into its managed dependency environment. Bootstrap
        # before third-party imports so the relaunched runner also activates it.
        import hermes_bootstrap  # noqa: F401
        from hermes_cli.env_loader import load_hermes_dotenv
        load_hermes_dotenv()
        from hermes_cli.config import load_config_readonly
        from hermes_cli.runtime_provider import resolve_runtime_provider
        config = load_config_readonly()
        from hermes_constants import resolve_reasoning_config
        reasoning = resolve_reasoning_config(config, config['model']['default'])
        from hermes_yaml import safe_load
        role_config = safe_load((profile / 'config.yaml').read_text())
        model = config['model']
        runtime = resolve_runtime_provider(requested=model['provider'], target_model=model['default'])
        if runtime.get('api_mode') not in ('chat_completions', 'codex_responses', 'anthropic_messages'):
            raise ValueError('unsupported fixture provider transport')
        home = args.scratch / 'home'
        home.mkdir(parents=True)
        # Only non-secret, bounded settings enter the isolated home. No live
        # plugins, hooks, memory, connectors, fallbacks, jobs or board are copied.
        (home / 'config.yaml').write_text(json.dumps({
            'model': {'default': model['default'], 'provider': runtime['provider']},
            'skills': {'disabled': role_config.get('skills', {}).get('disabled', [])},
            'tools': {'tool_search': {'enabled': 'off'}},
            'logging': {'level': 'ERROR'},
        }))
        role_paths = [SOURCE / 'taskforce/owner-blocker-authoring.md', SOURCE / 'taskforce' / ROLES[role]]
        if role == 'head-coordinator':
            role_paths.append(SOURCE / 'taskforce/coordinator-operations.md')
        snapshots = {}
        def policy_text(path):
            if path not in snapshots:
                snapshots[path] = path.read_text()
            return snapshots[path]
        for skill in skills:
            if skill == 'systematic-debugging':
                origin = SOURCE / 'instructions/systematic-debugging.md'
            elif skill == 'kanban-orchestration':
                origin = SOURCE / 'instructions/kanban-orchestration.md'
            else:
                matches = list((profile / 'skills').glob(f'**/{skill}/SKILL.md'))
                if len(matches) != 1:
                    raise ValueError('required skill missing or ambiguous')
                origin = matches[0]
            target = home / 'skills' / skill / 'SKILL.md'
            target.parent.mkdir(parents=True)
            target.write_text(policy_text(origin))

        # Match upstream eval isolation: discard home-bound module caches before
        # constructing the agent. Credentials stay in runtime, never a file.
        os.environ['HERMES_HOME'] = str(home)
        for name in list(sys.modules):
            if name.startswith(('hermes_cli', 'hermes_constants', 'agent.', 'tools.', 'model_tools', 'toolsets')):
                del sys.modules[name]
        os.chdir(args.scratch)
        from unittest.mock import patch
        from hermes_cli import kanban_db as kb, kanban_db_dispatch as dispatch
        from hermes_cli.kanban_db_connect import connect
        # Exercise the real persisted field and dispatcher argv without starting
        # a worker or selecting a live/current board.
        conn = connect(args.scratch / 'native-board.db')
        try:
            tid = kb.create_task(conn, title='Isolated task skill round trip',
                                 assignee=role, workspace_kind='dir',
                                 workspace_path=str(args.scratch), skills=skills)
            task = kb.get_task(conn, tid)
            if list(task.skills or []) != skills:
                raise ValueError('native skill persistence mismatch')
            with patch.object(dispatch, '_resolve_hermes_argv', return_value=['hermes']), \
                 patch.object(dispatch, '_resolve_worker_cli_toolsets', return_value=[]):
                argv = dispatch._worker_argv(task, role, str(home))
            dispatched = [argv[i + 1] for i, value in enumerate(argv) if value == '--skills']
            if dispatched != skills or conn.execute('PRAGMA integrity_check').fetchone()[0] != 'ok':
                raise ValueError('native skill dispatch mismatch')
        finally:
            conn.close()
        from agent.skill_commands import build_preloaded_skills_prompt
        preload, loaded, missing = build_preloaded_skills_prompt(dispatched)
        if missing:
            raise ValueError('required preload did not resolve')
        instructions = {}
        for name, path in DOCS.items():
            for alias in (f'~/.hermes/scripts/{name}', str(args.root / 'scripts' / name), name):
                instructions[alias] = policy_text(path)
        for name, filename in ROLES.items():
            path = SOURCE / 'taskforce' / filename
            for base in ('~/.hermes', str(args.root), str(home)):
                instructions[f'{base}/profiles/{name}/SOUL.md'] = policy_text(path)
        fixture = Fixture(args.worker, instructions, scratch=args.scratch)
        role_text = '\n\n'.join(policy_text(p) for p in role_paths)
        system = (role_text + '\n\n' + policy_text(DOCS['hermes-skill-routing.md']) + '\n\n' + preload
                  + '\n\nThis isolated trial uses assigned fixture tools. All board actions '
                    'are scoped to the fixture board; your task is t_trial. Source paths '
                    'are relative to the fixture workspace. No terminal, network, messaging '
                    'or publication tool is available. Use the provided lifecycle tools '
                    'to record actual outcomes. Other instructions are available through read_file.')
        import model_tools
        from run_agent import AIAgent

        class FixtureAgent(AIAgent):
            # Replace the complete tool-execution boundary, including inline and
            # parallel tools. There is deliberately no fallback to real dispatch.
            def _execute_tool_calls(self, assistant_message, messages, effective_task_id, api_call_count=0):
                for call in assistant_message.tool_calls:
                    try:
                        arguments = json.loads(call.function.arguments)
                        if not isinstance(arguments, dict):
                            raise ValueError('tool arguments must be an object')
                        result = fixture.call(call.function.name, arguments)
                    except (ValueError, TypeError):
                        result = fixture.call('invalid_tool_arguments', {})
                    messages.append({'role': 'tool', 'tool_call_id': call.id,
                                     'name': call.function.name, 'content': json.dumps(result)})

        with patch.object(model_tools, 'get_tool_definitions', return_value=TOOLS):
            agent = FixtureAgent(
                provider=runtime['provider'], model=runtime.get('model') or model['default'],
                api_key=runtime.get('api_key'), base_url=runtime.get('base_url'),
                requested_provider=runtime.get('requested_provider'),
                api_mode=runtime.get('api_mode'), quiet_mode=True, save_trajectories=False,
                skip_context_files=True, skip_memory=True, skip_background_review=True,
                load_soul_identity=False, checkpoints_enabled=False, platform='cli',
                max_iterations=args.max_turns, run_budget_seconds=args.timeout - 15,
                max_tokens=8192, reasoning_config=reasoning,
                request_overrides=runtime.get('request_overrides'),
                fallback_model=None, cwd=str(args.scratch),
            )
            result = agent.run_conversation(user_message=fixture.prompt, system_message=system)
        report = {'case': args.worker, 'role': role, 'model': agent.model,
                  'provider': runtime['provider'], 'runtime_profile': runtime_profile,
                  'reasoning': reasoning,
                  'loaded_skills': loaded,
                  'native_skill_round_trip': True,
                  'policy_sha256': {str(p.relative_to(REPO)) if p.is_relative_to(REPO)
                                    else str(p.relative_to(args.root)):
                                    hashlib.sha256(content.encode()).hexdigest()
                                    for p, content in snapshots.items()},
                  'failures': fixture.failures(),
                  'actions': [{'tool': n, 'arguments': {k: v for k, v in a.items() if k != 'content'},
                               'exit_code': r.get('exit_code'), 'error': r.get('error')}
                              for n, a, r in fixture.events],
                  'final_response': (result.get('final_response', '') if isinstance(result, dict) else str(result))[:4000]}
        report['status'] = 'pass' if not report['failures'] else 'fail'
        if isinstance(result, dict) and (result.get('failed') or result.get('error')):
            report.update(status='error', error_type='AgentRunFailed')
        from agent.redact import redact_sensitive_text
        cleaned = redact_sensitive_text(json.dumps(report), force=True)
        key = runtime.get('api_key')
        if isinstance(key, str) and len(key) > 8:
            cleaned = cleaned.replace(key, '[REDACTED]')
        return json.loads(cleaned)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--live', action='store_true', help='Make bounded model calls using configured role providers.')
    parser.add_argument('--case', action='append', choices=Fixture.names(), help='Default: all six cases.')
    parser.add_argument('--hermes-repo', type=Path, default=Path.home() / '.hermes/hermes-agent')
    parser.add_argument('--root', type=Path, default=Path.home() / '.hermes')
    parser.add_argument('--runtime-profile', choices=ROLES,
                        help='Explicit trial-only provider/model source; default is the scenario role. '
                             'Does not change live profile settings or reassign work.')
    parser.add_argument('--timeout', type=int, default=180, help='Hard seconds per case, 30..600 (default 180).')
    parser.add_argument('--max-turns', type=int, default=12, help='Maximum model iterations per case, 1..30.')
    parser.add_argument('--output', type=Path, help='Optional synthetic JSON report. Never contains credentials.')
    parser.add_argument('--worker', choices=Fixture.names(), help=argparse.SUPPRESS)
    parser.add_argument('--scratch', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if (args.live or args.worker) and any(os.environ.get(k) for k in ('HERMES_KANBAN_TASK', 'HERMES_KANBAN_RUN_ID',
                                      'HERMES_KANBAN_CLAIM_LOCK', 'HERMES_DELEGATED_CHILD_CONTEXT')):
        parser.error('live trials require the interactive operator; worker/delegation pins remain binding')
    if not 30 <= args.timeout <= 600 or not 1 <= args.max_turns <= 30:
        parser.error('timeout or max-turns outside bounds')
    if args.worker:
        try:
            print(json.dumps(worker(args)))
        except (Exception, SystemExit) as exc:
            report = {'case': args.worker, 'status': 'error', 'error_type': type(exc).__name__,
                      'trace_locations': [[frame.filename, frame.lineno]
                                          for frame in traceback.extract_tb(exc.__traceback__)]}
            if isinstance(exc, ModuleNotFoundError) and re.fullmatch(r'[\w.]+', exc.name or ''):
                report['missing_module'] = exc.name
            print(json.dumps(report))
        return 0
    if not args.live:
        print('\n'.join(Fixture.names()))
        return 0
    python = args.hermes_repo / '.venv/bin/python'
    if not python.is_file() or not shutil.which('rustc'):
        parser.error('installed Hermes venv and rustc are required')
    reports = []
    with tempfile.TemporaryDirectory(prefix='nixhomeserver-hermes-behavior-') as tmp:
        for case in args.case or Fixture.names():
            scratch = Path(tmp) / case
            scratch.mkdir()
            command = [str(python), '-B', str(Path(__file__).resolve()), '--worker', case,
                       '--scratch', str(scratch), '--root', str(args.root.resolve()),
                       '--hermes-repo', str(args.hermes_repo.resolve()),
                       '--timeout', str(args.timeout), '--max-turns', str(args.max_turns)]
            if args.runtime_profile:
                command.extend(['--runtime-profile', args.runtime_profile])
            start = time.monotonic()
            try:
                run = subprocess.run(command, capture_output=True, text=True, timeout=args.timeout)
                report = json.loads(run.stdout) if run.returncode == 0 else {'case': case, 'status': 'error',
                                                                          'error_type': 'WorkerExit',
                                                                          'exit_code': run.returncode,
                                                                          'stderr_bytes': len(run.stderr),
                                                                          'trace_locations': re.findall(r'File "([^"\n]+)", line (\d+)', run.stderr),
                                                                          'exception_types': re.findall(r'^([\w.]+(?:Error|Exception)):', run.stderr, re.M)}
            except subprocess.TimeoutExpired:
                report = {'case': case, 'status': 'error', 'error_type': 'TimeoutExpired'}
            except json.JSONDecodeError:
                report = {'case': case, 'status': 'error', 'error_type': 'InvalidWorkerReport'}
            report['seconds'] = round(time.monotonic() - start, 2)
            reports.append(report)
            detail = '; '.join(report.get('failures', [])) or report.get('error_type', '')
            print(f'{case}: {report["status"]} ({report["seconds"]}s) {detail}', file=sys.stderr, flush=True)
    revision = subprocess.run(['git', '-C', str(args.hermes_repo), 'rev-parse', 'HEAD'],
                              capture_output=True, text=True, check=True).stdout.strip()
    output = json.dumps({'hermes_revision': revision, 'results': reports}, indent=2) + '\n'
    if args.output:
        args.output.write_text(output)
    else:
        print(output, end='')
    return 0 if all(r['status'] == 'pass' for r in reports) else 1


if __name__ == '__main__':
    sys.exit(main())
