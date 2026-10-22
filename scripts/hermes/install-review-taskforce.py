#!/usr/bin/env python3
"""Install fleet instructions and the owner-approved global cap; preserve model settings."""
import argparse
import importlib.util
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys

import hermes_common

SOURCE = Path(__file__).resolve().parent
sys.path.insert(0, str(SOURCE))
from hermes_config import platform_tools
MARKER = '<!-- hermes-review-taskforce -->'
END_MARKER = '<!-- /hermes-review-taskforce -->'
JOB_NAME = 'kanban review taskforce'
GLOBAL_WORKER_LIMIT = 4
DESCRIPTIONS = {
    'project-auditor': 'PROJECT AUDITOR AND TASKFORCE LEAD. Sole owner of each board\'s persisted FINDINGS.md and immutable batch plans. Commissions focused adversarial audits of idle existing features from feature-reviewer, assesses their evidence, batches worthwhile proposals, immediately escalates urgent credible security/regression findings, and hands approved plans to head-coordinator. Routes diff and deploy-range verification to feature-reviewer; it does not verify work itself. Never implements or deploys.',
    'feature-reviewer': 'FEATURE-REVIEWER, THE VERIFIER LANE. Judges finished work against its acceptance criteria: per-card diffs, bounded technical questions and whole-change-set deploy reviews, returning accept or request-changes. Also audits idle existing features when project-auditor commissions one, and reports those findings to project-auditor. Never implements, edits FINDINGS.md or batch plans, or deploys.',
    'head-coordinator': 'HEAD COORDINATOR. Routes and decomposes implementation; never implements. Sends diff, question and whole-set deploy reviews to feature-reviewer, and scoped audit/planning requests to project-auditor, which exclusively manages feature-reviewer audits and the continuous improvement findings. Decomposes approved immutable plans into implementer, review and composition cards; keeps the handoff dependency-blocked until the work finishes. Routes only unavoidable actual credential handling locally; preserves board health and whole-set guarded deploy gate. The owner uses T3 Code for manual large-model consultation.',
    'local-implementer': 'LOCAL IMPLEMENTER. Only the smallest bounded step requiring actual passwords, API keys, tokens, private keys or equivalent credentials. Explicit secret boundary and runtime cap required. Surrounding source, mocks, tests and composition use standard-implementer. Private data, paths and telemetry alone do not qualify. Never send credentials to remote models or tools.',
}


def worker_cap(text):
    """Set only kanban.max_in_progress, retaining nested caps and all other YAML."""
    blocks = list(re.finditer(r'^kanban:[ \t]*\n.*?(?=^[^\s#]|\Z)', text, re.M | re.S))
    if not blocks:
        if re.search(r'^kanban:', text, re.M):
            raise ValueError('Expected block YAML for kanban settings')
        return text.rstrip() + f'\n\nkanban:\n  max_in_progress: {GLOBAL_WORKER_LIMIT}\n'
    if len(blocks) != 1:
        raise ValueError('Duplicate kanban settings')
    block = blocks[0]
    current = block[0]
    rows = re.findall(r'^  max_in_progress:[^\n]*', current, re.M)
    if len(rows) > 1:
        raise ValueError('Duplicate global worker cap')
    if rows:
        updated, count = re.subn(r'^(  max_in_progress:[ \t]*)[0-9]+([ \t]*(?:#.*)?)$',
                                 lambda m: m[1] + str(GLOBAL_WORKER_LIMIT) + m[2], current, flags=re.M)
        if count != 1:
            raise ValueError('Expected an integer global worker cap')
    else:
        updated = current.replace('\n', f'\n  max_in_progress: {GLOBAL_WORKER_LIMIT}\n', 1)
    return text[:block.start()] + updated + text[block.end():]


def policy(existing, template, start=0, end=None, legacy_heading=None):
    """Replace our bounded policy, migrating legacy files without owning their tail."""
    block = MARKER + '\n' + template.rstrip() + '\n' + END_MARKER + '\n'
    if MARKER in existing or END_MARKER in existing:
        if existing.count(MARKER) != 1 or existing.count(END_MARKER) > 1:
            raise ValueError('Invalid taskforce policy markers')
        start = existing.index(MARKER)
        if END_MARKER in existing:
            end = existing.index(END_MARKER)
            if end < start:
                raise ValueError('Reversed taskforce policy markers')
            end += len(END_MARKER)
            if existing[end:end + 1] == '\n':
                end += 1
            return existing[:start] + block + existing[end:]
    end = len(existing) if end is None else end
    # Old reviewer files owned the introduction and named sections; old auditor
    # files had only a start marker. Preserve the first independent section and
    # everything after it, rather than guessing that appended policy is ours.
    headings = set(re.findall(r'^## .+$', template, re.M))
    if legacy_heading:
        headings.add('## ' + legacy_heading)
    legacy = existing[start:end]
    for boundary in re.finditer(r'^## .+$|^<!-- [^/\n].* -->$', legacy, re.M):
        if boundary[0] != MARKER and boundary[0] not in headings:
            end = start + boundary.start()
            break
    suffix = existing[end:]
    return existing[:start] + block + ('\n' if suffix and not suffix.startswith('\n') else '') + suffix


def soul(name, existing):
    template = (SOURCE / 'taskforce' / f'{name}.md').read_text()
    if name in {'feature-reviewer', 'local-implementer'}:
        return policy(existing, template)
    if name == 'project-auditor':
        existing = existing.replace('- **Never leave your workspace.**',
            '- **Never leave your workspace**, except for the board taskforce documents\n'
            '  explicitly authorised below; never edit source under that exception.')
        if MARKER not in existing and END_MARKER not in existing:
            existing = existing.rstrip() + '\n\n'
            return policy(existing, template, start=len(existing))
        return policy(existing, template)
    heading = next((h for h in ('Review and improvement', 'Continuous improvement intake',
                               'Requesting an audit on demand') if '## ' + h + '\n' in existing),
                   'Requesting an audit on demand')
    if MARKER in existing or END_MARKER in existing:
        existing = policy(existing, template)
    else:
        sections = list(re.finditer(rf'^## {re.escape(heading)}\n.*?(?=^## |\Z)', existing, re.M | re.S))
        if len(sections) != 1:
            raise ValueError(f'Expected one policy section: {heading}')
        existing = policy(existing, template, sections[0].start(), sections[0].end(), heading)
    # The unused manual consultant was retired by the owner. Migrate its routing
    # prose, while retaining the plan contract and all independently owned policy.
    existing = re.sub(r'^## `principal-consultant` is not yours\n.*?(?=^## |\Z)',
                      '', existing, flags=re.M | re.S)
    existing = re.sub(r'^The rule underneath all four:.*?(?=^## |\Z)',
                      '', existing, flags=re.M | re.S)
    existing = existing.replace('dispatchable, so this is cheap next to the frontier lane.', 'dispatchable.')
    for old in ('A card from `principal-consultant` arrives with the plan attached.',
                'A card from `principal-consultant` or `project-auditor` arrives with the plan attached.'):
        existing = existing.replace(old, 'A card from `project-auditor` or the owner arrives with the plan attached.')
    existing = re.sub(r'^\| `local-implementer` \|.*$',
                      '| `local-implementer` | Only the smallest step requiring actual credential values; all surrounding work uses ordinary lanes. |',
                      existing, flags=re.M)
    existing = existing.replace(
        'One exception you do not route and must not "correct": the board steward files\n'
        'its own low-priority repo cleanup cards straight to `local-implementer`\n'
        '(tenant `steward-cleanup`, priority `-10`). Those are intentional — leave them\n'
        'alone, and never reassign one to `standard-implementer`.',
        'Legacy low-priority `steward-cleanup` cards may finish in their recorded lane\n'
        'only when direct credential handling is unavoidable; otherwise reassign them. The steward is read-only and cannot\n'
        'create new cleanup cards. Route ordinary new work to `standard-implementer`.')
    start = existing.find('- Give each child the slice it owns')
    end = existing.find('- Preserve the plan\'s structure:', start)
    if start >= 0 and end >= 0:
        existing = existing[:start] + (
            '- Give each child only its owned slice. Put the absolute plan path on the\n'
            '  parent handoff; children reference that parent instead of repeating the\n'
            '  specification. Keep Goal/Change/Verify and explicit acceptance criteria\n'
            '  within the card budget. Verify that the parent context reaches each child.\n') + existing[end:]
    return existing


def idle_recovery_prompt(text):
    start = '<!-- hermes-idle-recovery -->'
    end = '<!-- /hermes-idle-recovery -->'
    block = start + '\n' + (SOURCE / 'taskforce/idle-recovery-policy.md').read_text().rstrip() + '\n' + end
    if start in text or end in text:
        if text.count(start) != 1 or text.count(end) != 1 or text.index(end) < text.index(start):
            raise ValueError('Invalid idle recovery policy markers')
        text = re.sub(re.escape(start) + r'.*?' + re.escape(end), lambda _: block, text, flags=re.S)
    else:
        text = block + '\n\n' + text
    text = text.replace('bind its blocker notification before needs_input blocking, record the exact question/cause once,',
                        'author its checked owner-blocker summary before needs_input blocking, record the exact question/cause once,')
    return text


def changed_files(root, policy_only=False):
    default = root / 'SOUL.md'
    changes = {default: policy(default.read_text() if default.exists() else '',
                               (SOURCE / 'taskforce/default.md').read_text())}
    for name in DESCRIPTIONS:
        directory = root / 'profiles' / name
        path = directory / 'SOUL.md'
        changes[path] = soul(name, path.read_text())
        metadata = directory / 'profile.yaml'
        text = metadata.read_text()
        pattern = r'^description:.*?(?=^[A-Za-z_][A-Za-z_0-9]*:|\Z)'
        text, count = re.subn(pattern, lambda _: 'description: ' + json.dumps(DESCRIPTIONS[name]) + '\n',
                              text, flags=re.M | re.S)
        if count != 1:
            raise ValueError(f'Expected description in {metadata}')
        changes[metadata] = text
        if name in {'project-auditor', 'feature-reviewer', 'head-coordinator'}:
            config = directory / 'config.yaml'
            text = config.read_text()
            # Enable board tools for on-demand CLI/desktop conversations. Worker lifecycle
            # tools are still injected by Hermes; worker kanban_list stays hidden.
            for platform in ('cli', 'desktop'):
                text = platform_tools(text, platform, add=('kanban',), optional=platform == 'desktop')
            changes[config] = text
    # All live profiles must agree with the root's owner-approved global cap.
    # Per-profile limits and inference/model settings are separate and untouched.
    configs = [root / 'config.yaml', *sorted((root / 'profiles').glob('*/config.yaml'))]
    for config in configs:
        if config.exists() and (config == root / 'config.yaml' or not config.parent.name.startswith('.')):
            changes[config] = worker_cap(changes.get(config, config.read_text()))
    # Reuse the existing bounded hook editor; keep unrelated hooks verbatim.
    spec = importlib.util.spec_from_file_location('steward_installer', SOURCE / 'install-steward-readonly.py')
    hooks = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(hooks)
    for name in (*DESCRIPTIONS, 'standard-implementer'):
        config = root / 'profiles' / name / 'config.yaml'
        if config.exists():
            text = changes.get(config, config.read_text())
            command = 'python3 ' + shlex.quote(str(root / 'scripts/review-verdict-guard.py'))
            changes[config] = hooks.readonly_hook(text, command, 'review-verdict', '^kanban_(complete|unlink)$')
    changes[root / 'scripts/review-verdict-guard.py'] = (SOURCE / 'review-verdict-guard.py').read_text()
    changes[root / 'profiles/head-coordinator/scripts/idle-recovery-monitor.py'] = (SOURCE / 'idle-recovery-monitor.py').read_text()
    skill = root / 'profiles/feature-reviewer/skills/devops/sdlc-review/SKILL.md'
    if skill.exists():
        changes[skill] = skill.read_text().replace(
            'metadata={"review_outcome": "approved", "reviewer_checks": [...]}' ,
            'metadata={"review_outcome": "approved", "verdict": "accept",\n'
            '              "revision": "<reviewed source revision>",\n'
            '              "checks": [{"command": "<exact check>", "exit_code": 0}]}')
    for directory in [root / 'scripts', *(p / 'scripts' for p in (root / 'profiles').iterdir() if p.is_dir())]:
        for name in ('review-taskforce.py', 'review-taskforce-tick.sh'):
            changes[directory / name] = (SOURCE / name).read_text()
    changes[root / 'scripts/review-taskforce-approval.md'] = (SOURCE / 'taskforce/approval-policy.md').read_text()
    changes = {path: text for path, text in changes.items()
               if not (policy_only and path.name in {'config.yaml', 'profile.yaml'})}
    spec = importlib.util.spec_from_file_location('instruction_policy', SOURCE / 'install-instruction-policy.py')
    instructions = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(instructions)
    return {path: text for path, text in instructions.changes(root, changes).items()
            if not (policy_only and path.name in {'config.yaml', 'profile.yaml'})}


def install(root, check=False, cron=True, policy_only=False):
    changes = changed_files(root, policy_only=policy_only)  # Validate all transformations before writing.
    idle_changed = False
    idle_jobs_file = root / 'profiles/head-coordinator/cron/jobs.json'
    idle_jobs = json.loads(idle_jobs_file.read_text()).get('jobs', []) if idle_jobs_file.exists() else []
    idle = [job for job in idle_jobs if job.get('name') == 'kanban idle recovery']
    if len(idle) > 1:
        raise ValueError('Duplicate idle recovery jobs; repair the existing wiring')
    if cron and not policy_only and idle:
        idle_recovery_prompt(idle[0].get('prompt') or '')  # Reject malformed markers before writes.
        # The idle-recovery schedule used to be the one cadence this repo did
        # not pin down, so a re-provision could hand the lane a different one
        # silently. Pin it the way the taskforce cron drift check does: a
        # present job with the wrong cadence is a fault to repair with
        # `hermes cron edit`, not something to re-create or auto-fix.
        if idle[0].get('schedule', {}).get('minutes') != 15:
            raise ValueError('Idle recovery cron schedule drift; repair the existing job '
                             'with: hermes -p head-coordinator cron edit <id> --schedule "every 15m"')
    for path, text in changes.items():
        print(f'{"drift" if check else "install"}: {path}')
        if check:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        hermes_common.backup_file(root, 'review-taskforce', path)
        mode = path.stat().st_mode & 0o777 if path.exists() else 0o700
        hermes_common.atomic_write(path, text, mode=mode)
    if cron and not policy_only and idle:
        job = idle[0]
        prompt = idle_recovery_prompt(job.get('prompt') or '')
        idle_changed = job.get('monitor_script') != 'idle-recovery-monitor.py' or prompt != job.get('prompt')
        if idle_changed:
            print('drift: idle recovery monitor' if check else 'install: idle recovery monitor')
            if not check:
                subprocess.run(['hermes', '--profile', 'head-coordinator', 'cron', 'edit',
                                job['id'], '--monitor-script', 'idle-recovery-monitor.py', '--prompt', prompt],
                                check=True, timeout=60, env={**os.environ, 'HERMES_HOME': str(root)})
    jobs_file = root / 'cron/jobs.json'
    jobs = json.loads(jobs_file.read_text()).get('jobs', []) if jobs_file.exists() else []
    matching = [job for job in jobs if job.get('name') == JOB_NAME]
    if cron and not policy_only and not matching:
        print('drift: missing taskforce cron' if check else 'create: paused taskforce cron')
        if not check:
            env = os.environ.copy()
            env['HERMES_HOME'] = str(root)
            subprocess.run(['hermes', '--profile', 'default', 'cron', 'create', 'every 1h',
                            '--name', JOB_NAME, '--script', 'review-taskforce-tick.sh', '--no-agent',
                            '--deliver', 'local', '--workdir', str(SOURCE.parent.parent),
                            '--paused', '--paused-reason', 'Validate taskforce wiring before activation'], check=True, timeout=60, env=env)
    elif cron and not policy_only:
        expected = str(SOURCE.parent.parent)
        if len(matching) != 1 or any(job.get('script') != 'review-taskforce-tick.sh'
            or not job.get('no_agent') or job.get('workdir') != expected
            or job.get('schedule', {}).get('minutes') != 60 for job in matching):
            raise ValueError('Taskforce cron drift; repair the existing job using hermes cron edit')
    return 1 if check and (changes or idle_changed or (cron and not policy_only and not matching)) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--policy-only', action='store_true', help='Refresh tracked-source scripts/policies without configuration, metadata or cron writes')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    return install(root, check=args.check, policy_only=args.policy_only)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'taskforce installer: {exc}', file=sys.stderr)
        sys.exit(2)
