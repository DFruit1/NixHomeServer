"""Metadata-only evidence through native Hermes hooks and the existing Langfuse SDK.

Python is required by Hermes' plugin interface. No model calls, prompt changes,
credential copies, core patches, new service or dependency are introduced.
"""
import functools
import contextlib
import hashlib
import importlib.metadata
import json
import logging
import os
from pathlib import Path
import re
import sqlite3

logger = logging.getLogger(__name__)
EFFORTS = {'none','minimal','low','medium','high','xhigh','max','ultra'}
try:
    from langfuse import propagate_attributes
except ImportError:
    propagate_attributes=None


def label(value):
    return value if (isinstance(value,str) and re.fullmatch(r'[A-Za-z0-9_./:-]{1,120}',value)
                     and not value.startswith(('sk-','pk-lf-','sk-lf-'))) else None


def file_hash(path):
    try:
        stat = path.stat()
        return _file_hash(str(path),stat.st_mtime_ns,stat.st_size) if stat.st_size<=131072 else None
    except OSError:
        return None


@functools.lru_cache(maxsize=128)
def _file_hash(path,mtime,size):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def prompt_hash(home,session_id):
    """Read the persisted hash, never prompt content; missing/locked DB is unknown."""
    try:
        db = sqlite3.connect((home/'state.db').as_uri()+'?mode=ro',uri=True,timeout=.05)
        try:
            db.execute('PRAGMA query_only=ON')
            row=db.execute('SELECT system_prompt_hash FROM sessions WHERE id=?',(session_id,)).fetchone()
            value=row[0] if row else None
            return value if isinstance(value,str) and re.fullmatch(r'[a-f0-9]{64}',value) else None
        finally:
            db.close()
    except (sqlite3.Error,ValueError):
        return None


def snapshot(home,config,*,session_id='',model='',provider='',request=None,**_):
    home=Path(home).resolve()
    body=request.get('body') if isinstance(request,dict) else None
    body=body if isinstance(body,dict) else {}
    reasoning=body.get('reasoning')
    effort=reasoning.get('effort') if isinstance(reasoning,dict) else body.get('reasoning_effort')
    agent=config.get('agent',{})
    model_config=config.get('model',{})
    settings={
        'model': {k:label(model_config.get(k)) for k in ('default','provider')},
        'reasoning_effort':label(agent.get('reasoning_effort')),
        'reasoning_overrides':{label(k):label(v) for k,v in agent.get('reasoning_overrides',{}).items()
                               if label(k)},
        'fallbacks':[{k:label(x.get(k)) for k in ('provider','model')}
                     for x in config.get('fallback_providers',[]) or []],
    }
    return {
        'evidence_schema':1,
        'profile':label(home.name) if home.parent.name=='profiles' else 'default',
        'model':label(body.get('model') or model),'provider':label(provider),
        'reasoning_effort':effort if isinstance(effort,str) and effort in EFFORTS else None,
        'reasoning_source':'request_body',
        'config_settings_sha256':hashlib.sha256(json.dumps(settings,sort_keys=True).encode()).hexdigest(),
        'soul_on_disk_sha256':file_hash(home/'SOUL.md'),
        'persisted_prompt_sha256':prompt_hash(home,session_id),
        'board':label(os.environ.get('HERMES_KANBAN_BOARD')),
        'card_id':label(os.environ.get('HERMES_KANBAN_TASK')),
        'run_id':label(os.environ.get('HERMES_KANBAN_RUN_ID')),
    }


def runtime_scope():
    from hermes_constants import get_hermes_home
    from hermes_cli.config import load_config_readonly
    return get_hermes_home(),load_config_readonly()


@functools.lru_cache(maxsize=1)
def version():
    try:
        return importlib.metadata.version('hermes-agent')
    except importlib.metadata.PackageNotFoundError:
        return 'unknown'


@functools.lru_cache(maxsize=16)
def client_for_home(home):
    # Read only through Hermes' profile-scoped resolver. Values stay in memory.
    from agent.secret_scope import get_secret
    public=get_secret('HERMES_LANGFUSE_PUBLIC_KEY')
    secret=get_secret('HERMES_LANGFUSE_SECRET_KEY')
    if not public or not secret:
        return None
    from langfuse import Langfuse
    return Langfuse(public_key=public,secret_key=secret,
                    base_url=get_secret('HERMES_LANGFUSE_BASE_URL'),
                    environment=get_secret('HERMES_LANGFUSE_ENV') or 'default')


def export(metadata,*,session_id='',task_id='',turn_id='',api_request_id='',client=None,**_):
    """One token-free span, correlated to the bundled plugin's turn trace.

    The seed mirrors the installed Langfuse plugin. The integration test checks
    this adapter against that plugin, including session-only turns.
    """
    if client is None:
        from hermes_constants import get_hermes_home
        client=client_for_home(str(get_hermes_home()))
    if client is None or not session_id:
        return
    scope=f'task:{task_id}' if task_id else f'session:{session_id}'
    key=(f'{scope}:turn:{turn_id}' if turn_id else
         f'{scope}:api:{api_request_id}' if api_request_id else task_id or scope)
    trace_id=client.create_trace_id(seed=f'{session_id}::{task_id or key}')
    attributes=propagate_attributes(session_id=session_id) if propagate_attributes else contextlib.nullcontext()
    with attributes:
        span=client.start_observation(name='Hermes runtime evidence',as_type='span',
                                      trace_context={'trace_id':trace_id},metadata=metadata)
        span.end()


def on_request(**kwargs):
    try:
        home,config=runtime_scope()
        plugins=config.get('plugins',{})
        if ('observability/langfuse' not in plugins.get('enabled',[])
                or 'observability/langfuse' in plugins.get('disabled',[])):
            return
        evidence=snapshot(home,config,**kwargs)
        evidence.update({k:label(kwargs.get(k)) for k in ('session_id','task_id','turn_id','api_request_id')})
        evidence['hermes_package_version']=version()
        logger.info('hermes_runtime_evidence %s',json.dumps(evidence,sort_keys=True))
        export(evidence,**kwargs)
    except Exception as exc:
        # Exceptions can carry credential-bearing provider diagnostics.
        logger.warning('runtime evidence unavailable (%s)',type(exc).__name__)


def register(ctx):
    ctx.register_hook('pre_api_request',on_request)
