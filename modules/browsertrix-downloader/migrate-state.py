#!/usr/bin/env python3
"""Provisioning glue, not an application database migration.

Python's stdlib SQLite backup API keeps this offline, module-owned operation
independent of the application/frontend build and adds no Cargo dependencies.
WSD-002 risk: an old closure ignores private capture options and mutates expanded
jobs. Never expand its database, overwrite either history, or ignore divergence.
"""

import argparse
from contextlib import ExitStack, contextmanager
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import stat
import tempfile


ORIGIN = "private_state_origin"
ABSENT = "absent"


def regular_file(path):
    try:
        mode = path.lstat().st_mode
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(mode):
        raise ValueError(f"Refusing non-regular database: {path}")
    # SQLite can follow a sidecar symlink before any application SQL is run.
    for suffix in ("-wal", "-shm", "-journal"):
        sidecar = Path(str(path) + suffix)
        if sidecar.is_symlink():
            raise ValueError(f"Refusing database sidecar symlink: {sidecar}")
    return True


@contextmanager
def connection(path, mode):
    with ExitStack() as stack:
        db = sqlite3.connect(path.as_uri() + f"?mode={mode}", uri=True, timeout=5)
        stack.callback(db.close)
        yield db


def quote(name):
    return '"' + name.replace('"', '""') + '"'


def logical_digest(db):
    """Stable across WAL checkpoints, VACUUM and optimizer statistics updates."""
    digest = hashlib.sha256()

    def record(row):
        values = [
            {"blob": value.hex()} if isinstance(value, bytes) else value
            for value in row
        ]
        digest.update(json.dumps(values, ensure_ascii=True, separators=(",", ":")).encode())
        digest.update(b"\n")

    schema = db.execute(
        "SELECT type,name,tbl_name,sql FROM sqlite_master "
        "WHERE name NOT LIKE 'sqlite_stat%' ORDER BY type,name"
    ).fetchall()
    for row in schema:
        record(row)
        kind, name, _, _ = row
        if kind == "table":
            columns = db.execute(f"PRAGMA table_info({quote(name)})").fetchall()
            ordering = ",".join(str(i + 1) for i in range(len(columns)))
            for contents in db.execute(f"SELECT * FROM {quote(name)} ORDER BY {ordering}"):
                record(contents)
    return digest.hexdigest()


def require_legacy(db):
    tables = {row[0] for row in db.execute("SELECT name FROM sqlite_master WHERE type='table'")}
    columns = {row[1] for row in db.execute("PRAGMA table_info(jobs)")}
    if "runtime_json" in columns or tables - {
        "jobs", "job_events", "schema_migrations", "sqlite_sequence", "sqlite_stat1", "sqlite_stat4"
    }:
        raise ValueError("Legacy path already contains expanded/unknown state; preserve it and reconcile offline")
    if db.execute("PRAGMA quick_check").fetchone() != ("ok",):
        raise ValueError("Legacy SQLite integrity check failed; original retained")


def check_origin(db, source, digest):
    try:
        origin = db.execute(f"SELECT legacy_path,legacy_digest FROM {ORIGIN} WHERE id=1").fetchone()
    except sqlite3.DatabaseError as error:
        raise ValueError("Private database lacks its import receipt; preserve both databases and reconcile offline") from error
    if origin != (str(source), digest):
        raise ValueError(
            "Legacy database changed after private-state import; both histories retained. "
            "Stop both services and reconcile offline before restarting; never restore over either database."
        )


def provision(source, destination, check=False):
    source = source.absolute()
    destination = destination.absolute()
    if source == destination or source.resolve() == destination.resolve():
        raise ValueError("Private and legacy databases must be separate paths")
    if destination.parent.is_symlink() or not destination.parent.is_dir():
        raise ValueError("Private destination parent must be an existing real directory")
    with ExitStack() as stack:
        original = None
        if regular_file(source):
            # Reserve the writer slot without changing rows/schema. A separate
            # read connection can back up this stable committed snapshot, WAL
            # included. Old writers time out rather than racing the handoff.
            lock = stack.enter_context(connection(source, "rw"))
            lock.execute("BEGIN IMMEDIATE")
            original = stack.enter_context(connection(source, "ro"))
            original.execute("BEGIN")
            require_legacy(original)
        fingerprint = logical_digest(original) if original else ABSENT
        if regular_file(destination):
            with connection(destination, "ro") as existing:
                check_origin(existing, source, fingerprint)
            return
        if check:
            raise ValueError("Private database missing; run the stopped-service storage provisioning first")

        # Stage on the destination filesystem, never publish a partially copied
        # database. A crash before linking leaves the legacy source authoritative.
        with tempfile.TemporaryDirectory(prefix=".private-import-", dir=destination.parent) as stage:
            staged = Path(stage) / "database.sqlite"
            with connection(staged, "rwc") as copied:
                if original:
                    original.backup(copied)
                copied.execute("PRAGMA journal_mode=DELETE")
                if original and logical_digest(copied) != fingerprint:
                    raise ValueError("Legacy backup snapshot differs; no private database published")
                copied.execute(
                    f"CREATE TABLE {ORIGIN}(id INTEGER PRIMARY KEY CHECK(id=1),"
                    "legacy_path TEXT NOT NULL,legacy_digest TEXT NOT NULL)"
                )
                copied.execute(f"INSERT INTO {ORIGIN} VALUES(1,?,?)", (str(source), fingerprint))
                copied.commit()
            os.chmod(staged, 0o600)
            with staged.open("rb") as handle:
                os.fsync(handle.fileno())
            # Recheck separately after the copy, before publishing. The reserved
            # lock is held through publication; no concurrent legacy commit fits
            # between the recheck and the handoff.
            if original:
                with connection(source, "ro") as latest:
                    if logical_digest(latest) != fingerprint:
                        raise ValueError("Legacy database changed during copy; original retained")
            elif source.exists() or source.is_symlink():
                raise ValueError("Legacy database appeared during copy; retry with services stopped")
            os.link(staged, destination)  # Exclusive: never overwrite an existing v2 database.
            descriptor = os.open(destination.parent, os.O_DIRECTORY)
            try:
                os.fsync(descriptor)
            finally:
                os.close(descriptor)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify receipt on every service start; never import")
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        provision(args.source, args.destination, args.check)
    except (OSError, sqlite3.Error, ValueError) as error:
        parser.exit(1, f"Browsertrix private state: {error}\n")


if __name__ == "__main__":
    main()
