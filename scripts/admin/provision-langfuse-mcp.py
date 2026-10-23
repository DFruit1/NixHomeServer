#!/usr/bin/env python3
"""Desktop entrypoint for the reviewed local-only credential operator.

The native Langfuse API mints/registers the key on the existing server. Only
age ciphertext returns to the desktop; the local AI sees a sanitized receipt.
"""
import argparse
import datetime as dt
import json
import os
from pathlib import Path
import shlex
import subprocess
import sys
import tempfile

sys.path.insert(0,str(Path(__file__).resolve().parents[1]/'hermes'))
from langfuse_mcp import Client, handle


def preflight(repo,targets):
    scratch=repo/'.tmp'
    if scratch.is_symlink():raise ValueError('Refuse symlinked handoff directory')
    scratch.mkdir(mode=0o700,exist_ok=True)
    for path in targets:
        path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
        if path.is_symlink() or (path.exists() and not path.is_file()):raise ValueError('Invalid existing credential target')
        if path.parent.stat().st_dev!=scratch.stat().st_dev:raise ValueError('Atomic handoff requires matching filesystems')
    existing=[p.read_bytes() for p in targets if p.exists()]
    if len(existing)==2 and existing[0]!=existing[1]:raise ValueError('Conflicting encrypted credentials; preserve both copies')


def publish_ciphertext(repo,targets,ciphertext):
    # /tmp is a different filesystem on the desktop. One ignored task directory
    # is necessary for atomic, no-overwrite hard-link publication to both home
    # targets. Only ciphertext enters it; cleanup removes that exact directory.
    with tempfile.TemporaryDirectory(prefix='langfuse-mcp-handoff-',dir=repo/'.tmp') as scratch:
        for path,mode in targets:
            if path.is_symlink():raise ValueError('Refuse symlinked credential target')
            if path.exists():
                if path.read_text()!=ciphertext:raise ValueError('Preserve conflicting credential bytes')
                continue
            temporary=Path(scratch)/path.name
            with temporary.open('x') as out:
                os.chmod(temporary,mode);out.write(ciphertext);out.flush();os.fsync(out.fileno())
            os.link(temporary,path)  # Atomic create, never overwrite a concurrent target.
            descriptor=os.open(path.parent,os.O_DIRECTORY)
            try:os.fsync(descriptor)
            finally:os.close(descriptor)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,default=Path(__file__).resolve().parents[2])
    parser.add_argument('--apply',action='store_true')
    args=parser.parse_args();repo=args.repo.resolve()
    target=repo/'secrets/langfuseMcpClientEnv.age'
    runtime=Path.home()/'.hermes/credentials/langfuse-mcp.age'
    preflight(repo,(target,runtime))
    snippet='sudo -n python3 "$1/scripts/admin/provision-langfuse-mcp-server.py" --repo "$1"'
    if args.apply:snippet+=' --recover' if target.exists() or runtime.exists() else ' --apply'
    # Use the maintained archive/SSH implementation directly: credential work
    # must never take remote_run's normal desktop fallback on transport failure.
    shell=('source '+shlex.quote(str(repo/'scripts/helpers/remote-run.sh'))+'\n'
           '_remote_run_run '+shlex.quote(snippet)+'\n'
           'status=$?\nif [ "$status" = 2 ]; then exit "${remote_run_exit:-1}"; fi\nexit "$status"')
    result=subprocess.run(['bash','-c',shell],cwd=repo,stdout=subprocess.PIPE,stderr=subprocess.PIPE,
                          text=True,timeout=420)
    if result.returncode:raise ValueError('Remote credential step failed; no desktop fallback')
    lines=[line for line in result.stdout.splitlines() if line.startswith('LANGFUSE_CREDENTIAL_RECEIPT:')]
    if len(lines)!=1:raise ValueError('Missing unique server receipt')
    receipt=json.loads(lines[0].split(':',1)[1])
    if args.apply:
        ciphertext=receipt.pop('ciphertext')
        if not ciphertext.startswith('-----BEGIN AGE ENCRYPTED FILE-----'):raise ValueError('Armored ciphertext required')
        publish_ciphertext(repo,((target,0o644),(runtime,0o600)),ciphertext)
        subprocess.run(['git','add','secrets/langfuseMcpClientEnv.age'],cwd=repo,check=True)
        client=Client(runtime)
        now=dt.datetime.now(dt.timezone.utc)
        query={'view':'observations','dimensions':[{'field':'providedModelName'}],
            'metrics':[{'measure':'inputTokens','aggregation':'sum'}],'filters':[],
            'fromTimestamp':(now-dt.timedelta(hours=24)).isoformat(),'toTimestamp':now.isoformat(),
            'config':{'row_limit':20}}
        for name,arguments in (('getHealth',{'failIfDatabaseUnavailable':True,'failIfNoRecentEvents':False}),
                               ('queryMetrics',query)):
            response=handle({'jsonrpc':'2.0','id':1,'method':'tools/call','params':{'name':name,'arguments':arguments}},client)
            if 'error' in response or response.get('result',{}).get('isError'):raise ValueError('Fresh MCP verification failed')
        receipt['mcp_health_and_usage_verified']=True
        receipt['encrypted_file']='secrets/langfuseMcpClientEnv.age'
        receipt['runtime_file']='~/.hermes/credentials/langfuse-mcp.age'
    print(json.dumps(receipt,sort_keys=True))


if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('Local credential step stopped ('+type(exc).__name__+').',file=sys.stderr);sys.exit(1)
