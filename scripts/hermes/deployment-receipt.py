#!/usr/bin/env python3
"""Check review/decision/test consistency without deploying or mutating Hermes.

Python operations glue reuses the native board, existing verdict validator,
canonical archive helper and v2 test-stamp parser. No new backend or authority.
"""
import argparse
import base64
from contextlib import closing
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import re
import sqlite3
import stat
import subprocess
import tempfile
import time

# Board comment authors that represent the owner speaking on a decision card.
# The desktop app writes `desktop`, the owner's own CLI writes `user`, and an
# owner-recorded decision marker writes `owner`. All three are the owner, so a
# later comment from any of them must still supersede an approval; keying on
# `desktop` alone silently let owner feedback from the other two clients pass a
# stale approval. Kept in step with kanban-board-health.sh and cron_stall.py.
OWNER_AUTHORS=('owner','desktop','user')


def strict_json(text):
    def unique(pairs):
        result = {}
        for key,value in pairs:
            if key in result:
                raise ValueError('Duplicate JSON field')
            result[key] = value
        return result
    def invalid_constant(value):
        raise ValueError('Non-finite JSON value')
    return json.loads(text,object_pairs_hook=unique,parse_constant=invalid_constant)


def digest(value):
    return hashlib.sha256(json.dumps(value,sort_keys=True,separators=(',',':')).encode()).hexdigest()


def validate_scope(scope):
    keys = {'schema_version','kind','base_revision','head_revision','baseline_evidence',
            'source_hash','hostname','target','actions','inputs'}
    if (not isinstance(scope,dict) or set(scope)!=keys or type(scope['schema_version']) is not int
            or scope['schema_version']!=1 or scope['kind']!='nixos-whole-set'):
        raise ValueError('Expected a version=1 whole-set deployment scope')
    for name in ('base_revision','head_revision'):
        if not isinstance(scope[name],str) or not re.fullmatch(r'[0-9a-f]{40}',scope[name]):
            raise ValueError('Deployment scope requires full commit identities')
    if not isinstance(scope['baseline_evidence'],str) or not 1<=len(scope['baseline_evidence'].strip())<=500:
        raise ValueError('Record the evidence for the supplied last-deployed baseline')
    if not isinstance(scope['hostname'],str) or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9-]{0,62}',scope['hostname']):
        raise ValueError('Invalid deployment hostname')
    if not isinstance(scope['target'],str) or not re.fullmatch(r'[A-Za-z0-9_.-]+@[A-Za-z0-9_.:\[\]-]+',scope['target']):
        raise ValueError('Expected an explicit user@host deployment target')
    try:
        if not scope['source_hash'].startswith('sha256-') or len(base64.b64decode(scope['source_hash'][7:],validate=True))!=32:
            raise ValueError()
    except (TypeError,AttributeError,ValueError):
        raise ValueError('Invalid source NAR hash') from None
    if (not isinstance(scope['actions'],list) or not scope['actions']
            or any(action not in ('test','switch') for action in scope['actions'])
            or len(set(scope['actions']))!=len(scope['actions'])):
        raise ValueError('List the reviewed test/switch actions explicitly')
    if not isinstance(scope['inputs'],dict) or len(scope['inputs'])>16:
        raise ValueError('Invalid mutable input manifest')
    for name,value in scope['inputs'].items():
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}',name) or not isinstance(value,str) or not re.fullmatch(r'[0-9a-f]{64}',value):
            raise ValueError('Mutable inputs require bounded names and SHA-256 identities')
    return scope


def input_hashes(paths):
    if len(paths)>16:
        raise ValueError('At most 16 declared mutable inputs are supported')
    result = {}
    for name,path in sorted(paths.items()):
        if not re.fullmatch(r'[A-Za-z0-9_-]{1,64}',name):
            raise ValueError('Invalid mutable input name')
        path = Path(path).resolve(strict=True)
        parts = path.parts
        if (path.name in {'.env','auth.json','serverBootstrapSudoPassword'}
                or 'SensitivePrivateSecrets' in parts or 'agenix' in parts
                or any(parts[i:i+2]==('secrets','unencrypted') for i in range(len(parts)))):
            raise ValueError('Credential/secret inputs are not supported by this receipt')
        if not stat.S_ISREG(path.stat().st_mode) or path.stat().st_size>8*1024*1024:
            raise ValueError('Mutable inputs must be bounded regular non-secret files')
        fd = os.open(path,os.O_RDONLY|os.O_NOFOLLOW|os.O_NONBLOCK)
        with os.fdopen(fd,'rb') as stream:
            before = os.fstat(stream.fileno())
            if not stat.S_ISREG(before.st_mode) or before.st_size>8*1024*1024:
                raise ValueError('Mutable inputs must be bounded regular non-secret files')
            contents = stream.read(8*1024*1024+1)
            fingerprint = lambda s:(s.st_dev,s.st_ino,s.st_mode,s.st_size,s.st_mtime_ns,s.st_ctime_ns)
            if (len(contents)>8*1024*1024 or fingerprint(before)!=fingerprint(os.fstat(stream.fileno()))
                    or fingerprint(before)!=fingerprint(path.stat())):
                raise ValueError('Mutable input changed while being read')
            value = hashlib.sha256(contents).hexdigest()
        result[name] = value
    return result


def command(argv, **kwargs):
    try:
        return subprocess.run(argv,check=True,capture_output=True,text=True,timeout=120,**kwargs).stdout.strip()
    except (OSError,subprocess.SubprocessError):
        raise ValueError('Source or stamp helper failed; no approval receipt emitted') from None


def capture_scope(repo,base,baseline_evidence,hostname,target,actions,inputs):
    repo = Path(repo).resolve(strict=True)
    git = lambda *args:command(['git','-C',str(repo),*args])
    if Path(git('rev-parse','--show-toplevel')).resolve()!=repo:
        raise ValueError('Use the deployment checkout root')
    if git('status','--porcelain=v1','--untracked-files=all'):
        raise ValueError('Commit the reviewed source; deployment checkout is dirty or untracked')
    if any(entry and entry[0]!='H' for entry in git('ls-files','-v','-z').split('\0')):
        raise ValueError('Deployment checkout has hidden index flags; use an ordinary clean checkout')
    head = git('rev-parse','HEAD')
    if not re.fullmatch(r'[0-9a-f]{40}',base):
        raise ValueError('Use the full last-deployed baseline revision')
    git('merge-base','--is-ancestor',base,head)
    manifest = input_hashes(inputs)
    with tempfile.TemporaryDirectory(prefix='nixhomeserver-deploy-receipt-') as tmp:
        scratch = Path(tmp)
        archive, tree = scratch/'source.tar', scratch/'source'
        tree.mkdir()
        # Use the same explicit tracked-file manifest and plaintext exclusions as
        # deployment. Hash the extracted tree, never .git or tar container bytes.
        command(['bash','-c','set -e; source "$1"; repo_root="$2"; create_deploy_repo_archive "$3"',
                 'receipt',str(repo/'scripts/helpers/repo-common.sh'),str(repo),str(archive)],
                env={**os.environ,'TMPDIR':str(scratch)})
        command(['tar','-C',str(tree),'-xf',str(archive)])
        source_hash = command(['nix','hash','path',str(tree)])
    if (git('rev-parse','HEAD')!=head or git('status','--porcelain=v1','--untracked-files=all')
            or any(entry and entry[0]!='H' for entry in git('ls-files','-v','-z').split('\0'))
            or input_hashes(inputs)!=manifest):
        raise ValueError('Source or declared inputs changed during capture')
    return validate_scope({'schema_version':1,'kind':'nixos-whole-set','base_revision':base,
        'head_revision':head,'baseline_evidence':baseline_evidence,'source_hash':source_hash,
        'hostname':hostname,'target':target,'actions':actions,'inputs':manifest})


def evidence(root,board,review,decision,repo):
    validator = Path(repo).resolve()/'scripts/hermes/review-verdict-guard.py'
    spec = importlib.util.spec_from_file_location('receipt_verdict',validator)
    guard = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(guard)
    path = root/'kanban/boards'/board/'kanban.db'
    with closing(sqlite3.connect(path.resolve().as_uri()+'?mode=ro',uri=True,timeout=2)) as db:
        db.row_factory = sqlite3.Row
        db.execute('PRAGMA query_only=ON')
        deadline = time.monotonic()+8
        db.set_progress_handler(lambda:int(time.monotonic()>deadline),10000)
        db.execute('BEGIN')
        cards = {row['id']:dict(row) for row in db.execute(
            'SELECT id,status,assignee,tenant FROM tasks WHERE id IN (?,?)',(review,decision))}
        if (review not in cards or cards[review]['status']!='done'
                or cards[review]['assignee'] not in {'feature-reviewer','project-auditor'}
                or cards[review]['tenant']!='verification'):
            raise ValueError('Expected a completed whole-set verification card')
        if (decision not in cards or cards[decision]['assignee']!='head-coordinator'
                or cards[decision]['status'] not in ('running','ready')):
            raise ValueError('Expected the open paired coordinator decision')
        parents = list(db.execute('''SELECT l.parent_id,p.status FROM task_links l
            LEFT JOIN tasks p ON p.id=l.parent_id WHERE l.child_id=?''',(decision,)))
        if review not in {p[0] for p in parents} or any(p[1]!='done' for p in parents):
            raise ValueError('Coordinator decision lacks its accepted review or has unfinished/missing prerequisites')
        run = db.execute('SELECT id,profile,status,outcome,metadata FROM task_runs WHERE task_id=? ORDER BY id DESC LIMIT 1',
                         (review,)).fetchone()
        if (not run or run['profile']!=cards[review]['assignee'] or run['status']!='done'
                or run['outcome']!='completed' or not isinstance(run['metadata'],str) or len(run['metadata'])>65536):
            raise ValueError('The latest review run is not a completed verifier run')
        metadata = strict_json(run['metadata'])
        if cards[review]['assignee']=='project-auditor':
            guard.validate(metadata,profile='project-auditor')
        else:
            guard.validate(metadata)
        if metadata['verdict']!='accept':
            raise ValueError('Whole-set review requested changes')
        scope = validate_scope(metadata.get('deployment_scope'))
        if metadata['revision']!=scope['head_revision']:
            raise ValueError('Review revision does not match its deployment scope')
        chosen = None
        scanned_bytes = 0
        for index,comment in enumerate(db.execute(
                'SELECT id,author,body FROM task_comments WHERE task_id=? ORDER BY id DESC LIMIT 201',(decision,))):
            if index>=200:
                raise ValueError('Reconcile the decision in a recent bounded structured comment')
            if comment['author'] in OWNER_AUTHORS and chosen is None:
                raise ValueError('New owner feedback needs coordinator reconciliation')
            body = comment['body'] or ''
            if not isinstance(body,str):
                raise ValueError('Invalid decision comment')
            scanned_bytes += len(body)
            if scanned_bytes>1024*1024:
                raise ValueError('Decision comment scan exceeds the bounded format')
            try:
                parsed = strict_json(body)
            except ValueError:
                if body.lstrip().startswith('{') or '"deployment_decision"' in body:
                    raise ValueError('Invalid structured deployment decision JSON') from None
                continue
            if not isinstance(parsed,dict) or 'deployment_decision' not in parsed:
                continue
            if len(body)>32768:
                raise ValueError('Deployment decision exceeds the bounded format')
            if not isinstance(parsed,dict) or set(parsed)!={'deployment_decision'}:
                raise ValueError('Invalid structured deployment decision')
            chosen = parsed['deployment_decision']
            if comment['author']!='head-coordinator':
                raise ValueError('Deployment decision must be authored by head-coordinator')
            comment_id = comment['id']
            break
        keys = {'schema_version','approved','review_task','review_run_id','scope'}
        if (not isinstance(chosen,dict) or set(chosen)!=keys or type(chosen['schema_version']) is not int
                or chosen['schema_version']!=1
                or chosen['approved'] is not True or chosen['review_task']!=review
                or type(chosen['review_run_id']) is not int or chosen['review_run_id']!=run['id']):
            raise ValueError('Latest coordinator decision is missing, withdrawn or does not match the reviewed scope/run')
        if digest(validate_scope(chosen['scope']))!=digest(scope):
            raise ValueError('Coordinator deployment scope differs from the reviewed scope')
        return {'scope':scope,'review_run_id':run['id'],'decision_comment_id':comment_id,
                'review_metadata_sha256':digest(metadata),'decision_sha256':digest(chosen)}


def tested_stamp(path,repo):
    path = Path(path)
    if path.is_symlink() or not path.is_file() or path.stat().st_size>4096:
        raise ValueError('Missing or unsafe operator-supplied tested stamp')
    values = command(['bash','-c','source "$1"; deploy_read_test_stamp "$2" src top debug || exit; printf "%s\\n" "$src" "$top" "$debug"',
                      'receipt',str(Path(repo).resolve()/'scripts/helpers/deploy-transaction.sh'),str(path)]).splitlines()
    if len(values)!=3:
        raise ValueError('Invalid tested deployment stamp')
    return {'source_hash':values[0],'toplevel':values[1],'debug_validated':values[2]=='true'}


def check(root,board,review,decision,repo,action,inputs,stamp=None,*,hostname,target):
    if not re.fullmatch(r'[A-Za-z0-9_-]+',board) or any(not re.fullmatch(r't_[A-Za-z0-9_]+',tid) for tid in (review,decision)):
        raise ValueError('Use explicit board and native task identifiers')
    first = evidence(root,board,review,decision,repo)
    scope = first['scope']
    if hostname!=scope['hostname'] or target!=scope['target']:
        raise ValueError('Intended hostname/target differs from the reviewed scope')
    if action not in scope['actions']:
        raise ValueError('Action was not reviewed and approved')
    current = capture_scope(repo,scope['base_revision'],scope['baseline_evidence'],scope['hostname'],
                            scope['target'],scope['actions'],inputs)
    if current!=scope:
        raise ValueError('Checkout or complete mutable input manifest differs from reviewed scope')
    tested = None
    if action=='switch':
        if stamp is None:
            raise ValueError('Switch consistency requires the authorized target test-stamp evidence')
        tested = tested_stamp(stamp,repo)
        if tested['source_hash']!=scope['source_hash']:
            raise ValueError('Tested source differs from accepted source')
    if evidence(root,board,review,decision,repo)!=first:
        raise ValueError('Review or decision changed during consistency checking')
    return {'schema_version':1,'checked_at':time.time(),'board':board,'review_task':review,'decision_task':decision,
            **first,'action':action,'stage':'reviewed_and_tested' if tested else 'reviewed','tested':tested,
            'provenance':{'baseline':'supplied evidence, not independently reconstructed',
                          'test_stamp':'operator-supplied; guarded deploy must revalidate the live target stamp'},
            'scope_sha256':digest(scope)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('operation',choices=('snapshot','check'))
    parser.add_argument('--repo',type=Path,default=Path.cwd())
    parser.add_argument('--base')
    parser.add_argument('--baseline-evidence')
    parser.add_argument('--hostname')
    parser.add_argument('--target')
    parser.add_argument('--actions',nargs='+',choices=('test','switch'),default=['test','switch'])
    parser.add_argument('--input',action='append',default=[],metavar='NAME=PATH')
    parser.add_argument('--board')
    parser.add_argument('--review')
    parser.add_argument('--decision')
    parser.add_argument('--action',choices=('test','switch'))
    parser.add_argument('--tested-stamp',type=Path)
    args = parser.parse_args()
    try:
        inputs = {}
        for value in args.input:
            name,separator,path = value.partition('=')
            if not separator or not path or name in inputs:
                raise ValueError('Use unique NAME=PATH input arguments')
            inputs[name] = Path(path)
        if args.operation=='snapshot':
            if not all((args.base,args.baseline_evidence,args.hostname,args.target)):
                raise ValueError('Snapshot requires base, baseline-evidence, hostname and target')
            result = capture_scope(args.repo,args.base,args.baseline_evidence,args.hostname,args.target,args.actions,inputs)
        else:
            if not all((args.board,args.review,args.decision,args.action,args.hostname,args.target)):
                raise ValueError('Check requires board, review, decision, action, hostname and target')
            result = check(Path(os.environ.get('HERMES_ROOT',str(Path.home()/'.hermes'))),args.board,
                           args.review,args.decision,args.repo,args.action,inputs,args.tested_stamp,
                           hostname=args.hostname,target=args.target)
        print(json.dumps(result,sort_keys=True,indent=2))
    except sqlite3.Error:
        parser.exit(1,'Deployment receipt unavailable: native board evidence is missing, incompatible or unreadable\n')
    except (ValueError,OSError) as exc:
        parser.exit(1,f'Deployment receipt unavailable: {exc}\n')


if __name__=='__main__':
    main()
