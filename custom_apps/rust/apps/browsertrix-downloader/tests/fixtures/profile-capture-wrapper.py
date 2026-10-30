#!/usr/bin/env python3
"""Test-only native fixture injection; production private-URL validation stays on.

The worker validates public example.com normally. Its synthetic test container
has no network and resolves that host only to its own private fixture server.
"""
import os
import subprocess
import sys
from pathlib import Path

base = os.environ["WEB_ARCHIVES_BASE_PODMAN"]
image = os.environ["WEB_ARCHIVES_IMAGE"]
args = sys.argv[1:]
if args and args[0] == "pull":
    raise SystemExit("Fixture never pulls images")
if args and args[0] == "run":
    index = args.index(image)
    prefix = [v for v in args[1:index] if not v.startswith("--network=")]
    fixtures = str(Path(__file__).resolve().parent)
    mode = "" if os.environ.get("WEB_ARCHIVES_FIXTURE_MODE") == "site" else " --profile-mode"
    args = ["run", *prefix, "--network=none", "--add-host=example.com:127.0.0.1",
            "-v", fixtures + ":/archive-test-fixtures:ro", "--entrypoint=/bin/bash", image,
            "-c", 'python3 /archive-test-fixtures/capture_site.py' + mode + ' >/dev/null 2>&1 & fixture_server=$!; trap \'kill "$fixture_server" 2>/dev/null || true; wait "$fixture_server" 2>/dev/null || true\' EXIT; "$@"',
            "synthetic-profile-fixture", *args[index + 1:]]
raise SystemExit(subprocess.call([base, *args]))
