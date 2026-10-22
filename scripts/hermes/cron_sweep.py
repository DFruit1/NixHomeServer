#!/usr/bin/env python3
"""Apply bounded intake to the existing no-agent review-taskforce tick.

Reuse the installed scheduler's permissions and creation path. No new cadence,
model, remote operation or alternative approval mechanism is introduced.
"""
import importlib.util
from pathlib import Path
import sys


def configure(scheduler):
    original_pending=scheduler.sweep_pending
    original_hermes=scheduler.hermes

    def pending(tasks):
        return original_pending(tasks) or any(
            t.get('tenant')==scheduler.TENANT and t.get('status') not in {'done','archived'}
            and t.get('assignee') in {'head-coordinator','standard-implementer','feature-reviewer','project-auditor'}
            for t in tasks)

    def body(root,board):
        return '\n'.join([
            'Goal: Deliver one evidence-backed system improvement, or record no candidate.',
            'Change: review-taskforce/FINDINGS.md:1 — check assessed findings and existing work.',
            'Verify: accepted exact source, integration and applicable installed readback; no routing-only success.',
            scheduler.board_state_line(root,board),
            'Constraints:',
            '- Choose from verified incidents or assessed findings; no speculative repository crawl.',
            '- Name the benefit, exact scope and stopping condition before commissioning.',
            '- One open improvement chain per board; preserve existing priorities and approval gates.',
            '- Small fixes need implementer and independent verifier; investigations go to the auditor.',
            '- Keep the handoff open through delivered results; children must not depend on its closure.',
            '- Record routed|no_candidate with record-sweep; routed is intake, not delivery.',
            '- Do not implement, deploy or manufacture work. Stop at the five-minute card budget.',
        ])

    def hermes(board,*args):
        if len(args)>1 and args[0]=='create' and args[1]==scheduler.SWEEP_TITLE:
            args=(*args,'--max-runtime','300','--max-retries','1')
        return original_hermes(board,*args)

    scheduler.sweep_pending=pending;scheduler.sweep_body=body;scheduler.hermes=hermes


if __name__=='__main__':
    source=Path(__file__).resolve().with_name('review-taskforce.py')
    spec=importlib.util.spec_from_file_location('review_taskforce',source)
    scheduler=importlib.util.module_from_spec(spec);spec.loader.exec_module(scheduler)
    configure(scheduler);sys.argv=[str(source),'tick'];sys.exit(scheduler.main())
