#!/usr/bin/env python3
"""Compact Hermes YAML without changing settings; share bounded tool-list edits.

Python operations glue reuses Hermes' existing PyYAML dependency. Values are
never logged or expanded. Compaction keeps explicit defaults: absence can change
meaning between Hermes consumers and versions.
"""
import argparse
import fcntl
import hashlib
import os
from pathlib import Path
import stat
import sys

import yaml


class UniqueLoader(yaml.SafeLoader):
    def construct_mapping(self, node, deep=False):
        self.flatten_mapping(node)
        keys = [self.construct_object(key, deep=deep) for key, _ in node.value]
        if len(keys) != len(set(keys)):
            raise ValueError('Duplicate YAML mapping keys; reconcile before editing')
        return super().construct_mapping(node, deep=deep)


def document(text):
    """Reject ambiguous input and suppress parser snippets that could leak values."""
    try:
        if any(isinstance(token, yaml.tokens.AliasToken) for token in yaml.scan(text)):
            raise ValueError('YAML aliases are unsupported; reconcile before editing')
        data = yaml.load(text, Loader=UniqueLoader)
        if not isinstance(data, dict):
            raise ValueError('Expected a single YAML configuration mapping')
        return data
    except (yaml.YAMLError, TypeError):
        raise ValueError('Invalid or unsupported YAML configuration; no values logged') from None


def platform_tools(text, platform, *, add=(), replace=None, optional=False):
    data = document(text)
    platforms = data.get('platform_toolsets', {})
    if not isinstance(platforms, dict):
        raise ValueError('Expected platform_toolsets mapping')
    if platform not in platforms:
        if optional:
            return text
        raise ValueError(f'Missing platform_toolsets.{platform}')
    current = platforms[platform]
    if not isinstance(current, list) or any(not isinstance(tool, str) for tool in current):
        raise ValueError(f'Expected tool list at platform_toolsets.{platform}')
    desired = list(replace) if replace is not None else current + [tool for tool in add if tool not in current]
    if desired == current:
        return text
    # Use YAML marks rather than a regex: both block and flow sequences are valid.
    node = yaml.compose(text)
    mapping = next(value for key, value in node.value if key.value == 'platform_toolsets')
    sequence = next(value for key, value in mapping.value if key.value == platform)
    start, end = sequence.start_mark.index, sequence.end_mark.index
    rendered = yaml.safe_dump(desired, default_flow_style=True, width=100000).strip()
    if not sequence.flow_style:
        # Stop at the last item: the sequence's end mark can consume comments
        # and the indentation belonging to the following mapping key.
        end = sequence.value[-1].end_mark.index
    updated = text[:start] + rendered + text[end:]
    expected = document(text)
    expected['platform_toolsets'][platform] = desired
    if document(updated) != expected:
        raise ValueError('Tool-list edit would change unrelated settings')
    return updated


def compact(text, reference):
    before = document(text)
    reference_comments = {line.strip() for line in reference.splitlines() if line.strip().startswith('#')}
    protected = set()
    for token in yaml.scan(text):
        if isinstance(token, yaml.tokens.ScalarToken) and token.end_mark.line > token.start_mark.line:
            protected.update(range(token.start_mark.line, token.end_mark.line + 1))
    lines = []
    for number, line in enumerate(text.splitlines(keepends=True)):
        stripped = line.strip()
        if (number in protected or stripped.startswith('# nixhomeserver-')
                or (stripped and stripped not in reference_comments)):
            lines.append(line)
    updated = ''.join(lines)
    if document(updated) != before:
        raise ValueError('Compaction would change configuration values')
    return updated


def install(root, check=False, reference=None):
    example = reference or root / 'hermes-agent/cli-config.yaml.example'
    reference_text = example.read_text()
    paths = [root / 'config.yaml', *sorted((root / 'profiles').glob('*/config.yaml'))]
    pending = []
    for path in paths:
        if path.parent.name.startswith('.') and path != root / 'config.yaml':
            continue
        if path.is_symlink():
            raise ValueError(f'Refusing symlink config: {path}')
        old = path.read_bytes()
        updated = compact(old.decode(), reference_text).encode()
        if old != updated:
            pending.append((path, old, updated, path.stat()))
    # Validate every config before touching any. Backups are permanent private
    # config archives, never repo files or plaintext temporary staging files.
    for path, old, updated, previous in pending:
        print(f'{"drift" if check else "compact"}: {path} ({len(old)} -> {len(updated)} bytes)')
        if check:
            continue
        fd = os.open(path, os.O_RDWR | os.O_NOFOLLOW)
        with os.fdopen(fd, 'r+b') as stream:
            fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            if (stream.read() != old or path.stat() != previous
                    or os.fstat(stream.fileno()) != previous):
                raise ValueError(f'Config changed during preflight: {path}; retry after its writer finishes')
            archive = root / 'backups/config-compaction' / hashlib.sha256(str(path).encode()).hexdigest()[:12]
            archive.mkdir(parents=True, exist_ok=True, mode=0o700)
            archive.chmod(0o700)
            backup = archive / hashlib.sha256(old).hexdigest()
            if not backup.exists():
                fd = os.open(backup, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
                with os.fdopen(fd, 'wb') as saved:
                    saved.write(old)
                    saved.flush()
                    os.fsync(saved.fileno())
            if backup.read_bytes() != old or stat.S_IMODE(backup.stat().st_mode) != 0o600:
                raise ValueError(f'Invalid private backup: {backup}')
            # Retain the inode and permissions. A failed write is recoverable from
            # the durable archive; no credential-bearing temporary file is made.
            stream.seek(0)
            stream.write(updated)
            stream.truncate()
            stream.flush()
            os.fsync(stream.fileno())
    return int(check and bool(pending))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true')
    parser.add_argument('--reference', type=Path, help='Upstream cli-config.yaml.example; only its comments are removed')
    args = parser.parse_args()
    try:
        sys.exit(install(Path(os.environ.get('HERMES_ROOT', str(Path.home() / '.hermes'))), args.check, args.reference))
    except (ValueError, OSError, UnicodeError) as exc:
        print(f'config compaction: {exc}', file=sys.stderr)
        sys.exit(2)
