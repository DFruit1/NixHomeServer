#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
python3 -B - "$repo" <<'PY'
import sys, unittest, tempfile, json
from pathlib import Path
sys.path.insert(0,str(Path(sys.argv[1])/'scripts/hermes'))
from agent_usage_guard import evaluate, intake_hold
from agent_usage_report import render_summary

def summary(now, recent=2000000, baseline=2400000):
    return {'generated_at':now,'export_ok':True,'metrics_status':'observed',
        'sources':{'codex':{'status':'observed'},'opencode':{'status':'observed'},
                   'llama.cpp':{'qwen':{'status':'observed'}}},
        'guard_metrics':{'status':'observed','window_end':now-900,
            'recent':[{'model':'example','sum_inputTokens':recent,'sum_outputTokens':0,'count_count':20}],
            'baseline':[{'model':'example','sum_inputTokens':baseline,'sum_outputTokens':0,'count_count':100}]}}

class GuardTest(unittest.TestCase):
    def test_coverage_hold_remains_visible_when_export_is_failed_or_stale(self):
        with tempfile.TemporaryDirectory(prefix='usage-guard-report-') as tmp:
            root=Path(tmp);directory=root/'state/agent-usage';directory.mkdir(parents=True)
            (directory/'guard.json').write_text(json.dumps({'generated_at':10000,'hold_intake':True,
                'active':{'coverage:langfuse':'Export failed'}}))
            for stamp in (1,10000):
                (directory/'summary.json').write_text(json.dumps({'generated_at':stamp,'export_ok':False}))
                result='\n'.join(render_summary(root,now=10001))
                self.assertIn('token coverage unknown',result)
                self.assertIn('proactive intake held: coverage:langfuse',result)

    def test_sustained_burn_contains_only_new_proactive_intake(self):
        state={}
        for now in (10000,10300,10600):state=evaluate(summary(now),state,now)
        self.assertTrue(state['hold_intake'])
        self.assertEqual(['token_spike:example'],list(state['active']))
        self.assertTrue(intake_hold(state,10601))
        self.assertIn('2000000',str(state['measurements']))
        self.assertNotIn('estimated_cost',str(state))

    def test_repeated_or_out_of_order_sample_does_not_confirm_incident(self):
        state=evaluate(summary(10000),{},10000)
        state=evaluate(summary(10000),state,10300)
        self.assertFalse(state['hold_intake'])
        self.assertEqual(1,state['pending']['token_spike:example']['samples'])

    def test_absolute_floor_and_baseline_both_required(self):
        for recent,baseline in ((100,0),(2000000,96000000)):
            state={}
            for now in (10000,10300,10600):state=evaluate(summary(now,recent,baseline),state,now)
            self.assertFalse(state['hold_intake'])

    def test_insufficient_baseline_is_unknown_not_a_spike(self):
        d=summary(10000);d['guard_metrics']['baseline']=[]
        state=evaluate(d,{},10000)
        self.assertNotIn('token_spike:example',state['pending'])

    def test_missing_metrics_is_an_actionable_coverage_hold(self):
        state={}
        for now in (10000,10300,10600):
            d=summary(now);d['guard_metrics']={'status':'unavailable'}
            state=evaluate(d,state,now)
        self.assertTrue(state['hold_intake'])
        self.assertIn('coverage:langfuse',state['active'])

    def test_unavailable_or_stale_guard_cannot_authorize_intake(self):
        self.assertTrue(intake_hold({},10000))
        self.assertTrue(intake_hold({'generated_at':1,'hold_intake':False},10000))
        self.assertFalse(intake_hold({'generated_at':10000,'hold_intake':False},10001))

    def test_two_distinct_healthy_samples_clear_with_same_incident_until_then(self):
        state={}
        for now in (10000,10300,10600):state=evaluate(summary(now),state,now)
        incident=state['incident']
        state=evaluate(summary(10900,100,2400000),state,10900)
        self.assertTrue(state['hold_intake']);self.assertEqual(incident,state['incident'])
        state=evaluate(summary(11200,100,2400000),state,11200)
        self.assertFalse(state['hold_intake'])
        for now in (11500,11800,12100):state=evaluate(summary(now),state,now)
        self.assertNotEqual(incident,state['incident'])

if __name__=='__main__':unittest.main(argv=['usage-guard'])
PY
