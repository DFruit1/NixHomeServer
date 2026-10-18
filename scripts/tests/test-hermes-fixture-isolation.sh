#!/usr/bin/env bash
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if [[ "${HERMES_FIXTURE_ACTIVE:-}" != 1 ]]; then
  # The generic gate needs only the system Python; native integration is separate.
  exec python3 -B - "$repo" "${BASH_SOURCE[0]}" <<'PY'
import importlib.util
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
repo=Path(sys.argv[1]);suite=Path(sys.argv[2]).resolve()
spec=importlib.util.spec_from_file_location('fixture',repo/'scripts/hermes/fixture-runner.py')
runner=importlib.util.module_from_spec(spec);spec.loader.exec_module(runner)
with tempfile.TemporaryDirectory(prefix='hermes-fixture-isolation-',dir='/tmp') as task:
    task=Path(task);runtime=task/'runtime';binary=runtime/'.venv/bin';binary.mkdir(parents=True)
    (binary/'python').symlink_to(Path(sys.executable).resolve())
    (runtime/'.venv/pyvenv.cfg').write_text('home = '+str(Path(sys.executable).resolve().parent)+'\n')
    scratch=task/'scratch';scratch.mkdir()
    if not shutil.which('bwrap'):
        try:runner.command(repo,suite,runtime,scratch)
        except ValueError as exc:
            assert 'bubblewrap is required' in str(exc)
            print('PASS missing bubblewrap refuses execution; confinement integration unavailable')
        else:raise AssertionError('Fixture execution silently lost confinement')
    else:
        os.environ['HERMES_PROFILE_NAME']='fixture-origin-profile'
        argv,env=runner.command(repo,suite,runtime,scratch)
        env['HERMES_FIXTURE_EXPECT_PROFILE']='fixture-origin-profile'
        raise SystemExit(subprocess.call(argv,env=env))
PY
fi
python3 -B - "$repo" <<'PY'
import json
import os
from pathlib import Path
import socket
import shutil
import sys

repo=Path(sys.argv[1])
origin=json.loads(Path(os.environ['HERMES_FIXTURE_ORIGIN']).read_text())
assert origin['provenance']=='confined-synthetic-test'
if expected:=os.environ.get('HERMES_FIXTURE_EXPECT_PROFILE'):
    assert origin['origin']['HERMES_PROFILE_NAME']==expected
try:
    Path(os.environ['HERMES_FIXTURE_ORIGIN']).write_text('must refuse')
except OSError:
    pass
else:
    raise AssertionError('Origin receipt is writable')
for variable in ('HERMES_KANBAN_TASK','HERMES_KANBAN_DB','HERMES_DELEGATED_CHILD_CONTEXT',
                 'SSH_AUTH_SOCK','OPENAI_API_KEY','BASH_ENV','LD_PRELOAD'):
    assert variable not in os.environ, variable
assert not Path('/var/lib').exists()
assert not Path('/run/user').exists()
assert not Path('/home/dsaw/.ssh').exists()
assert not Path('/home/dsaw/.hermes/kanban/boards/nixhomeserver/kanban.db').exists()
assert not Path('/home/dsaw/.hermes/hermes-agent/.env').exists()
assert not any((repo/'secrets/unencrypted').glob('*'))
for path in (repo/'scripts/hermes/fixture-runner.py',Path(shutil.which('true')).resolve()):
    try:
        with path.open('ab'):
            pass
    except OSError:
        pass
    else:
        raise AssertionError('Readonly mount is writable: '+str(path))
probe=socket.socket()
probe.settimeout(.1)
try:
    probe.connect(('1.1.1.1',443))
except OSError:
    pass
else:
    raise AssertionError('Fixture network escaped its namespace')
finally:
    probe.close()
print('PASS fixture credentials/home/host state absent, readonly code, isolated network, origin retained')
PY
