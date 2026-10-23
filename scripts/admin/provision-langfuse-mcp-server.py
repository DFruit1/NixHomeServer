#!/usr/bin/env python3
"""Server-side credential step, invoked by the desktop's local-only operator.

Use Langfuse's native owner authentication and project-key creation, then the
standard realized generate-secrets entrypoint. No database edits, infrastructure
rotation, NixOS activation or routing changes. Never emit clear credentials.
"""
import argparse
import base64
import fcntl
import hashlib
from http.cookies import SimpleCookie
import json
import os
import secrets
from pathlib import Path
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request

NAME='langfuseMcpClientEnv'
IDENTITY='/persist/etc/agenix/age.key'


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None


class Owner:
    def __init__(self):
        # Inspect into process memory; no environment or secret values leave it.
        environment=json.loads(subprocess.check_output(['podman','inspect','--format','{{json .Config.Env}}','langfuse-web']))
        values=dict(x.split('=',1) for x in environment if '=' in x)
        self.origin=values['NEXTAUTH_URL'].rstrip('/')
        self.email=values['LANGFUSE_INIT_USER_EMAIL']
        self.cookies={}
        secret=dict(line.split('=',1) for line in Path('/run/agenix/langfuseServerEnv').read_text().splitlines() if '=' in line)
        csrf=self.call('/api/auth/csrf')['csrfToken']
        body=urllib.parse.urlencode({'csrfToken':csrf,'email':self.email,
            'password':secret['LANGFUSE_INIT_USER_PASSWORD'],'json':'true','callbackUrl':self.origin}).encode()
        self.call('/api/auth/callback/credentials',body,form=True)
        session=self.call('/api/auth/session')
        if session.get('user',{}).get('email','').lower()!=self.email.lower():
            raise ValueError('Existing bootstrap owner authentication failed')

    def call(self,path,data=None,*,form=False):
        headers={'Host':urllib.parse.urlsplit(self.origin).netloc,'Origin':self.origin,
                 'Content-Type':'application/x-www-form-urlencoded' if form else 'application/json'}
        if self.cookies:headers['Cookie']='; '.join(k+'='+v for k,v in self.cookies.items())
        request=urllib.request.Request('http://127.0.0.1:3040'+path,data=data,headers=headers)
        try:response=urllib.request.build_opener(NoRedirect).open(request,timeout=15)
        except urllib.error.HTTPError as error:
            if error.code not in (302,303):raise
            response=error
        with response:
            for line in response.headers.get_all('Set-Cookie',[]):
                cookie=SimpleCookie();cookie.load(line)
                self.cookies.update({k:v.value for k,v in cookie.items()})
            raw=response.read(2*1024*1024+1)
        if len(raw)>2*1024*1024:raise ValueError('Response bound')
        return json.loads(raw) if raw else {}

    def rpc(self,name,payload,*,query=False):
        data=json.dumps({'json':payload})
        response=(self.call('/api/trpc/'+name+'?'+urllib.parse.urlencode({'input':data})) if query else
                  self.call('/api/trpc/'+name,data.encode()))
        return response['result']['data']['json']


def encrypt(repo,credentials):
    """Realize/evaluate before staging plaintext; never copy it into Nix store."""
    name=repo/'secrets'/NAME
    ciphertext=name.with_suffix('.age')
    if ciphertext.exists():raise ValueError('Existing client ciphertext must be preserved')
    env=dict(os.environ,NIXHOMESERVER_REPO_ROOT=str(repo))
    subprocess.run(['nix','run','.#generate-secrets','--','--help'],cwd=repo,env=env,
                   check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=120)
    program=subprocess.check_output(['nix','eval','--raw','.#apps.x86_64-linux.generate-secrets.program'],cwd=repo,text=True).strip()
    manifest=subprocess.check_output(['nix','eval','--json','--file',str(repo/'secrets/manifest.nix')],text=True)
    parsed=json.loads(manifest)
    if NAME not in parsed['externalSecrets']:raise ValueError('Client secret absent from manifest')
    if any(not (repo/'secrets'/(key+'.age')).is_file() for key in parsed['generatedSecrets']):
        raise ValueError('Missing existing generated ciphertext; refusing unrelated generation')
    before={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (repo/'secrets').glob('*.age')}
    staging=repo/'secrets/unencrypted';created=not staging.exists()
    staging.mkdir(mode=0o700,exist_ok=True)
    target=staging/NAME
    descriptor=os.open(target,os.O_WRONLY|os.O_CREAT|os.O_EXCL|os.O_NOFOLLOW,0o600)
    inode=os.fstat(descriptor).st_ino
    try:
        with os.fdopen(descriptor,'w') as out:json.dump(credentials,out)
        env['NIXHOMESERVER_MANIFEST_JSON']=manifest
        subprocess.run([program,'--replace-external',NAME,'--identity',IDENTITY],cwd=repo,env=env,
                       check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=180)
        for filename,digest in before.items():
            if hashlib.sha256((repo/'secrets'/filename).read_bytes()).hexdigest()!=digest:
                raise ValueError('Unrelated ciphertext changed')
        return ciphertext.read_text()
    finally:
        if target.exists() and not target.is_symlink() and target.stat().st_ino==inode:target.unlink()
        if created:
            try:staging.rmdir()
            except OSError:pass


def durable_json(path,value):
    # Only non-secret state or ciphertext is persisted outside normal staging.
    temporary=path.with_suffix('.pending')
    with temporary.open('w') as out:
        os.chmod(temporary,0o600);json.dump(value,out);out.flush();os.fsync(out.fileno())
    temporary.replace(path)
    descriptor=os.open(path.parent,os.O_DIRECTORY)
    try:os.fsync(descriptor)
    finally:os.close(descriptor)


def provision(repo,directory,*,recover=False,owner_factory=Owner):
    directory.mkdir(parents=True,exist_ok=True,mode=0o700)
    if directory.is_symlink():raise ValueError('Receipt directory is symlinked')
    with (directory/'lock').open('a') as lock:
        fcntl.flock(lock,fcntl.LOCK_EX|fcntl.LOCK_NB)
        journal=directory/'receipt.json'
        state=json.loads(journal.read_text()) if journal.exists() else {}
        if state.get('ciphertext'):
            # A completed encrypted receipt survives remote-run cleanup and a
            # broken SSH/desktop handoff. Replay cannot create another key.
            return state
        if recover:raise ValueError('No completed encrypted server receipt to recover')
        owner=owner_factory()
        if not state:
            state={'note':'Desktop read-only usage MCP '+secrets.token_hex(16),'attempts':0}
            durable_json(journal,state)
        # A crash after minting but before recording its ID is found by the
        # unique persisted intent note. It was never handed to a consumer.
        previous=owner.rpc('projectApiKeys.byProjectId',{'projectId':'hermes'},query=True)
        matches=[row for row in previous if row.get('note')==state['note']]
        if len(matches)>1:raise ValueError('Ambiguous provisioning ownership; preserve keys')
        for row in matches:owner.rpc('projectApiKeys.delete',{'projectId':'hermes','id':row['id']})
        if state['attempts']>=2:raise ValueError('Provisioning attempt budget exhausted; owned unused key reconciled')
        state['attempts']+=1;durable_json(journal,state)
        key=owner.rpc('projectApiKeys.create',{'projectId':'hermes','note':state['note']})
        state['key_id']=key['id'];durable_json(journal,state)
        try:
            credentials={'baseUrl':owner.origin,'publicKey':key['publicKey'],'secretKey':key['secretKey']}
            auth=base64.b64encode((credentials['publicKey']+':'+credentials['secretKey']).encode()).decode()
            request=urllib.request.Request('http://127.0.0.1:3040/api/public/projects',headers={'Authorization':'Basic '+auth})
            with urllib.request.urlopen(request,timeout=15) as response:projects=json.load(response)
            if not any(p.get('id')=='hermes' for p in projects['data']):raise ValueError('Wrong project')
            ciphertext=encrypt(repo,credentials)
            state.update(ciphertext=ciphertext,project='hermes',native_key_verified=True,unrelated_ciphertexts_unchanged=True)
            durable_json(journal,state)
        except Exception:
            owner.rpc('projectApiKeys.delete',{'projectId':'hermes','id':key['id']})
            raise
        return state


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--repo',type=Path,required=True)
    parser.add_argument('--apply',action='store_true')
    parser.add_argument('--recover',action='store_true')
    args=parser.parse_args()
    if os.geteuid()!=0:raise ValueError('Existing server root operator is required')
    if args.apply and args.recover:raise ValueError('Choose apply or recover')
    if not (args.apply or args.recover):
        Owner();print('LANGFUSE_CREDENTIAL_RECEIPT:'+json.dumps({'owner_authentication':True}));return
    repo=args.repo.resolve()
    receipt=provision(repo,Path('/var/lib/langfuse/credential-provisioning/desktop-usage-mcp-v1'),recover=args.recover)
    print('LANGFUSE_CREDENTIAL_RECEIPT:'+json.dumps(receipt))


if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('Langfuse credential step stopped ('+type(exc).__name__+').',file=sys.stderr);sys.exit(1)
