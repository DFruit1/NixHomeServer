#!/usr/bin/env python3
"""Bridge native coding-agent counters to private Langfuse, without inference.

Python operations glue shares Hermes/OpenCode's SQLite and JSON interfaces and
the existing Python installers/reports. It adds no backend or dependency. OTLP
HTTP/JSON avoids coupling this scheduled collector to an agent's managed SDK
environment. Only allowlisted usage/identity fields leave the workstation.
"""
import argparse
import base64
from contextlib import contextmanager
import copy
import datetime as dt
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import sys
import time
import urllib.parse
import urllib.request

from agent_usage_report import read_summary
from hermes_common import atomic_write

VERSION = '1'
MAX_FILES, MAX_BYTES, MAX_LINE, MAX_SPANS = 512, 32*1024*1024, 1024*1024, 1000


def label(value):
    return value if isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9_.:/@+-]{1,180}',value) and not value.startswith(('sk-','pk-lf-')) else 'unknown'


def token_details(input_tokens, output_tokens, cached=0, cache_write=0, *, inclusive=False):
    if any(type(x) is not int or x<0 for x in (input_tokens,output_tokens,cached,cache_write)):
        raise ValueError('Invalid token counter')
    uncached=input_tokens-cached-cache_write if inclusive else input_tokens
    if uncached<0:raise ValueError('Cache exceeds prompt counter')
    result={'input':uncached,'output':output_tokens}
    if cached:result['cache_read_input_tokens']=cached
    if cache_write:result['cache_creation_input_tokens']=cache_write
    result['total']=uncached+cached+cache_write+output_tokens
    return result


def identity(value, size=32):
    return hashlib.sha256(value.encode()).hexdigest()[:size]


def attribute(key,value):
    kind='boolValue' if type(value) is bool else 'intValue' if type(value) is int else 'doubleValue' if type(value) is float else 'stringValue'
    return {'key':key,'value':{kind:str(value) if kind=='intValue' else value}}


def attributes(span):
    result={x['key']:next(iter(x['value'].values())) for x in span['attributes']}
    return {k:int(v) if next(iter(x['value']))=='intValue' else v
            for x in span['attributes'] for k,v in [(x['key'],result[x['key']])]}


def observation(source,session,event,stamp,model,details,metadata=None,*,kind='generation'):
    nanos=str(int(stamp*1_000_000_000))
    values={'langfuse.observation.type':kind,'langfuse.environment':'nixhomeserver',
            'langfuse.session.id':label(session),'langfuse.trace.name':source+' usage',
            'langfuse.observation.metadata.source':source,
            'langfuse.observation.metadata.capture_mode':'metadata',
            'langfuse.observation.metadata.accounting_version':VERSION,
            'langfuse.observation.metadata.cost_status':'unknown',
            'langfuse.observation.metadata.recorded_at':dt.datetime.fromtimestamp(stamp,dt.timezone.utc).isoformat()}
    if kind=='generation':
        values['langfuse.observation.model.name']=label(model)
        values['langfuse.observation.usage_details']=json.dumps(details,separators=(',',':'))
    for key,value in (metadata or {}).items():
        if isinstance(value,(str,int,float,bool)):
            values['langfuse.observation.metadata.'+key]=value
    return {'traceId':identity(source+':'+session),'spanId':identity(source+':'+session+':'+event,16),
            'name':source+' usage','kind':1,'startTimeUnixNano':nanos,'endTimeUnixNano':nanos,
            'attributes':[attribute(k,v) for k,v in values.items()],'status':{'code':1}}


def project_name(cwd):
    path=Path(cwd or 'unknown')
    # T3 worktree names identify branches; their parent identifies the project.
    return label(path.parent.name if '/.t3/worktrees/' in str(path) else path.name)


def timestamp(value):
    return dt.datetime.fromisoformat(value.replace('Z','+00:00')).timestamp()


def codex_records(path, previous, *, since, byte_limit=MAX_BYTES, span_limit=MAX_SPANS):
    state=copy.deepcopy(previous);spans=[]
    stat=path.stat()
    if stat.st_size<state.get('offset',0) or state.get('inode',stat.st_ino)!=stat.st_ino:
        state={}
    state['inode']=stat.st_ino
    with path.open('rb') as stream:
        stream.seek(state.get('offset',0));started=stream.tell()
        while stream.tell()-started<byte_limit and len(spans)<span_limit:
            if state.get('discarding'):
                fragment=stream.readline(min(65536,byte_limit-(stream.tell()-started)))
                if not fragment:break
                state['offset']=stream.tell()
                if fragment.endswith(b'\n'):state.pop('discarding',None)
                continue
            remaining=byte_limit-(stream.tell()-started)
            line=stream.readline(min(MAX_LINE+1,remaining))
            if not line:break
            if not line.endswith(b'\n'):
                if len(line)<=MAX_LINE:break  # An actively written record is retried.
                state['discarding']=True
                state['offset']=stream.tell()
                continue  # Large content drains across passes; never exported.
            state['offset']=stream.tell()
            if not any(marker in line for marker in (b'"session_meta"',b'"turn_context"',b'"token_count"')):continue
            try:record=json.loads(line)
            except (ValueError,UnicodeDecodeError):continue
            payload=record.get('payload') or {}
            if record.get('type')=='session_meta':
                state.update(session=label(payload.get('id') or payload.get('session_id')),
                             project=project_name(payload.get('cwd')))
                try:state['created']=timestamp(payload.get('timestamp') or record.get('timestamp'))
                except (ValueError,TypeError,AttributeError):state['created']=0
            elif record.get('type')=='turn_context':state['model']=label(payload.get('model'))
            elif record.get('type')=='event_msg' and payload.get('type')=='token_count':
                info=payload.get('info') or {};total=info.get('total_token_usage')
                if not isinstance(total,dict):continue
                keys=('input_tokens','output_tokens','cached_input_tokens','cache_write_input_tokens','reasoning_output_tokens')
                current={k:total.get(k,0) for k in keys}
                if any(type(v) is not int or v<0 for v in current.values()):continue
                old=state.get('total',{})
                if current==old:continue  # Limit updates repeat the preceding usage event.
                reset=any(current[k]<old.get(k,0) for k in keys)
                delta={k:current[k]-(0 if reset else old.get(k,0)) for k in keys}
                try:
                    details=token_details(delta['input_tokens'],delta['output_tokens'],delta['cached_input_tokens'],
                                          delta['cache_write_input_tokens'],inclusive=True)
                    stamp=timestamp(record['timestamp'])
                except (ValueError,KeyError,TypeError):
                    state['invalid_usage']=state.get('invalid_usage',0)+1;continue
                state['total']=current
                if stamp<max(since,state.get('created',0)) or not details['total']:continue
                event=record['timestamp']+json.dumps(current,sort_keys=True)
                spans.append(observation('codex-cli',state.get('session',identity(str(path))),event,stamp,
                    state.get('model','unknown'),details,{'project':state.get('project','unknown'),
                    'reasoning_tokens':delta['reasoning_output_tokens'],'counter_reset':reset,
                    'cost_status':'subscription_or_api_unknown'}))
        state['read_bytes']=stream.tell()-started
    state['pending']=state.get('offset',0)<stat.st_size or bool(state.get('discarding'))
    return spans,state


@contextmanager
def readonly(path):
    db=sqlite3.connect(path.absolute().as_uri()+'?mode=ro',uri=True,timeout=.5)
    deadline=time.monotonic()+5
    db.set_progress_handler(lambda:int(time.monotonic()>deadline),10000)
    db.execute('PRAGMA query_only=ON')
    try:yield db
    finally:db.close()


def opencode_records(path, previous, *, since):
    states=copy.deepcopy(previous);spans=[];bounded=False;remaining_rows=MAX_SPANS
    with readonly(path) as db:
        if db.execute("SELECT 1 FROM sqlite_master WHERE type='table' AND name='session_v2'").fetchone():
            return opencode_v2_records(db,previous,since=since)
        sessions=db.execute('SELECT id,directory FROM session WHERE time_updated>=? ORDER BY time_updated DESC LIMIT 513',
                            (int(since*1000),)).fetchall()
        bounded=len(sessions)>512
        for session,cwd in sessions[:512]:
            row_limit=remaining_rows+1
            rows=db.execute("SELECT p.id,p.time_created,json_extract(p.data,'$.type'),"
                "json_extract(p.data,'$.tokens'),json_extract(m.data,'$.modelID'),json_extract(m.data,'$.providerID') "
                "FROM part p LEFT JOIN message m ON m.id=p.message_id WHERE p.session_id=? AND p.id>? "
                'ORDER BY p.id LIMIT ?', (session,states.get(session,''),row_limit)).fetchall()
            bounded=bounded or len(rows)==row_limit
            for part,created,kind,tokens,model,provider in rows[:remaining_rows]:
                remaining_rows-=1
                states[session]=part
                if kind!='step-finish' or created/1000<since or not tokens:continue
                tokens=json.loads(tokens);cache=tokens.get('cache') or {};reason=tokens.get('reasoning',0)
                # OpenCode stores text output separately from reasoning output.
                details=token_details(tokens.get('input',0),tokens.get('output',0)+reason,
                                      cache.get('read',0),cache.get('write',0))
                if not details['total']:continue
                spans.append(observation('opencode-cli',session,part,created/1000,model,details,
                    {'project':project_name(cwd),'provider_route':label(provider),'reasoning_tokens':reason}))
            if remaining_rows==0:bounded=True;break
    states={k:v for k,v in states.items() if any(k==row[0] for row in sessions[:512])}
    return spans,states,bounded


def opencode_v2_records(db,previous,*,since):
    """V2 retains V1 tables; choose its current message projection explicitly.

    Cursor on updated time, not message sequence: a streamed message can finish
    after a later message. Deterministic message IDs also permit final corrections.
    """
    states=copy.deepcopy(previous.get('sessions',{})) if previous.get('schema')==2 else {}
    sessions=db.execute('SELECT id,directory,time_created FROM session_v2 WHERE time_updated>=? '
                        'ORDER BY time_updated DESC LIMIT 513',(int(since*1000),)).fetchall()
    spans=[];bounded=len(sessions)>512;remaining=MAX_SPANS
    for session,cwd,created in sessions[:512]:
        cursor=states.get(session,{});updated=cursor.get('updated',int(since*1000));last_id=cursor.get('id','')
        rows=db.execute("SELECT id,time_updated,type,json_extract(data,'$.tokens'),json_extract(data,'$.model'),"
            "json_extract(data,'$.time.completed') FROM session_message WHERE session_id=? "
            'AND time_created>=? '
            "AND type IN ('assistant','compaction') AND (time_updated>? OR (time_updated=? AND id>?)) "
            "AND json_extract(data,'$.tokens') IS NOT NULL AND (json_extract(data,'$.time.completed') IS NOT NULL "
            "OR (type='compaction' AND json_extract(data,'$.status') IN ('completed','failed'))) "
            'ORDER BY time_updated,id LIMIT ?', (session,created,updated,updated,last_id,remaining+1)).fetchall()
        bounded=bounded or len(rows)>remaining
        for message,modified,kind,raw,model,completed in rows[:remaining]:
            tokens=json.loads(raw);cache=tokens.get('cache') or {};reason=tokens.get('reasoning',0)
            details=token_details(tokens.get('input',0),tokens.get('output',0)+reason,
                                  cache.get('read',0),cache.get('write',0))
            model=json.loads(model or '{}')
            states[session]={'updated':modified,'id':message};remaining-=1
            if not details['total']:continue
            spans.append(observation('opencode-cli',session,message,(completed or modified)/1000,
                model.get('id'),details,{'project':project_name(cwd),'provider_route':label(model.get('providerID')),
                'reasoning_tokens':reason,'native_schema':2,'aux_task':kind}))
        if not remaining:bounded=True;break
    states={k:v for k,v in states.items() if any(k==row[0] for row in sessions[:512])}
    return spans,{'schema':2,'sessions':states},bounded


def engine_record(text,name,now):
    names={'llamacpp:prompt_tokens_total':'input_tokens','llamacpp:prompt_tokens_cached_total':'cache_read_tokens',
           'llamacpp:tokens_predicted_total':'output_tokens'}
    values={}
    for line in text.splitlines():
        fields=line.split()
        if len(fields)==2 and fields[0] in names:
            value=float(fields[1])
            if not math.isfinite(value) or value<0:raise ValueError('Invalid engine counter')
            values[names[fields[0]]]=int(value)
    if values.keys()!=set(names.values()):raise ValueError('Missing engine counters')
    span=observation('llama.cpp-engine',name,str(int(now//300)),now,'',None,
                     {'engine':label(name),'accounting':'overlaps_agent_generations_do_not_add',**values},kind='span')
    return span,values


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None


def request(url, *, headers=None, data=None):
    opener=urllib.request.build_opener(NoRedirect)
    req=urllib.request.Request(url,data=data,headers=headers or {})
    with opener.open(req,timeout=10) as response:
        body=response.read(2*1024*1024+1)
        if len(body)>2*1024*1024:raise ValueError('Response bound exceeded')
        return body


def credentials(config):
    token=base64.b64encode((config['public_key']+':'+config['secret_key']).encode()).decode()
    return {'Authorization':'Basic '+token,'Content-Type':'application/json','x-langfuse-ingestion-version':'4'}


def send(config, spans):
    deadline=time.monotonic()+45
    for offset in range(0,len(spans),128):
        if time.monotonic()>deadline:raise TimeoutError('Export deadline exceeded')
        batch={'resourceSpans':[{'resource':{'attributes':[attribute('service.name','nixhomeserver-agent-usage')]},
            'scopeSpans':[{'scope':{'name':'nixhomeserver.agent-usage','version':VERSION},'spans':spans[offset:offset+128]}]}]}
        body=request(config['base_url']+'/api/public/otel/v1/traces',headers=credentials(config),
                     data=json.dumps(batch,separators=(',',':')).encode())
        result=json.loads(body or '{}')
        partial=result.get('partialSuccess',{})
        if int(partial.get('rejectedSpans',0)) or partial.get('errorMessage'):
            raise ValueError('Partial telemetry rejection')


def coordinator_records(root, previous, *, since, until):
    """Completed native runs, not feature acceptance or extra token usage.

    A completion cohort includes runs started before the window. Session model
    is only attributed through a recorded native link, never today's config.
    """
    spans=[];state={};errors=0;bounded=False;remaining=1000
    paths=sorted(p for p in (root/'kanban/boards').glob('*/kanban.db')
                 if not p.parent.name.startswith(('.', '_')))
    for path in paths[:32]:
        if not remaining:
            bounded=True;break
        try:
            with readonly(path) as db:
                rows=db.execute("""SELECT r.id,r.task_id,r.status,r.outcome,r.started_at,r.ended_at,
                    CASE WHEN json_valid(r.metadata) THEN json_extract(r.metadata,'$.worker_session_id') END,
                    (SELECT count(*) FROM task_runs p WHERE p.task_id=r.task_id
                       AND p.profile=r.profile AND p.id<=r.id)
                    FROM task_runs r WHERE r.profile='head-coordinator' AND r.ended_at>=? AND r.ended_at<?
                    AND r.status!='running' ORDER BY r.ended_at DESC,r.id DESC LIMIT ?""",
                    (since,until,remaining+1)).fetchall()
            bounded=bounded or len(rows)>remaining
            selected=rows[:remaining];remaining-=len(selected)
            for run,card,status,outcome,start,end,session,attempt in selected:
                if type(start) not in (int,float) or type(end) not in (int,float) or not math.isfinite(start) or not math.isfinite(end) or end<start:
                    errors+=1;continue
                session=label(session)
                model='unknown'
                if session!='unknown':
                    try:
                        with readonly(root/'profiles/head-coordinator/state.db') as db:
                            row=db.execute('SELECT model FROM sessions WHERE id=?',(session,)).fetchone()
                        model=label(row[0]) if row else 'unknown'
                    except (OSError,sqlite3.Error):pass
                metadata={'profile':'head-coordinator','board':label(path.parent.name),'card_id':label(card),
                          'run_id':str(run),'status':label(status),'outcome':label(outcome),
                          'elapsed_seconds':end-start,'attempt':attempt,'session_model':model,
                          'session_linked':session!='unknown','capture_mode':'metadata'}
                key=path.parent.name+':'+str(run)
                fingerprint=identity(json.dumps(metadata,sort_keys=True)+str(start)+str(end))
                state[key]=fingerprint
                if previous.get(key)==fingerprint:continue
                span=observation('hermes-kanban-run',key,key,end,'',{},metadata,kind='span')
                if session!='unknown':
                    span['attributes']=[attribute(a['key'],session) if a['key']=='langfuse.session.id' else a
                                        for a in span['attributes']]
                span['name']='Hermes coordinator run'
                span['startTimeUnixNano']=str(int(start*1_000_000_000))
                if status in {'failed','crashed','timed_out','spawn_failed','gave_up'}:
                    span['status']={'code':2}
                spans.append(span)
        except (OSError,sqlite3.Error,TypeError,ValueError):errors+=1
    return spans,state,{'status':'unavailable' if not paths else 'partial' if errors else
                        'bounded' if bounded or len(paths)>32 else 'observed',
                        'boards':min(len(paths),32),'errors':errors,'exported':len(spans)}


def collect(config, previous, now):
    state=copy.deepcopy(previous);state.setdefault('codex',{});spans=[];sources={}
    since=now-86400  # Explicit initial/backfill horizon, not a claim about older history.
    try:
        with readonly(config['codex_home']/'state_5.sqlite') as db:
            files=db.execute('SELECT rollout_path FROM threads WHERE updated_at>=? ORDER BY updated_at DESC LIMIT 513',
                             (int(since),)).fetchall()
        consumed=0;invalid=0;pending=0;invalid_usage=0
        for (filename,) in files[:MAX_FILES]:
            if len(spans)>=MAX_SPANS or consumed>=MAX_BYTES:break
            path=Path(filename)
            if not path.resolve().is_relative_to(config['codex_home'].resolve()):continue
            old=state['codex'].get(filename,{})
            try:
                new_spans,new=codex_records(path,old,since=since,byte_limit=min(MAX_BYTES-consumed,8*1024*1024),
                                             span_limit=MAX_SPANS-len(spans))
                consumed+=new['read_bytes']
                pending+=bool(new.get('pending'))
                invalid_usage+=new.get('invalid_usage',0)
                state['codex'][filename]=new;spans.extend(new_spans)
            except (OSError,ValueError):invalid+=1
        sources['codex']={'status':'partial' if invalid or invalid_usage else
                          'bounded' if pending or len(files)>MAX_FILES or consumed>=MAX_BYTES or len(spans)>=MAX_SPANS else 'observed',
                          'files':min(len(files),MAX_FILES),'pending_files':pending,'bytes_read':consumed,
                          'errors':invalid,'invalid_usage':invalid_usage,'exported':len(spans)}
    except (OSError,sqlite3.Error):sources['codex']={'status':'unavailable'}
    try:
        new_spans,new,bounded=opencode_records(config['opencode_db'],state.get('opencode',{}),since=since)
        state['opencode']=new;spans.extend(new_spans)
        sources['opencode']={'status':'bounded' if bounded or len(new_spans)>=MAX_SPANS else 'observed','exported':len(new_spans)}
    except (OSError,sqlite3.Error,ValueError,TypeError):sources['opencode']={'status':'unavailable'}
    new_spans,new,coverage=coordinator_records(config['root'],state.get('coordinator_runs',{}),since=since,until=now)
    state['coordinator_runs']=new;spans.extend(new_spans);sources['coordinator_runs']=coverage
    sources['llama.cpp']={}
    for name,endpoint in config['llama_endpoints'].items():
        try:
            span,counters=engine_record(request(endpoint+'/metrics').decode(),name,now)
            spans.append(span);sources['llama.cpp'][name]={'status':'observed',**counters,
                'note':'Engine lifetime counters overlap agent generations; never sum both.'}
        except (OSError,ValueError):sources['llama.cpp'][name]={'status':'unavailable'}
    state['codex']={k:v for k,v in state['codex'].items() if any(k==row[0] for row in files)} if 'files' in locals() else state['codex']
    return spans,state,sources


def metrics(config,now):
    query={'view':'observations','dimensions':[{'field':'providedModelName'}],
           'metrics':[{'measure':m,'aggregation':a} for m,a in [('count','count'),('inputTokens','sum'),('outputTokens','sum'),('totalTokens','sum')]],
           'filters':[{'column':'type','operator':'=','value':'GENERATION','type':'string'}],
           'fromTimestamp':dt.datetime.fromtimestamp(now-86400,dt.timezone.utc).isoformat(),
           'toTimestamp':dt.datetime.fromtimestamp(now,dt.timezone.utc).isoformat(),'config':{'row_limit':1000}}
    payload=json.loads(request(config['base_url']+'/api/public/v2/metrics?'+urllib.parse.urlencode({'query':json.dumps(query)}),
                               headers=credentials(config)))
    rows=payload['data']
    if not isinstance(rows,list) or len(rows)>=1000:raise ValueError('Metrics bound exceeded')
    return [{'model':label(row.get('providedModelName')),
             **{k:int(row[k]) for k in ('count_count','sum_inputTokens','sum_outputTokens','sum_totalTokens')}} for row in rows]


def atomic_json(path,value):
    atomic_write(path,json.dumps(value,sort_keys=True,separators=(',',':'))+'\n',mode=0o600)


def run(config):
    now=time.time();directory=config['state_dir'];checkpoint=directory/'checkpoint.json'
    previous=json.loads(checkpoint.read_text()) if checkpoint.exists() else {}
    report={'schema_version':1,'generated_at':now,'export_ok':False,'billing':'Unknown: tokens are not subscription invoices.',
            'window_start':now-86400,'window_end':now,'url':config['base_url']}
    try:
        spans,state,sources=collect(config,previous,now);report['sources']=sources
        send(config,spans)
        state['last_success']=now;atomic_json(checkpoint,state)
        report.update(export_ok=True,exported_observations=len(spans))
    except Exception as exc:
        # Provider/HTTP exceptions can contain credentials and private payloads.
        report['error_kind']=type(exc).__name__
    try:report['models']=metrics(config,now);report['metrics_status']='observed'
    except Exception as exc:report['metrics_status']='unavailable';report['metrics_error_kind']=type(exc).__name__
    atomic_json(directory/'summary.json',report)
    return report


NATIVE_CONTEXT_V1 = '''
# BEGIN nixhomeserver-langfuse-usage-v1
def _nixhomeserver_usage_context(provider, model, base_url, usage=None):
    from hermes_constants import get_hermes_home
    from urllib.parse import urlsplit
    home = get_hermes_home()
    host = urlsplit(base_url).hostname or ""
    route = ("codex" if provider == "openai-codex" else
             "opencode-go" if host == "opencode.ai" else
             "llamacpp-local" if host in {"127.0.0.1", "localhost", "::1"} else "other")
    metadata = {"source": "hermes", "accounting_version": "1",
                "provider_route": route,
                "profile": home.name if home.parent.name == "profiles" else "default",
                "cost_status": "subscription_included" if route in {"codex", "opencode-go"} else
                               "local_inference" if route == "llamacpp-local" else "unknown",
                "cost_note": "Model price estimates are not subscription invoices or local operating cost."}
    for key, variable in (("board", "HERMES_KANBAN_BOARD"), ("card_id", "HERMES_KANBAN_TASK"),
                          ("run_id", "HERMES_KANBAN_RUN_ID")):
        value = os.environ.get(variable, "")
        if value and re.fullmatch(r"[A-Za-z0-9_.:-]{1,120}", value): metadata[key] = value
    if isinstance(usage, dict): metadata["reasoning_tokens"] = usage.get("reasoning_tokens", 0)
    return metadata
# END nixhomeserver-langfuse-usage-v1
'''


NATIVE_CONTEXT = NATIVE_CONTEXT_V1.replace('langfuse-usage-v1', 'langfuse-usage-v2').replace(
    'base_url, usage=None):', 'base_url, usage=None, request=None):').replace(
    '    return metadata\n',
    '    body = request.get("body") if isinstance(request, dict) else None\n'
    '    if isinstance(body, dict):\n'
    '        reasoning = body.get("reasoning")\n'
    '        effort = reasoning.get("effort") if isinstance(reasoning, dict) else body.get("reasoning_effort")\n'
    '        if isinstance(effort, str) and effort in {"none", "minimal", "low", "medium", "high", "xhigh", "max"}:\n'
    '            metadata["reasoning_effort"] = effort\n'
    '    if isinstance(request, dict) and isinstance(request.get("wire_reasoning_effort"), str) and request.get("wire_reasoning_effort") in {"none", "minimal", "low", "medium", "high", "xhigh", "max"}:\n'
    '        metadata["reasoning_effort"] = request["wire_reasoning_effort"]\n'
    '    return metadata\n')


def patch_native(text):
    if '# BEGIN nixhomeserver-langfuse-usage-v2' in text:
        if not text.endswith(NATIVE_CONTEXT) or '_nixhomeserver_usage_context(provider, model, base_url, request=request)' not in text:
            raise ValueError('Native telemetry adapter drift')
        return text
    if '# BEGIN nixhomeserver-langfuse-usage-v1' in text:
        if not text.endswith(NATIVE_CONTEXT_V1) or 'usage_details["total"] = canonical.total_tokens' not in text:
            raise ValueError('Native telemetry adapter drift')
        text=text[:-len(NATIVE_CONTEXT_V1)]
    else:
        replacements=[
            ('    ("reasoning_tokens", "reasoning_tokens", None),\n',''),
            ('    cost_details: Dict[str, float] = {}\n','    usage_details["total"] = canonical.total_tokens\n    cost_details: Dict[str, float] = {}\n'),
            ('        gen_metadata = {\n','        gen_metadata = {**_nixhomeserver_usage_context(provider, model, base_url),\n'),
            ('    gen_metadata = {"tool_call_count":','    gen_metadata = {**_nixhomeserver_usage_context(provider, model, base_url, usage=usage), "tool_call_count":')]
        for before,after in replacements:
            if text.count(before)!=1:raise ValueError('Unsupported native Langfuse plugin; qualify its source before installation')
            text=text.replace(before,after)
    before='_nixhomeserver_usage_context(provider, model, base_url)'
    if text.count(before)!=1:raise ValueError('Unsupported native generation context')
    text=text.replace(before,'_nixhomeserver_usage_context(provider, model, base_url, request=request)')
    text=text.rstrip()+'\n'+NATIVE_CONTEXT
    compile(text,'langfuse-usage-adapter','exec')
    return text


HOOK_ORIGINAL = '        return self._sanitize_hook_payload({"method": "POST", "body": body})'
HOOK_PATCH = '        # nixhomeserver: preserve only wire effort outside the content size cap.\n        payload = self._sanitize_hook_payload({"method": "POST", "body": body})\n        reasoning = body.get("reasoning")\n        effort = reasoning.get("effort") if isinstance(reasoning, dict) else body.get("reasoning_effort")\n        if (isinstance(payload, dict) and isinstance(effort, str)\n                and effort in {"none", "minimal", "low", "medium", "high", "xhigh", "max"}):\n            payload["wire_reasoning_effort"] = effort\n        return payload'


def patch_request_hook(text):
    if 'nixhomeserver: preserve only wire effort' in text:
        if text.count(HOOK_PATCH)!=1:raise ValueError('Wire reasoning hook adapter drift')
        return text
    if text.count(HOOK_ORIGINAL)!=1:raise ValueError('Unsupported native request hook')
    text=text.replace(HOOK_ORIGINAL,HOOK_PATCH)
    compile(text,'request-effort-adapter','exec')
    return text


def configuration(args):
    root=Path(args.root).expanduser().absolute();env=root/'.env'
    values={}
    # Read existing values in memory. Never evaluate a dotenv file as shell.
    for line in env.read_text().splitlines():
        key,sep,value=line.partition('=')
        if sep and key.startswith('HERMES_LANGFUSE_'):values[key]=value.strip().strip('\"\'')
    url=values['HERMES_LANGFUSE_BASE_URL'].rstrip('/')
    parts=urllib.parse.urlsplit(url)
    if parts.scheme!='https' or parts.username or parts.password or parts.query or parts.fragment:
        raise ValueError('Private HTTPS Langfuse origin required')
    return {'root':root,'base_url':url,'public_key':values['HERMES_LANGFUSE_PUBLIC_KEY'],
            'secret_key':values['HERMES_LANGFUSE_SECRET_KEY'],'codex_home':Path.home()/'.codex',
            'opencode_db':Path.home()/'.local/share/opencode/opencode.db',
            'state_dir':root/'state/agent-usage','llama_endpoints':{'qwen-local':'http://127.0.0.1:8093'}}


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--root',default=os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes')))
    parser.add_argument('--report',action='store_true',help='Read cached counters without credentials or network')
    args=parser.parse_args();directory=Path(args.root).expanduser()/'state/agent-usage'
    if args.report:
        print(json.dumps(read_summary(directory/'summary.json'),sort_keys=True));return 0
    config=configuration(args);directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    with (directory/'collector.lock').open('a') as lock:
        try:fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        except BlockingIOError:print('Existing usage collection is active.');return 0
        report=run(config)
    print(json.dumps({k:report[k] for k in ('generated_at','export_ok','exported_observations','error_kind','metrics_status') if k in report}))
    return 0 if report['export_ok'] else 1


if __name__=='__main__':
    try:sys.exit(main())
    except Exception as exc:
        print('Agent usage collection unavailable ('+type(exc).__name__+').',file=sys.stderr);sys.exit(1)
