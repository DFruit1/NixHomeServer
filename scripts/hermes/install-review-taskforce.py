#!/usr/bin/env python3
"""Install reviewer taskforce policy without rewriting models or other settings."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile

SOURCE = Path(__file__).resolve().parent
MARKER = '<!-- hermes-review-taskforce -->'
JOB_NAME = 'kanban review taskforce'
DESCRIPTIONS = {
    'project-auditor': 'PROJECT AUDITOR AND TASKFORCE LEAD. Verifies implementations and whole deploy ranges. Manages feature-reviewer: commissions focused adversarial audits of idle existing features for correctness, regressions, integration, efficiency, security and simplicity. Sole owner of each board\'s persisted FINDINGS.md and immutable batch plans. Assesses evidence, batches worthwhile proposals, immediately escalates urgent credible security/regression findings, and hands approved plans to head-coordinator. Never implements or deploys.',
    'feature-reviewer': 'FEATURE REVIEWER. Reports to project-auditor, not head-coordinator. Answers one focused adversarial question about one idle existing feature and its integration boundaries. Reviews correctness, regressions, reliability, performance, security or simpler implementation as relevant. Returns revision-specific evidence, benefits, tradeoffs and verification proposals; clean findings are valid. Never implements, routes cards, edits the central findings document or writes batch plans.',
    'head-coordinator': 'HEAD COORDINATOR. Routes and decomposes implementation; never implements. Sends scoped audit requests to project-auditor, which exclusively manages feature-reviewer and the continuous improvement findings. Decomposes approved immutable plans into implementer, review and composition cards; keeps the handoff dependency-blocked until the work finishes. Retains existing sensitive-work routing, board health and whole-set guarded deploy gate. principal-consultant remains human-invoked only.',
}


def section(text, heading, replacement):
    pattern = rf'^## {re.escape(heading)}\n.*?(?=^## |\Z)'
    changed, count = re.subn(pattern, lambda _: replacement.rstrip() + '\n\n', text, flags=re.M | re.S)
    if count != 1:
        raise ValueError(f'Expected one policy section: {heading}')
    return changed


def soul(name, existing):
    template = (SOURCE / 'taskforce' / f'{name}.md').read_text()
    if name == 'feature-reviewer':
        return template
    if name == 'project-auditor':
        existing = existing.replace('- **Never leave your workspace.**',
            '- **Never leave your workspace**, except for the board taskforce documents\n'
            '  explicitly authorised below; never edit source under that exception.')
        if MARKER in existing:
            existing = existing.split(MARKER)[0].rstrip() + '\n'
        return existing.rstrip() + '\n\n' + MARKER + '\n' + template
    existing = existing.replace(
        '| `feature-reviewer` | One named feature/module/subsystem needs a focused correctness/reliability/performance audit. Cheap, runs often. |',
        '| `project-auditor` | Manages focused feature audits and approved improvement plans. |')
    existing = existing.replace('Scoped audit needed → `feature-reviewer`.',
                                'Scoped audit needed → `project-auditor`, which manages feature-reviewer.')
    existing = existing.replace('or ask `feature-reviewer` for a\ntargeted review of one suspect slice.',
                                'or ask `project-auditor` to commission a\ntargeted review of one suspect slice.')
    heading = 'Continuous improvement intake' if '## Continuous improvement intake\n' in existing else 'Requesting an audit on demand'
    existing = section(existing, heading, template)
    existing = existing.replace('A card from `principal-consultant` arrives with the plan attached.',
                                'A card from `principal-consultant` or `project-auditor` arrives with the plan attached.')
    start = existing.find('- Give each child the slice it owns')
    end = existing.find('- Preserve the plan\'s structure:', start)
    if start >= 0 and end >= 0:
        existing = existing[:start] + (
            '- Give each child only its owned slice. Put the absolute plan path on the\n'
            '  parent handoff; children reference that parent instead of repeating the\n'
            '  specification. Keep Goal/Change/Verify and explicit acceptance criteria\n'
            '  within the card budget. Verify that the parent context reaches each child.\n') + existing[end:]
    return existing


def changed_files(root):
    changes = {}
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
        if name in {'project-auditor', 'head-coordinator'}:
            config = directory / 'config.yaml'
            text = config.read_text()
            # Enable board tools for on-demand CLI/desktop conversations. Worker lifecycle
            # tools are still injected by Hermes; worker kanban_list stays hidden.
            block = re.search(r'^platform_toolsets:\n.*?(?=^\S|\Z)', text, re.M | re.S)
            if not block:
                raise ValueError('Expected platform_toolsets; inspect config before updating')
            settings = block.group(0)
            for platform in ('cli', 'desktop'):
                match = re.search(rf'^  {platform}: \[([^\n]*)\]', settings, re.M)
                if not match:
                    if platform == 'cli':
                        raise ValueError('Expected inline platform_toolsets.cli')
                    continue
                tools = [x.strip() for x in match.group(1).split(',') if x.strip()]
                if 'kanban' not in tools:
                    tools.append('kanban')
                    settings = settings[:match.start(1)] + ', '.join(tools) + settings[match.end(1):]
            text = text[:block.start()] + settings + text[block.end():]
            changes[config] = text
    for directory in [root / 'scripts', *(p / 'scripts' for p in (root / 'profiles').iterdir() if p.is_dir())]:
        for name in ('review-taskforce.py', 'review-taskforce-tick.sh'):
            changes[directory / name] = (SOURCE / name).read_text()
    changes[root / 'scripts/review-taskforce-approval.md'] = (SOURCE / 'taskforce/approval-policy.md').read_text()
    return {path: text for path, text in changes.items() if not path.exists() or path.read_text() != text}


def install(root, check=False, cron=True):
    changes = changed_files(root)  # Validate all transformations before writing.
    for path, text in changes.items():
        print(f'{"drift" if check else "install"}: {path}')
        if check:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        if path.exists():
            backup = root / 'backups/review-taskforce' / hashlib.sha256(str(path).encode()).hexdigest()[:12]
            backup.mkdir(parents=True, exist_ok=True, mode=0o700)
            old = path.read_bytes()
            copy = backup / hashlib.sha256(old).hexdigest()
            if not copy.exists():
                copy.write_bytes(old)
                copy.chmod(0o600)
        fd, temporary = tempfile.mkstemp(dir=path.parent)
        try:
            with os.fdopen(fd, 'w') as stream:
                stream.write(text)
            os.chmod(temporary, path.stat().st_mode & 0o777 if path.exists() else 0o700)
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
    jobs_file = root / 'cron/jobs.json'
    jobs = json.loads(jobs_file.read_text()).get('jobs', []) if jobs_file.exists() else []
    matching = [job for job in jobs if job.get('name') == JOB_NAME]
    if cron and not matching:
        print('drift: missing taskforce cron' if check else 'create: paused taskforce cron')
        if not check:
            env = os.environ.copy()
            env['HERMES_HOME'] = str(root)
            subprocess.run(['hermes', '--profile', 'default', 'cron', 'create', 'every 1h',
                            '--name', JOB_NAME, '--script', 'review-taskforce-tick.sh', '--no-agent',
                            '--deliver', 'local', '--workdir', str(SOURCE.parent.parent),
                            '--paused', '--paused-reason', 'Validate taskforce wiring before activation'], check=True, env=env)
    elif cron:
        expected = str(SOURCE.parent.parent)
        if len(matching) != 1 or any(job.get('script') != 'review-taskforce-tick.sh'
            or not job.get('no_agent') or job.get('workdir') != expected
            or job.get('schedule', {}).get('minutes') != 60 for job in matching):
            raise ValueError('Taskforce cron drift; repair the existing job using hermes cron edit')
    return 1 if check and (changes or (cron and not matching)) else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    args = parser.parse_args()
    root = Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes')))
    return install(root, check=args.check)


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError, OSError, subprocess.SubprocessError) as exc:
        print(f'taskforce installer: {exc}', file=sys.stderr)
        sys.exit(2)
