"""Bound scheduled inspections and retain unprocessed changes without retry loops.

Python integration glue for Hermes' existing scheduler, SQLite and tool runtime.
The private journal contains hashes, IDs and counters, never prompt/credential
contents. It is scheduler state, not model memory or additional permissions.
"""
import contextvars
import copy
import datetime as dt
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import tempfile
import threading
import time

_active=contextvars.ContextVar('nixhomeserver_cron_run',default=None)


def root():return Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes')))


def rule(job):
    path=root()/'scripts/hermes-cron-policy.json'
    if not path.exists():return None
    entry=json.loads(path.read_text()).get('jobs',{}).get(job.get('id'))
    if entry is not None and (not re.fullmatch(r'[a-f0-9]+',job['id']) or
            any(type(entry.get(k)) is not int or entry[k]<=0 for k in ('turns','tools','seconds'))):
        raise ValueError('Invalid scheduled inspection policy')
    return entry


def state_path(job):return root()/'state/cron-policy'/(job['id']+'.json')


def save(path,data):
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    fd,temporary=tempfile.mkstemp(prefix='.'+path.name+'.',dir=path.parent)
    try:
        with os.fdopen(fd,'w') as stream:
            json.dump(data,stream,sort_keys=True);stream.write('\n');stream.flush();os.fsync(stream.fileno())
        os.replace(temporary,path)
    finally:
        if os.path.exists(temporary):os.unlink(temporary)


def identity(entry):
    """Config bytes stay in memory; auth files contribute only change metadata."""
    base=root();home=base/'profiles'/entry['profile']
    digest=hashlib.sha256()
    for path in (base/'config.yaml',home/'config.yaml'):
        if path.exists():digest.update(path.read_bytes())
    for path in (base/'auth.json',base/'.env',home/'auth.json',home/'.env'):
        if path.exists():
            stat=path.stat();digest.update(str((stat.st_mtime_ns,stat.st_size)).encode())
    return digest.hexdigest()


def current_job(job):
    from cron.jobs import get_job
    return get_job(job['id']) or job


def lost_failure(job):
    """Migrate only a failure coincident with the last consumed monitor change."""
    try:
        failure=dt.datetime.fromisoformat(job['last_failure']['at'])
        changed=dt.datetime.fromisoformat(job['monitor_state']['last_changed_at'])
        return abs((failure-changed).total_seconds())<=60
    except (KeyError,TypeError,ValueError):return False


def agent_kwargs(job,iterations):
    entry=rule(job)
    return ({'max_iterations':min(iterations,entry['turns']),'run_budget_seconds':entry['seconds']}
            if entry else {'max_iterations':iterations})


def bind(agent,job):
    entry=rule(job)
    if entry:
        context=_active.get()
        agent._nix_cron_budget={'calls':set(),'lock':threading.Lock(),'limit':entry['tools'],
                                'deadline':(context['started'] if context else time.monotonic())+entry['seconds'],'exhausted':False}
        if context is not None:context['agent']=agent
    return agent


def enforce_deadline(agent):
    budget=getattr(agent,'_nix_cron_budget',None)
    if budget and time.monotonic()>=budget['deadline']:
        budget['exhausted']=True
        agent.interrupt('Scheduled inspection runtime budget exhausted')
        raise TimeoutError('Scheduled inspection runtime budget exhausted; defer unverified questions')


def note_result(agent,result):
    budget=getattr(agent,'_nix_cron_budget',None)
    if budget and (result.get('completed') is False or result.get('failed') is True
                   or 'iteration' in str(result.get('turn_exit_reason',''))):
        budget['exhausted']=True


def tool_block(agent,call_id):
    budget=getattr(agent,'_nix_cron_budget',None)
    if not budget:return None
    with budget['lock']:
        expired=time.monotonic()>=budget['deadline']
        if not expired and call_id in budget['calls']:return None
        if len(budget['calls'])>=budget['limit'] or expired:
            budget['exhausted']=True
            return ('Scheduled inspection tool budget exhausted. No further tools are permitted. '
                    'Return verified findings only, or [SILENT] if none; defer unanswered questions. '
                    'Do not delegate or switch execution paths to continue this inspection.')
        budget['calls'].add(call_id)
    return None


def run(original,job,**kwargs):
    entry=rule(job)
    if not entry:return original(job,**kwargs)
    started=time.monotonic()
    path=state_path(job);path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    with path.with_suffix('.lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        state=json.loads(path.read_text()) if path.exists() else {}
        now=time.time();config=identity(entry);pending=state.get('pending')
        if not state and lost_failure(job):
            pending={'hash':job['monitor_state']['last_output_hash'],'identity':config,
                     'attempts':1,'next_retry':0}
            state['pending']=pending
        forwarded=copy.deepcopy(job)
        focus=None;stall=None
        if entry.get('kind')=='stall':
            try:
                if __package__=='cron':
                    from cron import nixhomeserver_cron_stall as stall
                else:
                    import cron_stall as stall
                focus=stall.collect(root(),state,now)
            except Exception:
                state['collection_error']=True;save(path,state)
                return False,'Scheduled inspection evidence unavailable','','Read-only evidence collection failed; no model started'
            state['collection_error']=False
            fingerprint=hashlib.sha256(json.dumps([(f['key'],f['version']) for f in focus]).encode()).hexdigest()
            failed=state.get('stall_pending') or {}
            stalled=(failed.get('hash')==fingerprint and failed.get('identity')==config
                     and (failed['attempts']>=3 or now<failed['next_retry']))
            if (not focus or stalled) and not kwargs.get('extra_prompt'):
                state['last_checked_at']=now;save(path,state)
                return True,'# Cron Job: stall inspection\n**Status:** no_change\nNo new or due evidence.\n','[SILENT]',None
            forwarded['script']=None  # Replace the broad collector with this bounded evidence packet.
            kwargs['extra_prompt']=(kwargs.get('extra_prompt') or '')+'\n\n'+stall.packet(focus,now)
        if pending and (config!=pending.get('identity') or
                        (pending['attempts']<3 and now>=pending['next_retry'])):
            forwarded.setdefault('monitor_state',{})['last_output_hash']=None
        elif pending and not kwargs.get('extra_prompt'):
            # Native automatic reruns can arrive with a reset in-memory hash.
            # They still obey this snapshot's cooldown/cap; new source content
            # remains detectable against the pending hash without any DB edit.
            forwarded.setdefault('monitor_state',{})['last_output_hash']=pending['hash']
        context={'agent':None,'started':started};token=_active.set(context)
        try:
            try:result=original(forwarded,**kwargs)
            except Exception:
                result=False,'Scheduled inspection failed before completion','','Scheduled inspection failed; no snapshot acknowledged'
        finally:
            _active.reset(token)
            # Preserve the native runner's bounded unreachable/quota handling.
            for key in ('_model_unreachable','_quota_hold_seconds'):
                if key in forwarded:job[key]=forwarded[key]
        try:latest=current_job(job)
        except Exception:latest=job
        snapshot=(latest.get('monitor_state') or {}).get('last_output_hash')
        budget=getattr(context['agent'],'_nix_cron_budget',{})
        answer=str(result[2] or '').strip()
        success=(result[0] is True and bool(answer) and answer.splitlines()[0]!='[CRON_FAILURE]'
                 and not budget.get('exhausted'))
        if context['agent'] is not None and success:
            state['pending']=None;state['last_processed_at']=now;state['last_processed_hash']=snapshot
            if focus is not None:
                stall.processed(state,focus,now);state['stall_pending']=None
        elif (result[0] is False or context['agent'] is not None) and snapshot and (job.get('monitor_script') or job.get('monitor_url')):
            same=pending and pending.get('hash')==snapshot and pending.get('identity')==config
            attempts=pending['attempts']+1 if same else 1
            state['pending']={'hash':snapshot,'identity':config,'attempts':attempts,
                              'next_retry':now+min(86400,3600*4**(attempts-1))}
        if focus is not None and not success:
            old=state.get('stall_pending') or {}
            same=old.get('hash')==fingerprint and old.get('identity')==config
            attempts=old['attempts']+1 if same else 1
            state['stall_pending']={'hash':fingerprint,'identity':config,'attempts':attempts,
                                    'next_retry':now+min(86400,3600*4**(attempts-1))}
        state['last_checked_at']=now
        if context['agent'] is not None:
            state['last_tools']=len(budget['calls']);state['budget_exhausted']=budget['exhausted']
            # Character size of the delivered answer, one integer, no text.
            # The daily (2500) and stall (2400) prompts cap report length by
            # model self-discipline; without this counter, whether those caps
            # fit real reports was unmeasured folklore.
            head=answer.splitlines()[0] if answer else ''
            if head not in ('[SILENT]','[CRON_FAILURE]') and 'no_change' not in head:
                state['last_chars']=len(answer)
        save(path,state)
        return result
