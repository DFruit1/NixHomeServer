"""Bounded token anomaly containment in the existing no-agent supervisor.

Only optional proactive intake is held. Existing work, reviews, recovery,
provider limits and owner/deploy gates retain their native rules.
"""
import copy
import json
import os
from pathlib import Path
import time

from hermes_common import atomic_write

FRESH_SECONDS = 900
MIN_WINDOW_TOKENS = 1_000_000
SPIKE_MULTIPLIER = 3


def intake_hold(state, now):
    return (not isinstance(state, dict) or not isinstance(state.get('generated_at'),(int,float))
            or not 0 <= now-state['generated_at'] <= FRESH_SECONDS
            or state.get('hold_intake') is not False)


def evaluate(summary, previous, now):
    state=copy.deepcopy(previous)
    state.update(schema_version=1,generated_at=now)
    pending=state.setdefault('pending',{})
    active=state.setdefault('active',{})
    candidates={}
    measurements={}
    stamp=summary.get('generated_at',0)
    fresh=isinstance(stamp,(int,float)) and 0 <= now-stamp <= FRESH_SECONDS
    sources=summary.get('sources',{})
    metrics=summary.get('guard_metrics',{})
    if not fresh or not summary.get('export_ok') or metrics.get('status')!='observed':
        candidates['coverage:langfuse']='Token evidence unavailable; inspect collector, authentication and ingestion.'
    for source in ('codex','opencode'):
        if fresh and sources.get(source,{}).get('status')!='observed':
            candidates['coverage:'+source]='Native usage coverage incomplete; inspect bounded cursor or source availability.'
    for name,value in sources.get('llama.cpp',{}).items():
        if fresh and value.get('status')!='observed':
            candidates['coverage:llama.cpp']='Engine counters unavailable; inspect local inference metrics.'
    if fresh and metrics.get('status')=='observed':
        baseline={r['model']:r for r in metrics['baseline']}
        for row in metrics['recent']:
            model=row['model'];old=baseline.get(model)
            if old is None or old['count_count']<20:continue
            tokens=row['sum_inputTokens']+row['sum_outputTokens']
            expected=(old['sum_inputTokens']+old['sum_outputTokens'])/24
            measurements[model]={'tokens_15m':tokens,'baseline_tokens_15m':expected}
            if tokens>=MIN_WINDOW_TOKENS and tokens>SPIKE_MULTIPLIER*expected:
                candidates['token_spike:'+model]='Sustained token rate exceeds the prior six-hour baseline; inspect contributing sessions and original-task progress.'
    # Only distinct five-minute samples count. Re-reading a checkpoint cannot
    # confirm a spike or clear an incident; stale evidence still advances a
    # coverage incident on the real clock.
    sample=int(now//300) if not fresh else int(stamp//300)
    distinct=sample>state.get('sample',-1)
    if distinct:
        state['sample']=sample
        for key in set(pending)|set(active)|set(candidates):
            if key in candidates:
                item=pending.setdefault(key,{'first_seen':now,'samples':0})
                item['samples']+=1
                if item['samples']>=3 and now-item['first_seen']>=600:
                    active[key]=candidates[key]
            elif key not in active:pending.pop(key,None)
        if candidates:state['healthy_samples']=0
        else:state['healthy_samples']=state.get('healthy_samples',0)+1
        if state['healthy_samples']>=2:active.clear();pending.clear()
    if active and not state.get('incident'):state['incident']=int(now)
    if not active:state.pop('incident',None)
    state.update(hold_intake=bool(active),measurements=measurements,
                 note='Tokens include cache; engine counters are excluded. No billing inference. Runbook: documentation/langfuse.md#token-guards-and-alerts')
    return state


def read(path):
    try:
        if path.is_symlink() or path.stat().st_size>131072:raise ValueError('Invalid usage state')
        value=json.loads(path.read_text())
        return value if isinstance(value,dict) else {}
    except (OSError,ValueError):return {}


def main():
    root=Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes')))
    directory=root/'state/agent-usage'
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    state=evaluate(read(directory/'summary.json'),read(directory/'guard.json'),time.time())
    atomic_write(directory/'guard.json',json.dumps(state,sort_keys=True)+'\n',mode=0o600)
    for key in sorted(state['active']):
        print('TOKEN_GUARD '+key+' incident='+str(state['incident'])+' hold=proactive-intake')


if __name__=='__main__':main()
