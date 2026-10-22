"""Bind native session metadata to its actual dispatcher claim.

Python matches Hermes' SessionDB integration. Only metadata is read; the native
session-creation API persists this record without a board mutation capability.
"""
from contextlib import closing
import json
import hashlib
import stat
import tempfile
import os
from pathlib import Path
import re
import sqlite3
import time


def process_fingerprint():
    def ticks(pid):
        raw = (Path('/proc') / str(pid) / 'stat').read_bytes()
        if len(raw) > 4096:
            raise ValueError('Process identity exceeds its bound')
        return raw.decode().rsplit(')', 1)[1].split()[19]
    boot = Path('/proc/sys/kernel/random/boot_id').read_text().strip()
    return f'{boot}:{ticks(1)}|{ticks(os.getpid())}'


def dispatcher_owned():
    try:
        from agent.delegation_context import is_dispatcher_owned_worker_context
        return is_dispatcher_owned_worker_context()
    except ImportError:
        return False


def _native_binding():
    fields = {name: os.environ.get('HERMES_' + name, '') for name in
              ('KANBAN_TASK', 'KANBAN_RUN_ID', 'KANBAN_BOARD', 'KANBAN_DB',
               'KANBAN_WORKSPACE', 'PROFILE', 'KANBAN_CLAIM_LOCK')}
    if (not re.fullmatch(r't_[A-Za-z0-9_]+', fields['KANBAN_TASK'])
            or not re.fullmatch(r'[1-9][0-9]{0,12}', fields['KANBAN_RUN_ID'])
            or not re.fullmatch(r'[A-Za-z0-9_-]+', fields['KANBAN_BOARD'])
            or not re.fullmatch(r'[A-Za-z0-9_-]+', fields['PROFILE'])
            or not fields['KANBAN_CLAIM_LOCK']):
        return None
    path = Path(fields['KANBAN_DB'])
    workspace = Path(fields['KANBAN_WORKSPACE'])
    if (not path.is_absolute() or path.resolve() != path
            or path.parts[-4:] != ('kanban', 'boards', fields['KANBAN_BOARD'], 'kanban.db')
            or not workspace.is_absolute() or workspace.resolve() != workspace):
        return None
    fingerprint = process_fingerprint()
    deadline = time.monotonic() + 1
    with closing(sqlite3.connect(path.as_uri() + '?mode=ro', uri=True, timeout=.2)) as db:
        db.execute('PRAGMA query_only=ON')
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        row = db.execute('''SELECT t.id FROM tasks t JOIN task_runs r
            ON r.id=t.current_run_id AND r.task_id=t.id
            WHERE t.id=? AND t.current_run_id=? AND t.status='running'
            AND r.status='running' AND r.outcome IS NULL
            AND t.assignee=? AND r.profile=t.assignee AND t.workspace_path=?
            AND t.worker_pid=? AND r.worker_pid=t.worker_pid
            AND t.worker_started_at=? AND r.worker_started_at=t.worker_started_at
            AND t.claim_lock=? AND r.claim_lock=t.claim_lock
            AND t.claim_expires>=? AND r.claim_expires>=?''',
            (fields['KANBAN_TASK'], int(fields['KANBAN_RUN_ID']), fields['PROFILE'],
             str(workspace), os.getpid(), fingerprint, fields['KANBAN_CLAIM_LOCK'],
             int(time.time()), int(time.time()))).fetchone()
    if row is None or process_fingerprint() != fingerprint:
        return None
    return {'schema_version': 1, 'task_id': fields['KANBAN_TASK'],
            'run_id': int(fields['KANBAN_RUN_ID']), 'board': fields['KANBAN_BOARD'],
            'db': str(path), 'profile': fields['PROFILE'], 'pid': os.getpid(),
            'fingerprint': fingerprint, 'workspace': str(workspace)}


def session_origin(agent, origin_json):
    """Preserve routing and explicitly deny inherited native grants to delegates.

    SessionDB can inherit origin_json from a parent. A non-null JSON object with
    native_worker=null prevents a delegated session borrowing its parent's grant.
    Compression retains the same task/run/process binding. Missing evidence
    denies tool attestation without preventing unrelated session startup.
    """
    try:
        prior = json.loads(origin_json) if origin_json else {}
    except (ValueError, TypeError):
        prior = {}
    result = dict(prior) if isinstance(prior, dict) else {}
    result['native_worker'] = None
    if (not dispatcher_owned() or getattr(agent, 'side_agent', False)
            or getattr(agent, 'platform', None) in {'subagent', 'cron'}):
        return json.dumps(result, sort_keys=True)
    try:
        result['native_worker'] = _native_binding()
    except (OSError, ValueError, TypeError, IndexError, sqlite3.Error):
        pass
    return json.dumps(result, sort_keys=True)



def _launch_directory(root, binding, create=False):
    path = Path(root)
    for part in ('runtime', 'worker-origin', str(binding['pid']) + '-' +
                 hashlib.sha256(binding['fingerprint'].encode()).hexdigest()):
        path = path / part
        if create:
            try:
                path.mkdir(mode=0o700)
            except FileExistsError:
                pass
        info = path.lstat()
        if (not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid()
                or info.st_mode & (0o022 if part == 'runtime' else 0o077)):
            raise ValueError('Native launch metadata directory is not private')
    return path


def _record_launch(proc):
    """Record actual native launch context, including explicit delegate denial.

    This cooperative same-UID provenance is written only by the maintained
    native launch seam. Caller-selected environment/session labels never grant
    authority. No process environment or command content is persisted.
    """
    binding = _native_binding()
    if binding is None:
        return
    from gateway.session_context import get_session_env
    session = get_session_env('HERMES_SESSION_ID', '')
    allowed = dispatcher_owned()
    try:
        raw = (Path('/proc') / str(proc.pid) / 'stat').read_text()
    except FileNotFoundError:
        return  # A fast command has already exited; it can claim no authority.
    fields = raw.rsplit(')', 1)[1].split()
    if fields[0] == 'Z':
        return
    if len(raw) > 4096 or int(fields[1]) != os.getpid():
        raise ValueError('Native launch process identity is unavailable')
    ticks = fields[19]
    directory = _launch_directory(Path(binding['db']).parents[3], binding, create=True)
    target = directory / (str(proc.pid) + '-' + ticks + '.json')
    receipt = {'schema_version': 1, 'pid': proc.pid, 'start_ticks': ticks,
               'native_worker': binding, 'allowed': allowed, 'session_id': session}
    encoded = json.dumps(receipt, sort_keys=True)
    if len(encoded) > 4096 or not isinstance(session, str) or len(session) > 256:
        raise ValueError('Native launch metadata exceeds its bound')
    fd, temporary = tempfile.mkstemp(dir=directory, prefix='.launch-')
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(encoded)
            stream.flush()
            os.fsync(stream.fileno())
        # Exclusive publication refuses both symlinks and stale/duplicate targets.
        os.link(temporary, target, follow_symlinks=False)
    finally:
        os.unlink(temporary)


def record_launch(proc):
    """Missing metadata denies later attestation without breaking terminal tools."""
    try:
        _record_launch(proc)
    except (OSError, ValueError, TypeError, IndexError, sqlite3.Error):
        # The command has already started. Expected metadata/storage races are
        # absence of authority, never a reason to disrupt an ordinary command.
        return


def _authenticated_current_origin(root=None, *, expected_profile=None, expected_task=None,
                                  expected_board=None, expected_workspace=None):
    """Bind a scrubbed tool process to its live native worker without exporting pins.

    The board owns PID/run identity; kernel ancestry proves descent, and the
    native session row excludes in-process delegates/cron executions. This is
    scoped file-tool provenance, never a Kanban mutation capability.
    """
    import sqlite3
    from contextlib import closing

    board = os.environ.get('HERMES_KANBAN_BOARD', '')
    raw_db = os.environ.get('HERMES_KANBAN_DB', '')
    raw_workspace = os.environ.get('HERMES_KANBAN_WORKSPACE', '')
    if not re.fullmatch(r'[A-Za-z0-9_-]+', board) or not raw_db or not raw_workspace:
        raise ValueError('Native worker location is missing')
    board_db = Path(raw_db)
    workspace = Path(raw_workspace)
    if (not board_db.is_absolute() or board_db.resolve() != board_db
            or board_db.parts[-4:] != ('kanban', 'boards', board, 'kanban.db')
            or not workspace.is_absolute() or workspace.resolve() != workspace):
        raise ValueError('Native worker location is not canonical')
    native_root = board_db.parents[3]
    if root is not None and native_root != Path(root).resolve():
        raise ValueError('Native worker belongs to another Hermes root')
    deadline = time.monotonic() + 2
    keys = {
        'HERMES_KANBAN_TASK': 'task', 'HERMES_KANBAN_RUN_ID': 'run',
        'HERMES_KANBAN_BOARD': 'board', 'HERMES_KANBAN_DB': 'db',
        'HERMES_KANBAN_WORKSPACE': 'workspace', 'HERMES_PROFILE': 'profile',
        'HERMES_SESSION_ID': 'session',
    }

    def bounded(path, limit):
        with path.open('rb') as stream:
            raw = stream.read(limit + 1)
        if len(raw) > limit or time.monotonic() > deadline:
            raise ValueError('native identity read exceeds its bound')
        return raw

    boot = bounded(Path('/proc/sys/kernel/random/boot_id'), 128).decode().strip()

    def process(pid):
        fields = bounded(Path('/proc') / str(pid) / 'stat', 4096).decode().rsplit(')', 1)[1].split()
        if fields[0] == 'Z':
            raise ValueError('native identity process has exited')
        return (pid, int(fields[1]), fields[19])

    epoch = boot + ':' + process(1)[2]

    def identity(pid):
        values = {}
        for item in bounded(Path('/proc') / str(pid) / 'environ', 1024 * 1024).split(b'\0'):
            name, sep, value = item.partition(b'=')
            field = keys.get(name.decode(errors='ignore'))
            if not sep or field is None:
                continue
            if field in values:
                raise ValueError('native identity fields are ambiguous')
            values[field] = value.decode('utf-8')
        return values

    def read_board():
        with closing(sqlite3.connect(board_db.resolve().as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
            db.row_factory = sqlite3.Row
            db.execute('PRAGMA query_only=ON')
            db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
            rows = db.execute('''SELECT t.id,t.assignee,t.workspace_path,t.current_run_id,
                t.worker_pid,t.worker_started_at,r.profile,r.started_at
                FROM tasks t JOIN task_runs r ON r.id=t.current_run_id AND r.task_id=t.id
                WHERE t.status='running' AND r.status='running'
                AND r.outcome IS NULL AND t.worker_pid=r.worker_pid
                AND t.worker_started_at=r.worker_started_at AND t.claim_lock IS NOT NULL
                AND t.claim_lock=r.claim_lock AND t.claim_expires>=?
                AND r.claim_expires>=? LIMIT 65''', (int(time.time()), int(time.time()))).fetchall()
            if len(rows) > 64:
                raise ValueError('Too many active workers for bounded attestation')
            if len({row['worker_pid'] for row in rows}) != len(rows):
                raise ValueError('native worker PID bindings are ambiguous')
            return {row['worker_pid']: dict(row) for row in rows if type(row['worker_pid']) is int}

    candidates = read_board()
    lineage = []
    pid = os.getpid()
    actor = None
    for _ in range(64):
        before = process(pid)
        fields = identity(pid)
        if process(pid) != before:
            raise ValueError('process identity changed during native measurement')
        lineage.append((before, fields))
        if pid in candidates:
            actor = candidates[pid]
            break
        # A tool descendant may not manufacture or inherit another worker's
        # task/run fields. Real native identity exists only at the recorded PID.
        if fields.get('task') or fields.get('run'):
            raise ValueError('unattested descendant carries worker identity')
        if before[1] <= 0 or before[1] == pid or any(row[0][0] == before[1] for row in lineage):
            break
        pid = before[1]
    if actor is None:
        raise ValueError('no live native worker in acting process ancestry')
    before, native = lineage[-1]
    profile = actor['assignee']
    expected = {'task': actor['id'], 'run': str(actor['current_run_id']), 'board': board,
                'db': str(board_db), 'workspace': str(workspace), 'profile': profile}
    if (actor['profile'] != profile
            or actor['workspace_path'] != str(workspace)
            or actor['worker_started_at'] != epoch + '|' + before[2]
            or any(native.get(key) != value for key, value in expected.items())):
        raise ValueError('native board/run/process identity mismatch')
    for _, fields in lineage:
        if any(key in fields and fields[key] != value for key, value in expected.items()):
            raise ValueError('conflicting identity in acting process lineage')
    expected_association = {'schema_version': 1, 'task_id': actor['id'],
                            'run_id': actor['current_run_id'], 'board': board, 'db': str(board_db),
                            'profile': profile, 'pid': pid, 'fingerprint': actor['worker_started_at'],
                            'workspace': str(workspace)}
    # The FIRST native-recorded launch owns this process tree. In-process
    # delegates share the worker PID but their launches carry an explicit deny.
    launch = None
    launch_deadline = min(deadline, time.monotonic() + .3)
    while launch is None:
        try:
            directory = _launch_directory(native_root, expected_association)
        except FileNotFoundError:
            directory = None
        for proc_identity, _ in lineage[:-1]:
            if directory is None:
                break
            target = directory / (str(proc_identity[0]) + '-' + proc_identity[2] + '.json')
            try:
                info = target.lstat()
            except FileNotFoundError:
                continue
            # Exclusive link publication briefly has two links until the
            # temporary name is removed. Wait on THIS first receipt only;
            # never skip it to an ancestor's grant or denial.
            while stat.S_ISREG(info.st_mode) and info.st_nlink == 2:
                if time.monotonic() >= launch_deadline:
                    raise ValueError('Native launch publication did not complete')
                time.sleep(.005)
                info = target.lstat()
            if (not stat.S_ISREG(info.st_mode) or info.st_uid != os.getuid()
                    or info.st_mode & 0o077 or info.st_nlink != 1):
                raise ValueError('Native launch receipt is not a private regular file')
            fd = os.open(target, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            with os.fdopen(fd, 'rb') as stream:
                if os.fstat(stream.fileno()) != info:
                    raise ValueError('Native launch receipt changed before read')
                raw = stream.read(4097)
            if len(raw) > 4096:
                raise ValueError('Native launch receipt exceeds its bound')
            launch = json.loads(raw)
            if (not isinstance(launch, dict) or launch.get('schema_version') != 1
                    or launch.get('pid') != proc_identity[0]
                    or launch.get('start_ticks') != proc_identity[2]
                    or launch.get('native_worker') != expected_association
                    or launch.get('allowed') is not True):
                raise ValueError('Actual native launch is denied or mismatched')
            break
        if launch is None:
            if time.monotonic() >= launch_deadline:
                raise ValueError('No trusted native launch association for acting process')
            time.sleep(.01)
    session = launch.get('session_id')
    if lineage[0][1].get('session') != session:
        raise ValueError('Acting session label conflicts with actual native launch')
    if not isinstance(session, str) or not session or len(session) > 256:
        raise ValueError('acting native session identity missing')
    state = board_db.parents[3] / 'profiles' / profile / 'state.db'
    with closing(sqlite3.connect(state.resolve().as_uri() + '?mode=ro', uri=True, timeout=1)) as db:
        db.execute('PRAGMA query_only=ON')
        db.set_progress_handler(lambda: int(time.monotonic() > deadline), 1000)
        row = db.execute('SELECT source,profile_name,started_at,ended_at,origin_json FROM sessions WHERE id=?', (session,)).fetchone()
    if (not row or row[0] != 'kanban' or row[1] != profile or row[3] is not None
            or row[2] < actor['started_at'] or row[2] > time.time() + 2):
        raise ValueError('acting session does not own native worker execution')
    try:
        association = json.loads(row[4] or '{}').get('native_worker')
    except (ValueError, AttributeError, TypeError):
        raise ValueError('acting session native association is malformed') from None
    if association != expected_association:
        raise ValueError('acting session is not associated with this native worker/run')
    if read_board().get(pid) != actor or any(process(old[0]) != old for old, _ in lineage):
        raise ValueError('native worker claim or process lineage changed')
    for supplied, actual in ((expected_profile, profile), (expected_task, actor['id']),
                             (expected_board, board), (expected_workspace, workspace)):
        if supplied is not None and str(supplied) != str(actual):
            raise ValueError('Native worker does not match the required installation scope')
    return dict(expected_association, session_id=session, start_ticks=before[2], boot_id=boot)


def authenticated_current_origin(root=None, *, expected_profile=None, expected_task=None,
                                 expected_board=None, expected_workspace=None):
    """Return the exact active native task/run/process/session association.

    Raise ValueError when evidence is absent, stale, delegated or outside the
    requested scope. Callers must opt into this path; it grants no operation or
    installation authority by itself. Never infer authority from a profile name.
    """
    try:
        return _authenticated_current_origin(root, expected_profile=expected_profile,
            expected_task=expected_task, expected_board=expected_board,
            expected_workspace=expected_workspace)
    except (OSError, ValueError, TypeError, KeyError, IndexError, sqlite3.Error) as exc:
        raise ValueError('Native worker attestation refused: ' + str(exc)) from None
