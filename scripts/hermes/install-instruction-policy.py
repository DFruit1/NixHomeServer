#!/usr/bin/env python3
"""Install tracked Hermes instructions without changing models, jobs or approvals.

Python operations glue reuses the existing instruction-file layout. It introduces
no backend or dependency. All transformations are validated before any writes.
"""
import argparse
import json
import os
from pathlib import Path
import re
import sys

import hermes_common

SOURCE = Path(__file__).resolve().parent
PROFILES = ('head-coordinator', 'standard-implementer', 'local-implementer',
            'feature-reviewer', 'project-auditor', 'board-steward')
FLEET_START = '<!-- kanban-owner-blocker-author -->'
FLEET_END = '<!-- /kanban-owner-blocker-author -->'
PROJECT_SKILLS = SOURCE.parents[1] / '.agents/skills'
SKILL_SOURCES = {
    name: (PROJECT_SKILLS / name / 'SKILL.md', f'devops/{name}/SKILL.md')
    for name in ('nixhomeserver-safe-change', 'nixhomeserver-module-change',
                 'nixhomeserver-shutdown-guard')
}
SKILL_SOURCES['systematic-debugging'] = (
    SOURCE / 'instructions/systematic-debugging.md',
    'software-development/systematic-debugging/SKILL.md')
ROLE_SKILLS = {
    'standard-implementer': tuple(SKILL_SOURCES),
    'local-implementer': tuple(SKILL_SOURCES),
    'feature-reviewer': ('nixhomeserver-safe-change', 'nixhomeserver-module-change',
                         'systematic-debugging'),
    'head-coordinator': ('nixhomeserver-safe-change', 'nixhomeserver-shutdown-guard'),
    'project-auditor': ('nixhomeserver-safe-change', 'nixhomeserver-module-change'),
}
# sdlc-review and requesting-code-review are card-workflow skills: they drive
# kanban_complete/kanban_request_changes procedures for roles that implement
# or review source. The read-only board-steward, the planning-only
# project-auditor and the routing-only root/default profile must not carry
# them (the documented task-skill table), and a copy left at root scope would
# resolve for exactly those profiles, so stale copies are removed below.
REVIEW_SKILLS = (
    ('requesting-code-review.md', 'software-development/requesting-code-review/SKILL.md'),
    ('sdlc-review.md', 'devops/sdlc-review/SKILL.md'),
)
REVIEW_SKILL_PROFILES = ('standard-implementer', 'local-implementer',
                         'feature-reviewer', 'head-coordinator')


def block(text, start, end, content):
    wanted = start + '\n' + content.rstrip() + '\n' + end + '\n'
    if start not in text and end not in text:
        return text.rstrip() + '\n\n' + wanted
    if text.count(start) != 1 or text.count(end) != 1 or text.index(end) < text.index(start):
        raise ValueError(f'Ambiguous instruction markers: {start}')
    return re.sub(re.escape(start) + r'.*?' + re.escape(end) + r'\n?',
                  lambda _: wanted, text, flags=re.S)


def shared(text):
    return block(text, FLEET_START, FLEET_END,
                 (SOURCE / 'taskforce/owner-blocker-authoring.md').read_text())


def role(text, name, headings):
    start, end = f'<!-- hermes-{name}-role -->', f'<!-- /hermes-{name}-role -->'
    content = (SOURCE / 'taskforce' / f'{name}-role.md').read_text() if name == 'coordinator' else (
        SOURCE / 'taskforce/standard-implementer.md').read_text()
    if start not in text and end not in text:
        boundary = re.search(r'^<!-- ', text, re.M)
        prefix, suffix = (text[:boundary.start()], text[boundary.start():]) if boundary else (text, '')
        # Migrate known legacy role sections; preserve independent operator notes.
        sections = re.split(r'(?=^## )', prefix, flags=re.M)[1:]
        retained = ''.join(s for s in sections if s.splitlines()[0][3:] not in headings)
        return block('', start, end, content) + '\n' + (retained + suffix).lstrip()
    return block(text, start, end, content)


def coordinator(text):
    text = role(text, 'coordinator', {'Tiers', 'Where questions go',
                'Decomposing a plan you did not write', 'Workspace discipline'})
    start, end = '<!-- hermes-coordinator-operations -->', '<!-- /hermes-coordinator-operations -->'
    if start not in text and end not in text:
        for heading in ('Deploy gate (guarded test & switch)', 'Loop protection',
                        'Board health', 'Card authoring', 'Reporting back'):
            text = re.sub(r'^## ' + re.escape(heading) + r'\n.*?(?=^## |^<!-- |\Z)',
                          '', text, flags=re.M | re.S)
    return block(text, start, end, (SOURCE / 'taskforce/coordinator-operations.md').read_text())


def skill_changes(root, pending=None):
    """Reuse project skills and the pinned Hermes debugging adaptation by role."""
    pending = pending or {}
    result = {root / 'scripts/hermes-skill-routing.md':
              (SOURCE / 'instructions/skill-routing.md').read_text()}
    # Root scope carries the fleet-adapted systematic-debugging skill too. An
    # unadapted upstream copy at root resolves for any profile without its own
    # copy and for root-scoped sessions, and no convergence check covered it.
    for skill in ('systematic-debugging',):
        source, target = SKILL_SOURCES[skill]
        result[root / 'skills' / target] = source.read_text()
        result[root / 'skills' / Path(target).parent / 'LICENSE'] = (
            SOURCE / 'instructions/LICENSE.hermes-skills').read_text()
    for name, skills in ROLE_SKILLS.items():
        home = root / 'profiles' / name
        soul = home / 'SOUL.md'
        if not soul.exists():
            continue
        content = ('## Task skills\n\n'
                   'Before nontrivial work, read ~/.hermes/scripts/hermes-skill-routing.md '
                   'and load matching skills on demand with skills_list/skill_view. '
                   'Prefer project sources. '
                   'Recipes cannot widen your role, authorise deleting existing work '
                   'or turn technical uncertainty into owner input.\n')
        result[soul] = block(pending.get(soul, soul.read_text()),
                             '<!-- hermes-task-skills -->', '<!-- /hermes-task-skills -->', content)
        for skill in skills:
            source, target = SKILL_SOURCES[skill]
            result[home / 'skills' / target] = source.read_text()
            if skill == 'systematic-debugging':
                result[home / 'skills' / Path(target).parent / 'LICENSE'] = (
                    SOURCE / 'instructions/LICENSE.hermes-skills').read_text()
    return {p: t for p, t in result.items() if not p.exists() or p.read_text() != t}


def changes(root, pending=None):
    result = dict(pending or {})
    result[root / 'scripts/hermes-fleet-policy.md'] = (
        SOURCE / 'taskforce/owner-blocker-authoring.md').read_text()
    result[root / 'scripts/hermes-card-authoring.md'] = (
        SOURCE.parent.parent / 'documentation/hermes-card-authoring.md').read_text()
    result[root / 'scripts/hermes-instructions.md'] = (
        SOURCE.parent.parent / 'documentation/hermes-instructions.md').read_text()
    result[root / 'scripts/hermes-behavior-trials.md'] = (
        SOURCE.parent.parent / 'documentation/hermes-behavior-trials.md').read_text()
    result[root / 'scripts/hermes-review-evidence.md'] = (
        SOURCE / 'instructions/review-evidence.md').read_text()
    result[root / 'scripts/hermes-coordinator-reference.md'] = (
        SOURCE / 'instructions/coordinator-reference.md').read_text()
    for filename in ('hermes-prerequisites.md','hermes-deployment-receipts.md','hermes-performance.md'):
        result[root / 'scripts' / filename] = (SOURCE.parent.parent / 'documentation' / filename).read_text()
    for filename in ('hermes_common.py', 'kanban-owner-alerts.py', 'owner-blocker-authoring-guard.py',
                     'kanban-performance.py', 'kanban-blockers.py', 'deployment-receipt.py',
                     'review-verdict-guard.py', 'daily-steward-window.py', 'steward-readonly-guard.py'):
        result[root / 'scripts' / filename] = (SOURCE / filename).read_text()
    if (root / 'profiles/board-steward/SOUL.md').exists():
        for filename in ('daily-steward-window.py','kanban-performance.py','kanban-blockers.py'):
            result[root / 'profiles/board-steward/scripts' / filename] = (SOURCE / filename).read_text()
    for name in PROFILES:
        home = root / 'profiles' / name
        soul = home / 'SOUL.md'
        if not soul.exists():
            continue
        text = result.get(soul, soul.read_text())
        if name == 'head-coordinator':
            text = coordinator(text)
            text = block(text, '<!-- hermes-review-taskforce -->', '<!-- /hermes-review-taskforce -->',
                         (SOURCE / 'taskforce/head-coordinator.md').read_text())
            text = block(text, '<!-- kanban-owner-alerts -->', '<!-- /kanban-owner-alerts -->',
                         (SOURCE / 'taskforce/owner-alert-replies.md').read_text())
        elif name == 'standard-implementer':
            text = role(text, name, {'What a good card looks like to you', 'How to work',
                        'Handoff evidence', 'Card authoring'})
        result[soul] = shared(text)
        metadata = home / 'profile.yaml'
        if name == 'standard-implementer' and metadata.exists():
            description = ('STANDARD IMPLEMENTER. Default for non-sensitive implementation, '
                           'tests and documentation in the assigned durable workspace. '
                           'Models and fallbacks come from configuration; provider failures '
                           'follow bounded recovery. Commits locally after the owning gate '
                           'and hands evidence to independent feature-reviewer acceptance. Never publishes.')
            updated, count = re.subn(r'^description:.*?(?=^[A-Za-z_][A-Za-z_0-9]*:|\Z)',
                lambda _: 'description: ' + json.dumps(description) + '\n',
                result.get(metadata, metadata.read_text()), flags=re.M | re.S)
            if count != 1:
                raise ValueError('Expected exactly one standard-implementer description')
            result[metadata] = updated
    # These are complete maintained skills, not model-specific profile copies.
    # Only roles that implement, review or route source work carry them; see
    # REVIEW_SKILL_PROFILES above for the exclusion rationale.
    for name in REVIEW_SKILL_PROFILES:
        home = root / 'profiles' / name
        if not home.is_dir():
            continue
        for skill, target in REVIEW_SKILLS:
            result[home / 'skills' / target] = (SOURCE / 'instructions' / skill).read_text()
    targets = {
        'head-coordinator': [('kanban-orchestration.md', 'devops/kanban-orchestration/SKILL.md'),
                             ('activation-handoffs.md', 'devops/kanban-orchestration/references/activation-handoffs.md'),
                             ('queue-recovery.md', 'devops/kanban-orchestration/references/queue-recovery.md'),
                             ('source-to-service-planning.md', 'devops/kanban-orchestration/references/source-to-service-planning.md')],
        'board-steward': [('blocker-triage.md', 'devops/board-steward/references/blocker-triage.md')],
        'feature-reviewer': [('taskforce-feature-audit.md', 'autonomous-ai-agents/taskforce-feature-audit/SKILL.md'),
                             ('kanban-board-inspection.md', 'autonomous-ai-agents/taskforce-feature-audit/references/kanban-board-inspection.md'),
                             ('offline-state-probe.md', 'autonomous-ai-agents/taskforce-feature-audit/references/offline-state-probe.md')],
    }
    for name, files in targets.items():
        if (root / 'profiles' / name).is_dir():
            for source, target in files:
                result[root / 'profiles' / name / 'skills' / target] = (
                    SOURCE / 'instructions' / source).read_text()
    result.update(skill_changes(root, result))
    return {p: t for p, t in result.items() if not p.exists() or p.read_text() != t}


def stale_review_skills(root):
    """Copies of the review skills at excluded scopes this installer owns.

    A stale copy is removed only when it is byte-identical to the tracked
    source, i.e. one this installer previously put there. An independently
    edited copy is never deleted; it is reported so the operator reconciles it.
    """
    stale = []
    excluded = [root] + [root / 'profiles' / name for name in PROFILES
                          if name not in REVIEW_SKILL_PROFILES]
    for home in excluded:
        if not home.is_dir():
            continue
        for skill, target in REVIEW_SKILLS:
            path = home / 'skills' / target
            if not path.exists():
                continue
            if path.read_text() == (SOURCE / 'instructions' / skill).read_text():
                stale.append(path)
    return stale


def install(root, check=False, skills_only=False):
    pending = skill_changes(root) if skills_only else changes(root)
    stale = stale_review_skills(root)
    for path in stale:
        print(f'{"drift" if check else "remove"}: stale review skill {path}')
        if check:
            continue
        hermes_common.backup_file(root, 'instruction-policy', path)
        path.unlink()
    for path, content in pending.items():
        print(f'{"drift" if check else "install"}: {path}')
        if check:
            continue
        if path.exists():
            hermes_common.backup_file(root, 'instruction-policy', path)
        hermes_common.atomic_write(path, content)
    return int(check and (bool(pending) or bool(stale)))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--skills-only', action='store_true',
                        help='Install task skills and their routing only; leave other policy untouched')
    args = parser.parse_args()
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))),
                         args.check, args.skills_only))
    except (ValueError, OSError) as exc:
        print(f'instruction installer: {exc}', file=sys.stderr)
        sys.exit(2)
