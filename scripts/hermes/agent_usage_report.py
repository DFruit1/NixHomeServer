"""Read-only usage evidence for the owner and existing steward reports."""
import json
from pathlib import Path
import time


def read_summary(path, *, now=None):
    try:
        if path.is_symlink() or path.stat().st_size>131072:raise ValueError('Invalid summary')
        result=json.loads(path.read_text())
        age=(time.time() if now is None else now)-result['generated_at']
        result['status']='stale' if age<0 or age>900 else 'observed' if result['export_ok'] else 'export_failed'
        return result
    except (OSError,ValueError,KeyError,TypeError):return {'status':'unavailable'}


def render_summary(root, *, now=None):
    data=read_summary(Path(root)/'state/agent-usage/summary.json',now=now)
    if data['status']!='observed':return ['Agent usage: '+data['status']+'; token coverage unknown.']
    sources=data.get('sources',{})
    lines=['Agent usage: '+', '.join(name+'='+sources.get(name,{}).get('status','unknown')
                                   for name in ('codex','opencode'))+'.']
    if data.get('metrics_status')=='observed':
        lines.append('Langfuse rolling 24h input/output tokens (input includes cache):')
        for row in data.get('models',[])[:20]:
            lines.append('  '+row['model']+': '+str(row['sum_inputTokens'])+'/'+str(row['sum_outputTokens']))
    else:lines.append('Langfuse aggregate usage unavailable; do not infer zero.')
    for name,counters in sorted(sources.get('llama.cpp',{}).items()):
        if counters.get('status')!='observed':lines.append('llama.cpp '+name+': unavailable.');continue
        lines.append('llama.cpp '+name+' engine lifetime uncached/cached/output: '
                     +'/'.join(str(counters[k]) for k in ('input_tokens','cache_read_tokens','output_tokens'))
                     +'; overlaps agent generations, do not add.')
    lines.append('Usage is not subscription billing; actual cost remains unknown.')
    return lines
