#!/usr/bin/env python3
"""Read native prerequisite chains without changing cards or exposing card bodies.

Python/SQLite operations glue matches existing Hermes reports; no new service or
dependency. Only done satisfies a native dependency, including archived parents.
"""
import argparse
from collections import defaultdict, deque
from contextlib import closing
import json
import os
from pathlib import Path
import re
import sqlite3
import time

MAX_TASKS, MAX_LINKS, MAX_WALK = 5000, 25000, 2000000


def components(graph):
    """Iterative Kosaraju: cycles must not consume Python recursion depth."""
    seen, order = set(), []
    reverse = {node: [] for node in graph}
    for node, parents in graph.items():
        for parent in parents:
            reverse[parent].append(node)
    for start in sorted(graph):
        if start in seen:
            continue
        seen.add(start)
        stack = [(start, iter(graph[start]))]
        while stack:
            node, edges = stack[-1]
            parent = next(edges, None)
            if parent is None:
                order.append(node)
                stack.pop()
            elif parent not in seen:
                seen.add(parent)
                stack.append((parent, iter(graph[parent])))
    membership, groups = {}, []
    for start in reversed(order):
        if start in membership:
            continue
        group, stack = [], [start]
        membership[start] = len(groups)
        while stack:
            node = stack.pop()
            group.append(node)
            for child in reverse[node]:
                if child not in membership:
                    membership[child] = len(groups)
                    stack.append(child)
        groups.append(sorted(group))
    return membership, groups


def category(task):
    status, kind = task['status'], task['block_kind']
    if status == 'missing':
        return 'missing_prerequisite'
    if status == 'archived':
        return 'archived_prerequisite'
    if status == 'blocked':
        return {'needs_input': 'recorded_owner_gate', 'capability': 'capability',
                'transient': 'transient', 'dependency': 'dependency_hold'}.get(kind, 'blocked_unknown')
    return {'running': 'active', 'review': 'review', 'ready': 'recorded_ready',
            'triage': 'routing', 'scheduled': 'scheduled'}.get(status, 'unrouted')


def analyze(tasks, links):
    graph = {tid: set() for tid, t in tasks.items() if t['status'] != 'done'}
    dangling = []
    for parent, child in links:
        if parent not in tasks or child not in tasks:
            dangling.append({'parent': parent, 'child': child})
        if child in graph and (parent not in tasks or tasks[parent]['status'] != 'done'):
            graph.setdefault(parent, set())
            graph[child].add(parent)
    graph = {node: sorted(parents) for node, parents in graph.items()}
    membership, groups = components(graph)
    dag = {i: set() for i in range(len(groups))}
    cyclic = {i for i, members in enumerate(groups)
              if len(members) > 1 or members[0] in graph[members[0]]}
    for node, parents in graph.items():
        dag[membership[node]].update(membership[p] for p in parents if membership[p] != membership[node])
    waiting, roots, affected, held = [], {}, defaultdict(set), defaultdict(set)
    walked = 0
    def charge(count):
        nonlocal walked
        walked += count
        if walked > MAX_WALK:
            raise ValueError('Dependency graph exceeds the bounded traversal/output budget')
    for tid in sorted(tasks):
        if tasks[tid]['status'] in ('done', 'archived') or not graph.get(tid):
            continue
        start = membership[tid]
        queue, previous = deque([start]), {start: None}
        found, holds = {}, set()
        while queue:
            part = queue.popleft()
            members = groups[part]
            charge(len(members)+len(dag[part]))
            holds.update(node for node in members if node in tasks and tasks[node]['status'] in ('blocked', 'triage', 'archived'))
            if not dag[part] or part in cyclic:
                key = members[0]
                route, cursor = [], part
                while cursor is not None:
                    charge(1)
                    route.append(tid if cursor == start else groups[cursor][0])
                    cursor = previous[cursor]
                route.reverse()
                found[key] = route
                task = tasks.get(key, {'status': 'missing', 'assignee': None, 'block_kind': None})
                roots[key] = {'task_id': key, **task, 'members': members,
                              'category': 'cycle' if part in cyclic else category(task)}
                if tid not in members:
                    affected[key].add(tid)
            for parent in sorted(dag[part], key=lambda i: groups[i][0]):
                if parent not in previous:
                    previous[parent] = part
                    queue.append(parent)
        charge(len(holds))
        for hold in holds:
            if hold != tid:
                held[hold].add(tid)
        waiting.append({'task_id': tid, 'immediate_parents': graph[tid], 'roots': sorted(found),
                        'holds': sorted(holds),
                        'paths': {root: path if len(path) <= 64 else path[:63] + [path[-1]]
                                  for root, path in sorted(found.items())},
                        'paths_truncated': any(len(path) > 64 for path in found.values())})
    return {'active_cards': sum(t['status'] not in ('done', 'archived') for t in tasks.values()),
            'waiting_cards': len(waiting),
            'roots': sorted(({**r, 'downstream_cards': len(affected[key])} for key, r in roots.items()),
                            key=lambda r: (-r['downstream_cards'], r['task_id'])),
            'waiting': waiting, 'cycles': sorted(groups[i] for i in cyclic),
            'local_holds': [{'task_id': tid, **tasks[tid], 'category': category(tasks[tid]),
                             'downstream_cards': len(children)} for tid, children in sorted(held.items())
                            if tid not in roots],
            'dangling_links': sorted(dangling, key=lambda e: (e['child'], e['parent']))}


def report(root, board=None):
    if board is not None and not re.fullmatch(r'[A-Za-z0-9_-]+', board):
        raise ValueError('Invalid board slug')
    paths = ([root/'kanban/boards'/board/'kanban.db'] if board else sorted(
        set((root/'kanban/boards').glob('*/kanban.db')) |
        {p.with_name('kanban.db') for p in (root/'kanban/boards').glob('*/board.json')}))
    result = {'schema_version': 1, 'boards': {}, 'warnings': []}
    for path in paths:
        slug = path.parent.name
        if slug.startswith(('_', '.')):
            continue
        try:
            with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro', uri=True, timeout=2)) as db:
                db.execute('PRAGMA query_only=ON')
                deadline = time.monotonic() + 8
                db.set_progress_handler(lambda: int(time.monotonic() > deadline), 10000)
                db.execute('BEGIN')
                rows = db.execute('SELECT id,status,assignee,block_kind FROM tasks ORDER BY id LIMIT ?',
                                  (MAX_TASKS + 1,)).fetchall()
                links = db.execute('SELECT parent_id,child_id FROM task_links ORDER BY parent_id,child_id LIMIT ?',
                                   (MAX_LINKS + 1,)).fetchall()
                if len(rows) > MAX_TASKS or len(links) > MAX_LINKS:
                    raise ValueError('Dependency graph exceeds report bounds')
                tasks = {tid: {'status': status, 'assignee': who, 'block_kind': kind}
                         for tid, status, who, kind in rows}
                result['boards'][slug] = analyze(tasks, links)
        except (OSError, sqlite3.Error, ValueError):
            result['warnings'].append({'board': slug, 'reason': 'missing_unreadable_unsupported_or_oversize'})
    if not paths:
        result['warnings'].append({'board': None, 'reason': 'no_active_sources'})
    return result


def render(data, limit=10, task=None):
    lines = ['HERMES PREREQUISITES (recorded state; native readback before acting)']
    for board, result in sorted(data['boards'].items()):
        lines.append(f"[{board}] active={result['active_cards']} waiting={result['waiting_cards']} "
                     f"cycles={len(result['cycles'])} broken-links={len(result['dangling_links'])}")
        if task:
            for entry in result['waiting']:
                if entry['task_id'] == task:
                    lines.append(json.dumps(entry, sort_keys=True))
        else:
            for entry in result['roots'][:limit]:
                lines.append(f"  {entry['task_id']} @{entry['assignee'] or '?'} {entry['category']} "
                             f"holds={entry['downstream_cards']} downstream cards")
            for entry in result['local_holds'][:limit]:
                lines.append(f"  {entry['task_id']} @{entry['assignee'] or '?'} {entry['category']} "
                             f"local-hold affects={entry['downstream_cards']} downstream cards")
    if data['warnings']:
        lines.append(f"Coverage errors: {len(data['warnings'])}; inspect --json, not a clean-board result.")
    return '\n'.join(lines)


def main(argv=()):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--board')
    parser.add_argument('--task', help='Show this card\'s root paths (use with --board).')
    parser.add_argument('--json', action='store_true')
    args = parser.parse_args(argv)
    if args.task and not args.board:
        parser.error('--task requires --board')
    try:
        data = report(Path(os.environ.get('HERMES_ROOT', str(Path.home()/'.hermes'))), args.board)
    except ValueError as exc:
        parser.error(str(exc))
    print(json.dumps(data, sort_keys=True) if args.json else render(data, task=args.task))
    return 1 if data['warnings'] else 0


if __name__ == '__main__':
    raise SystemExit(main(None))
