"""Shared helpers for the Hermes installer scripts.

Operations glue only: standard-library Python, no new dependency and no model
calls. Scripts run both from the checkout and as installed copies, and each
installer already loaded its siblings by file location, so this module sits
beside its importers in scripts/hermes/ and is imported normally.

Every installer that edits a live file under ~/.hermes writes through
atomic_write and archives the previous bytes with backup_file, so a crash or
kill mid-write can never truncate a live policy or config file and every edit
has an undo under the private backups tree.
"""
import hashlib
import os
import tempfile
from pathlib import Path


def atomic_write(path, content, mode=None):
    """Write text to path via temp file + fsync + rename.

    The previous file is replaced atomically, so an interrupted write leaves
    either the old or the new content, never a truncated file. The existing
    mode is preserved when the file already exists; a new file is created
    private (0o600) unless an explicit mode is given.
    """
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    target_mode = mode if mode is not None else (
        path.stat().st_mode & 0o777 if path.exists() else 0o600)
    fd, temporary = tempfile.mkstemp(dir=str(path.parent), prefix=f'.{path.name}.')
    try:
        with os.fdopen(fd, 'w') as stream:
            stream.write(content)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temporary, target_mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def backup_file(root, subdir, path):
    """Archive an existing file under root/backups/<subdir>/ before changing it.

    The archive is content-addressed: the directory is a short hash of the file
    path and the file is the hash of the previous bytes, so re-runs do not
    accumulate copies and identical content is stored once.
    """
    path = Path(path)
    if not path.exists():
        return None
    old = path.read_bytes()
    backup = Path(root) / 'backups' / subdir / hashlib.sha256(str(path).encode()).hexdigest()[:12]
    backup.mkdir(parents=True, exist_ok=True, mode=0o700)
    copy = backup / hashlib.sha256(old).hexdigest()
    if not copy.exists():
        copy.write_bytes(old)
        copy.chmod(0o600)
    return copy
