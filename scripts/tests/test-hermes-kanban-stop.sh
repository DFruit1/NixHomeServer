#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# Native source is mounted read-only inside the maintained no-production-state
# fixture. Never import the installed runtime outside this boundary.
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  exec python3 -B "$repo/scripts/hermes/fixture-runner.py" --repo "$repo" \
    --suite "$repo/scripts/tests/test-hermes-kanban-stop.sh"
fi
python3 -B - "$repo" <<'PY'
import importlib.util
import json
import os
from pathlib import Path
import sys
import types
import unittest
from unittest.mock import patch

repo = Path(sys.argv[1])
native = Path(os.environ['HERMES_FIXTURE_NATIVE_PYTHON']).parents[2]
sys.path[:0] = [str(repo / 'scripts/hermes'), str(native)]
from worker_runtime_adapter import adapt, EDITS
from agent import delegation_context

helper_source = repo / 'scripts/hermes/worker_handoff.py'
if helper_source.is_file():
    helper_name = 'hermes_cli.nixhomeserver_worker_handoff'
    spec = importlib.util.spec_from_file_location(helper_name, helper_source)
    helper = importlib.util.module_from_spec(spec)
    sys.modules[helper_name] = helper
    spec.loader.exec_module(helper)

text = (native / 'agent/kanban_stop.py').read_text()
if 'agent/kanban_stop.py' in EDITS:
    text = adapt('agent/kanban_stop.py', text)
guard = types.ModuleType('fixture_kanban_stop')
exec(compile(text, 'fixture_kanban_stop.py', 'exec'), guard.__dict__)


class KanbanStopTest(unittest.TestCase):
    task = 't_fixture'
    board = 'fixture'
    terminals = ('kanban_complete', 'kanban_block', 'kanban_schedule',
                 'kanban_request_review', 'kanban_request_changes')

    def setUp(self):
        self.env = patch.dict(os.environ, {
            'HERMES_KANBAN_TASK': self.task,
            'HERMES_KANBAN_BOARD': self.board,
            'HERMES_KANBAN_STOP_NUDGE': '1',
            'HERMES_DELEGATED_CHILD_CONTEXT': '',
        })
        self.env.start()
        self.addCleanup(self.env.stop)

    def call(self, name='kanban_complete', *, call_id='call_1', task=None,
             board=None, object_call=False):
        args = json.dumps({'task_id': self.task if task is None else task,
                           'board': self.board if board is None else board})
        function = {'name': name, 'arguments': args}
        tc = {'id': call_id, 'type': 'function', 'function': function}
        if object_call:
            tc = types.SimpleNamespace(id=call_id,
                function=types.SimpleNamespace(**function))
        return {'role': 'assistant', 'tool_calls': [tc]}

    def result(self, name='kanban_complete', *, call_id='call_1', payload=None,
               named=True):
        if payload is None:
            payload = {'ok': True, 'task_id': self.task}
        msg = {'role': 'tool', 'tool_call_id': call_id,
               'content': json.dumps(payload)}
        if named:
            msg['name'] = name
        return msg

    def assertNeedsNudge(self, messages):
        self.assertIsNotNone(guard.build_kanban_stop_nudge(messages=messages),
                             'a failed or unrelated call must not end worker recovery')

    def test_every_refused_terminal_still_gets_bounded_recovery(self):
        for name in self.terminals:
            for payload in ({'error': 'refused: nothing changed'},
                            {'ok': False, 'task_id': self.task},
                            {'ok': True, 'task_id': self.task, 'error': 'refused'}):
                with self.subTest(name=name, payload=payload):
                    self.assertNeedsNudge([self.call(name), self.result(name, payload=payload)])

    def test_unanswered_terminal_call_is_not_a_handoff(self):
        for name in self.terminals:
            with self.subTest(name=name):
                self.assertNeedsNudge([self.call(name)])

    def test_successful_exact_task_handoffs_do_not_prompt_accidental_completion(self):
        for name in self.terminals:
            for named in (True, False):
                for object_call in (False, True):
                    with self.subTest(name=name, named=named, object_call=object_call):
                        messages = [self.call(name, object_call=object_call),
                                    self.result(name, named=named)]
                        self.assertIsNone(guard.build_kanban_stop_nudge(messages=messages))

    def test_wrong_task_in_call_or_result_never_suppresses_recovery(self):
        for call_task, result_task in ((self.task, 't_other'),
                                      ('t_other', self.task),
                                      ('t_other', 't_other')):
            with self.subTest(call_task=call_task, result_task=result_task):
                self.assertNeedsNudge([self.call(task=call_task), self.result(
                    payload={'ok': True, 'task_id': result_task})])

    def test_wrong_board_in_call_or_result_never_suppresses_recovery(self):
        self.assertNeedsNudge([self.call(board='another-board'), self.result()])
        self.assertNeedsNudge([self.call(), self.result(payload={
            'ok': True, 'task_id': self.task, 'board': 'another-board'})])

    def test_orphan_mismatched_and_renamed_results_are_not_a_handoff(self):
        for messages in ([self.result()],
                         [self.call(), self.result(call_id='unknown')],
                         [self.call(), self.result(name='kanban_block')]):
            with self.subTest(messages=messages):
                self.assertNeedsNudge(messages)

    def test_pinned_native_argument_defaults_remain_valid_for_own_task(self):
        # Native handlers can default omitted arguments to dispatcher pins.
        # The result still must positively identify a successful own-task write.
        for name in self.terminals:
            for args in ({}, {'task_id': self.task}, {'board': self.board}):
                with self.subTest(name=name, args=args):
                    call = self.call(name)
                    call['tool_calls'][0]['function']['arguments'] = json.dumps(args)
                    self.assertIsNone(guard.build_kanban_stop_nudge(messages=[
                        call, self.result(name, named=False)]))

    def test_responses_and_composite_ids_use_native_result_pairing(self):
        for object_call in (False, True):
            for raw_id, call_id in (('call_1|fc_item', None), ('fc_item', 'call_1')):
                with self.subTest(object_call=object_call, raw_id=raw_id, call_id=call_id):
                    message = self.call(call_id=raw_id, object_call=object_call)
                    call = message['tool_calls'][0]
                    if call_id is not None:
                        if object_call:
                            call.call_id = call_id
                        else:
                            call['call_id'] = call_id
                    self.assertIsNone(guard.build_kanban_stop_nudge(messages=[
                        message, self.result(named=False)]))

    def test_non_json_and_nonboolean_success_are_not_a_handoff(self):
        for content in ('', 'refused', 'null', '[]', '{',
                        json.dumps({'ok': 'true', 'task_id': self.task}),
                        json.dumps({'ok': 1, 'task_id': self.task}),
                        json.dumps({'ok': True})):
            with self.subTest(content=content):
                result = self.result()
                result['content'] = content
                self.assertNeedsNudge([self.call(), result])

    def test_unrelated_success_cannot_hide_later_terminal_refusal(self):
        messages = [self.call(task='t_other'), self.result(payload={
            'ok': True, 'task_id': 't_other'}),
            self.call(call_id='call_2'), self.result(call_id='call_2',
                payload={'error': 'refused'})]
        self.assertNeedsNudge(messages)

    def test_successful_comment_does_not_handoff_the_worker_card(self):
        self.assertNeedsNudge([self.call('kanban_comment'), self.result('kanban_comment')])

    def test_nudge_carries_explicit_task_and_board_tool_arguments(self):
        nudge = guard.build_kanban_stop_nudge(messages=[])
        self.assertIsNotNone(nudge)
        # Accept either JSON or Python-style notation, but require copyable
        # argument names and values, not only prose mentioning the identifiers.
        for name, value in (('task_id', self.task), ('board', self.board)):
            self.assertRegex(nudge, r'[\"\'`]?' + name + r'[\"\'`]?\s*[:=]\s*[\"\'`]' + value)

    def test_empty_stop_is_bounded_at_two_attempts(self):
        for attempts in (0, 1):
            self.assertIsNotNone(guard.build_kanban_stop_nudge(messages=[], attempts=attempts))
        for attempts in (2, 3, 100):
            self.assertIsNone(guard.build_kanban_stop_nudge(messages=[], attempts=attempts))
        self.assertIsNone(guard.build_kanban_stop_nudge(messages=[], max_attempts=0))

    def test_failed_terminal_recovery_keeps_original_attempt_budget(self):
        messages = [self.call(), self.result(payload={'error': 'refused'})]
        self.assertIsNotNone(guard.build_kanban_stop_nudge(messages=messages, attempts=1))
        self.assertIsNone(guard.build_kanban_stop_nudge(messages=messages, attempts=2))

    def test_nonworker_disabled_and_delegated_process_are_unchanged(self):
        for env in ({'HERMES_KANBAN_TASK': ''},
                    {'HERMES_KANBAN_STOP_NUDGE': 'off'},
                    {'HERMES_DELEGATED_CHILD_CONTEXT': '1'}):
            with self.subTest(env=env), patch.dict(os.environ, env):
                self.assertIsNone(guard.build_kanban_stop_nudge(messages=[]))

    def test_in_process_non_dispatcher_context_does_not_inherit_worker_guard(self):
        with delegation_context.non_dispatcher_owned_context():
            self.assertIsNone(guard.build_kanban_stop_nudge(messages=[]))
        # Prove that the context manager restored the owning worker identity.
        self.assertIsNotNone(guard.build_kanban_stop_nudge(messages=[]))

    def test_in_process_delegate_does_not_inherit_worker_guard(self):
        with delegation_context.delegated_child_context():
            self.assertIsNone(guard.build_kanban_stop_nudge(messages=[]))
        self.assertIsNotNone(guard.build_kanban_stop_nudge(messages=[]))

    def test_native_turn_stop_gate_continues_failed_handoff_then_accepts_review(self):
        # Exercise the real turn-loop caller and message appending. Only other
        # continuation policies and agent I/O callbacks are replaced.
        from agent import turn_stop_gates
        diagnostics = []
        agent = types.SimpleNamespace(
            _emit_diagnostic_status=diagnostics.append,
            _interim_content_was_streamed=lambda content: False)
        messages = [self.call(), self.result(payload={'error': 'refused: review required'})]
        candidate = {'role': 'assistant', 'content': 'I will submit this for review.'}

        def stop(worker, transcript, answer):
            return turn_stop_gates.apply_stop_gates(
                worker, answer, final_response=answer['content'], messages=transcript,
                conversation_history=[], pending_verification_response=None,
                pending_verification_response_previewed=False)

        with patch.dict(sys.modules, {'agent.kanban_stop': guard}), \
             patch.object(turn_stop_gates, '_verify_on_stop_nudge', return_value=None), \
             patch.object(turn_stop_gates, '_pre_verify_nudge', return_value=None):
            verdict = stop(agent, messages, candidate)
            self.assertTrue(verdict.continue_turn)
            self.assertIsNone(verdict.final_response)
            self.assertEqual(candidate['content'], verdict.pending_verification_response)
            self.assertEqual(1, agent._kanban_stop_nudges)
            self.assertIs(messages, agent._session_messages)
            self.assertEqual(['assistant', 'user'], [m['role'] for m in messages[-2:]])
            self.assertEqual('kanban_terminal_required', messages[-2]['finish_reason'])
            self.assertTrue(messages[-1]['_kanban_stop_synthetic'])
            self.assertIn(self.task, messages[-1]['content'])
            self.assertIn(self.board, messages[-1]['content'])
            self.assertEqual(1, len(diagnostics))

            messages.extend([self.call('kanban_request_review', call_id='review_2'),
                self.result('kanban_request_review', call_id='review_2', named=False)])
            before = list(messages)
            answer = {'role': 'assistant', 'content': 'Submitted for independent review.'}
            verdict = stop(agent, messages, answer)
            self.assertFalse(verdict.continue_turn)
            self.assertEqual(answer['content'], verdict.final_response)
            self.assertEqual(before, messages, 'a valid review handoff must not add a completion nudge')
            self.assertEqual(1, agent._kanban_stop_nudges)
            self.assertEqual(1, len(diagnostics))

            # A provider that keeps stopping after refusal gets exactly the
            # existing two continuations, not a new unbounded retry loop.
            agent._kanban_stop_nudges = 0
            messages = [self.call(), self.result(payload={'error': 'refused'})]
            for expected_attempt in (1, 2):
                before_length = len(messages)
                verdict = stop(agent, messages, {'role': 'assistant', 'content': 'Stopping.'})
                self.assertTrue(verdict.continue_turn)
                self.assertEqual(expected_attempt, agent._kanban_stop_nudges)
                self.assertEqual(before_length + 2, len(messages))
            before = list(messages)
            verdict = stop(agent, messages, {'role': 'assistant', 'content': 'Budget reached.'})
            self.assertFalse(verdict.continue_turn)
            self.assertEqual('Budget reached.', verdict.final_response)
            self.assertEqual(2, agent._kanban_stop_nudges)
            self.assertEqual(before, messages)


unittest.main(argv=[sys.argv[0]])
PY
