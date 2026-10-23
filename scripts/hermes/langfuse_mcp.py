"""Read-only stdio bridge to the existing private Langfuse MCP endpoint.

Python operations glue translates MCP JSON lines to the native stateless HTTP
endpoint with no daemon, backend or extra dependency. Credentials remain age
encrypted on disk; the existing server identity decrypts them over SSH into
this process's memory. Only three lookup tools can reach the native endpoint.
"""
import argparse
import base64
import copy
import datetime as dt
import json
import re
import subprocess
import sys
from pathlib import Path
import urllib.parse
import urllib.request

ALLOWED={'getHealth','queryMetrics','getMetricsSchema'}
MAX_BYTES=2*1024*1024


def handle(message,upstream):
    ident=message.get('id') if isinstance(message,dict) else None
    def error(code,text):return {'jsonrpc':'2.0','id':ident,'error':{'code':code,'message':text}}
    if not isinstance(message,dict) or message.get('jsonrpc')!='2.0':return error(-32600,'Invalid request')
    method=message.get('method')
    if method=='notifications/initialized':return None
    if method=='ping':return {'jsonrpc':'2.0','id':ident,'result':{}}
    if method not in {'initialize','tools/list','tools/call'}:return error(-32601,'Method not available in read-only usage endpoint')
    request=copy.deepcopy(message)
    try:
        if method=='tools/call':
            params=request['params'];name=params['name']
            if name not in ALLOWED:return error(-32601,'Tool not allowed by read-only usage endpoint')
            if name=='queryMetrics':
                args=params['arguments']
                start=dt.datetime.fromisoformat(args['fromTimestamp'].replace('Z','+00:00'))
                end=dt.datetime.fromisoformat(args['toTimestamp'].replace('Z','+00:00'))
                if start.tzinfo is None or end.tzinfo is None or not 0<=(end-start).total_seconds()<=7*86400:
                    raise ValueError('Metrics window')
                if args['view']!='observations':raise ValueError('Usage view')
                settings=args.setdefault('config',{})
                limit=settings.setdefault('row_limit',1000)
                if type(limit) is not int or not 1<=limit<=1000:raise ValueError('Row limit')
                args.setdefault('filters',[]).append({'column':'type','operator':'=','type':'string','value':'GENERATION'})
            elif name=='getMetricsSchema':
                params['arguments']={'view':'observations'}
        response=upstream(request)
        if 'result' in response and method=='tools/list':
            response['result']['tools']=[t for t in response['result']['tools'] if t.get('name') in ALLOWED]
        if 'result' in response and method=='initialize':
            response['result']['capabilities']={'tools':{'listChanged':False}}
            response['result']['serverInfo']={'name':'langfuse-usage-readonly','version':'1'}
        return response
    except (KeyError,ValueError,TypeError,AttributeError):return error(-32602,'Invalid or unbounded usage query')
    except Exception:return error(-32603,'Private Langfuse endpoint unavailable; inspect credential and transport health')


class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self,*args,**kwargs):return None


class Client:
    def __init__(self,path):self.path=path;self.values=None

    def credentials(self):
        if self.values is None:
            if self.path.is_symlink() or self.path.stat().st_size>65536:raise ValueError('Invalid encrypted credential')
            ciphertext=self.path.read_bytes()
            if not ciphertext.startswith(b'-----BEGIN AGE ENCRYPTED FILE-----'):raise ValueError('Armored age credential required')
            result=subprocess.run(['ssh','-o','BatchMode=yes','-o','ConnectTimeout=5','dsaw@192.168.8.12',
                'sudo','-n','age','--decrypt','--identity','/persist/etc/agenix/age.key'],
                input=ciphertext,stdout=subprocess.PIPE,stderr=subprocess.DEVNULL,timeout=20,check=True)
            if len(result.stdout)>4096:raise ValueError('Credential bound exceeded')
            values=json.loads(result.stdout)
            if set(values)!={'baseUrl','publicKey','secretKey'}:raise ValueError('Credential schema')
            url=urllib.parse.urlsplit(values['baseUrl'])
            if (url.scheme!='https' or not url.hostname or url.username or url.password
                    or url.path not in ('','/') or url.query or url.fragment):raise ValueError('Private HTTPS origin required')
            for name,prefix in (('publicKey','pk-lf-'),('secretKey','sk-lf-')):
                if not re.fullmatch(prefix+r'[A-Za-z0-9_-]{16,160}',values[name]):raise ValueError('Project key format')
            self.values=values
        return self.values

    def __call__(self,message):
        values=self.credentials()
        auth=base64.b64encode((values['publicKey']+':'+values['secretKey']).encode()).decode()
        request=urllib.request.Request(values['baseUrl'].rstrip('/')+'/api/public/mcp',
            data=json.dumps(message).encode(),headers={'Authorization':'Basic '+auth,
            'Content-Type':'application/json','Accept':'application/json, text/event-stream'})
        with urllib.request.build_opener(NoRedirect).open(request,timeout=15) as response:
            raw=response.read(MAX_BYTES+1)
        if len(raw)>MAX_BYTES:raise OSError('Response bound exceeded')
        text=raw.decode()
        if text.startswith(('event:','data:')):
            text=next(line[5:].strip() for line in text.splitlines() if line.startswith('data:'))
        return json.loads(text)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--credential-age',type=Path,default=Path.home()/'.hermes/credentials/langfuse-mcp.age')
    args=parser.parse_args();client=Client(args.credential_age)
    while True:
        line=sys.stdin.buffer.readline(MAX_BYTES+1)
        if not line:break
        if len(line)>MAX_BYTES:raise ValueError('Request bound exceeded')
        try:result=handle(json.loads(line),client)
        except ValueError:result={'jsonrpc':'2.0','id':None,'error':{'code':-32700,'message':'Invalid JSON'}}
        if result is not None:print(json.dumps(result,separators=(',',':')),flush=True)


if __name__=='__main__':
    try:main()
    except Exception as exc:
        print('Langfuse MCP stopped ('+type(exc).__name__+').',file=sys.stderr);sys.exit(1)
