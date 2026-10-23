"""Inert execution prerequisites for the existing native dispatch policy.

Uses Hermes' isolated, leased dependency inspection. Required modules are
looked up without importing card-supplied code. No tool is enabled by a check.
"""
import json
import os
from pathlib import Path
import subprocess
import sys

if __package__ == 'hermes_cli':
    from .nixhomeserver_fleet_contract import load
else:
    from fleet_contract import load


def capabilities(root, profile, workspace, imports):
    from hermes_cli.nixhomeserver_coordinator_repair import CATALOG_PROGRAM
    # Reuse passive installed-generation selection, replacing only its fixed
    # result expression. No arbitrary import expression or shell is executed.
    program = CATALOG_PROGRAM.replace(
        "print(json.dumps([s['name'] for s in skills._find_all_skills()]))",
        """import importlib.util
from hermes_cli.config import load_config
from hermes_cli.tools_config import _get_platform_tools
from model_tools import _select_tool_names
cfg=load_config()
enabled=sorted(set(_get_platform_tools(cfg,'cli')) | {'kanban'})
disabled=cfg.get('agent',{}).get('disabled_toolsets',[])
names=_select_tool_names(enabled,disabled,True)
required=json.loads(sys.argv[2])
print(json.dumps({'tools':sorted(names),'imports':{
    name: importlib.util.find_spec(name) is not None for name in required}}))""")
    if program == CATALOG_PROGRAM:
        raise ValueError('Installed dependency inspection contract changed')
    home = root / 'profiles' / profile
    if home.is_symlink() or not home.is_dir():
        raise ValueError('Assigned profile is not installed')
    native = root / 'hermes-agent'
    env = dict(os.environ, HERMES_HOME=str(home), TERMINAL_CWD=str(workspace), PYTHONDONTWRITEBYTECODE='1')
    result = subprocess.run([sys.executable, '-I', '-B', '-c', program, str(native), json.dumps(imports)],
                            cwd=workspace, env=env, capture_output=True, text=True, timeout=20)
    if result.returncode or len(result.stdout) > 1000000:
        raise ValueError('Installed interpreter/tool catalog unavailable')
    value = json.loads(result.stdout)
    if not isinstance(value, dict) or not isinstance(value.get('tools'), list) or not isinstance(value.get('imports'), dict):
        raise ValueError('Invalid execution catalog')
    return value


def reason(db, task_id, root, profile):
    contract = load(db, task_id)
    if contract is None:
        return None
    task = db.execute('SELECT * FROM tasks WHERE id=?', (task_id,)).fetchone()
    if not task:
        return None
    declared = contract.get('requirements', {})
    review_phase = profile in {'feature-reviewer', 'project-auditor'} and contract.get('review')
    required = declared.get('review', {}) if review_phase else declared
    path = Path(task['workspace_path']) if task['workspace_path'] else None
    # Native worktree provisioning occurs after claim. Recheck at the existing
    # post-preparation seam before spawn, when the actual path is persisted.
    pending = task['workspace_kind'] in {'worktree', 'scratch'} and (path is None or not path.exists()) and task['status'] != 'running'
    if path is None or not path.is_dir():
        if pending:
            return None
        return 'Worker preflight: missing assigned workspace. Input supplier: agent.'
    if not path.is_absolute() or path.resolve() != path:
        return 'Worker preflight: assigned workspace must be an existing canonical directory. Input supplier: agent.'
    try:
        if required.get('tools') or required.get('imports'):
            found = capabilities(root, profile, path, required.get('imports', []))
            missing = set(required.get('tools', [])) - set(found['tools'])
            absent = [name for name in required.get('imports', []) if found['imports'].get(name) is not True]
            if missing or absent:
                return ('Worker preflight: unavailable configured tools=' + ','.join(sorted(missing))
                        + ' modules=' + ','.join(absent) + '. Repair existing profile/runtime; no tool grant. Input supplier: agent.')
        revision = declared.get('source_revision')
        if revision and review_phase:
            if __package__ == 'hermes_cli':
                from .nixhomeserver_fleet_workflow import review_handoff
            else:
                from fleet_workflow import review_handoff
            revision = review_handoff(db, task_id)['metadata']['revision']
            exact = True
        else:
            exact = False
        if revision:
            environment = dict(os.environ, GIT_OPTIONAL_LOCKS='0', GIT_TERMINAL_PROMPT='0')
            for key in ('GIT_DIR', 'GIT_WORK_TREE', 'GIT_COMMON_DIR'):
                environment.pop(key, None)
            probe = subprocess.run(['git', '--no-optional-locks', '-C', str(path), 'rev-parse', '--show-toplevel', 'HEAD'],
                                   env=environment, capture_output=True, text=True, timeout=2)
            lines = probe.stdout.splitlines()
            if probe.returncode or len(lines) != 2 or Path(lines[0]) != path:
                return 'Worker preflight: assigned source is not a repository root. Input supplier: agent.'
            if exact:
                valid = lines[1] == revision
            else:
                valid = subprocess.run(['git', '--no-optional-locks', '-C', str(path), 'merge-base',
                                        '--is-ancestor', revision, 'HEAD'], env=environment,
                                       capture_output=True, timeout=2).returncode == 0
            if not valid:
                return 'Worker preflight: source does not match this execution phase. Input supplier: agent.'
        # Repair does not require another model permission grant. A broken
        # installed recovery seam is a prerequisite defect, never an owner ask.
        for name in ('nixhomeserver_resume_recovered.py', 'nixhomeserver_coordinator_repair.py'):
            if not (root / 'hermes-agent/hermes_cli' / name).is_file():
                return 'Worker preflight: maintained coordinator recovery path is unavailable. Input supplier: agent.'
    except (ImportError, OSError, ValueError, TypeError, KeyError, subprocess.TimeoutExpired):
        return 'Worker preflight: prerequisite inspection unavailable; repair the existing runtime. Input supplier: agent.'
    return None
