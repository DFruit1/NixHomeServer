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
END_MARKER = '<!-- /hermes-review-taskforce -->'
JOB_NAME = 'kanban review taskforce'
DESCRIPTIONS = {
    'project-auditor': 'PROJECT AUDITOR AND TASKFORCE LEAD. Sole owner of each board\'s persisted FINDINGS.md and immutable batch plans. Commissions focused adversarial audits of idle existing features from feature-reviewer, assesses their evidence, batches worthwhile proposals, immediately escalates urgent credible security/regression findings, and hands approved plans to head-coordinator. Routes diff and deploy-range verification to feature-reviewer; it does not verify work itself. Never implements or deploys.',
    'feature-reviewer': 'FEATURE-REVIEWER, THE VERIFIER LANE. Judges finished work against its acceptance criteria: per-card diffs, bounded technical questions and whole-change-set deploy reviews, returning accept or request-changes. Also audits idle existing features when project-auditor commissions one, and reports those findings to project-auditor. Never implements, edits FINDINGS.md or batch plans, or deploys.',
    'head-coordinator': 'HEAD COORDINATOR. Routes and decomposes implementation; never implements. Sends diff, question and whole-set deploy reviews to feature-reviewer, and scoped audit/planning requests to project-auditor, which exclusively manages feature-reviewer audits and the continuous improvement findings. Decomposes approved immutable plans into implementer, review and composition cards; keeps the handoff dependency-blocked until the work finishes. Retains existing sensitive-work routing, board health and whole-set guarded deploy gate. The owner uses T3 Code for manual large-model consultation.',
}


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
    if name == 'feature-reviewer':
        return policy(existing, template)
    if name == 'project-auditor':
        existing = existing.replace('- **Never leave your workspace.**',
            '- **Never leave your workspace**, except for the board taskforce documents\n'
            '  explicitly authorised below; never edit source under that exception.')
        if MARKER not in existing and END_MARKER not in existing:
            existing = existing.rstrip() + '\n\n'
            return policy(existing, template, start=len(existing))
        return policy(existing, template)
    heading = 'Continuous improvement intake' if '## Continuous improvement intake\n' in existing else 'Requesting an audit on demand'
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
