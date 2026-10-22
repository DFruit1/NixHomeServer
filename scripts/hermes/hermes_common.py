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


# Shared by instruction/taskforce installers: a reinstall must not resurrect a
# narrower role description than the managed instructions it just installed.
PROFILE_DESCRIPTIONS = {
    'standard-implementer': ('STANDARD IMPLEMENTER. Default for implementation without direct credential-value handling, '
        'tests and documentation in the assigned durable workspace. Models and fallbacks come from configuration; '
        'provider failures follow bounded recovery. Commits locally after the owning gate and hands exact evidence '
        'to independent acceptance by feature-reviewer or a qualified project-auditor. Never publishes.'),
    'local-implementer': ('LOCAL IMPLEMENTER. Only the smallest bounded step requiring direct handling of actual '
        'passwords, API keys, tokens, private keys or equivalent credentials. Explicit secret boundary and runtime '
        'cap required. Surrounding source, mocks, tests and composition use standard-implementer. Private data, '
        'paths and telemetry alone do not qualify. Never send credentials to remote models or tools.'),
    'head-coordinator': ('HEAD COORDINATOR. Routes and decomposes work; may inspect source, run validation and '
        'perform mechanical integration repairs with independent acceptance. Records delegated decisions, '
        'integrates accepted work and runs guarded deployments. Preserves exact owner scope, reserved effects, '
        'credential isolation and independent review; never self-approves.'),
    'project-auditor': ('ON-DEMAND PROJECT AUDITOR. Architectural questions, substantive plans and repeated failed recovery. '
        'Routine fixes use implementer and independent reviewer directly. Owns persisted FINDINGS.md and immutable plans. '
        'Commissions focused audits, assesses findings and technical plans. May provide independent source and '
        'whole-set verification when qualified and neither plan author nor implementer. Never implements or deploys.'),
    'feature-reviewer': ('FEATURE-REVIEWER. Independently verifies source, bounded questions and whole deployment '
        'sets against acceptance criteria; audits idle features on auditor commission. May correct a question premise '
        'within the same outcome. Never implements, edits FINDINGS.md or batch plans, or deploys.'),
}


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


def remove_block(text, start, end, label='managed'):
    """Drop one managed block, leaving the surrounding text otherwise stable.

    A role that must converge to the absence of a block (for example the
    routing-only default profile) needs a removal, not a rewrite: re-installing
    a different block would leave stale text behind forever. Ambiguous markers
    are refused exactly as in the block installers so a damaged section is
    reconciled deliberately rather than guessed at.
    """
    if start not in text and end not in text:
        return text
    if text.count(start) != 1 or text.count(end) != 1 or text.index(end) < text.index(start):
        raise ValueError(f'Ambiguous {label} markers')
    head = text[:text.index(start)].rstrip('\n')
    tail = text[text.index(end) + len(end):].lstrip('\n')
    if not head:
        return tail
    return head + '\n\n' + tail if tail else head + '\n'


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
