#!/usr/bin/env python3
"""Send stdin text to a SimpleX group through the local simplex-chat daemon.

Outbound-only, loopback-only. Run it with the Hermes bundled Python (see
``simplex-send-group.sh``), which makes the vendored ``websockets`` importable.
Usage: simplex_send_group.py GROUP_ID  < body
"""

from __future__ import annotations

import asyncio
import json
import os
import sys
from pathlib import Path

# Shared/default root, not a profile home: the Hermes source tree and the
# SimpleX credentials live here regardless of the invoking profile.
HOME = Path(os.environ.get("HERMES_ROOT", str(Path.home() / ".hermes")))
sys.path.insert(0, str(HOME / "hermes-agent"))
import hermes_bootstrap  # noqa: E402,F401  (sets up Hermes runtime paths)

import websockets  # noqa: E402

DEFAULT_WS = "ws://127.0.0.1:5225"


def ws_url() -> str:
    env = HOME / "profiles" / "head-coordinator" / ".env"
    if env.exists():
        for line in env.read_text().splitlines():
            if line.strip().startswith("SIMPLEX_WS_URL="):
                return line.split("=", 1)[1].strip()
    return DEFAULT_WS


async def send(group: str, text: str) -> None:
    items = [{"msgContent": {"type": "text", "text": text}}]
    cmd = f"/_send #{group} json {json.dumps(items)}"
    async with websockets.connect(ws_url(), max_size=None) as ws:
        await ws.send(json.dumps({"corrId": "steward", "cmd": cmd}))
        try:
            await asyncio.wait_for(ws.recv(), timeout=8)
        except asyncio.TimeoutError:
            pass  # text sends are fire-and-forget in the adapter too


def main() -> None:
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        print("usage: simplex_send_group.py GROUP_ID < body", file=sys.stderr)
        sys.exit(2)
    text = sys.stdin.read().strip()
    if not text:
        sys.exit(0)
    try:
        asyncio.run(send(sys.argv[1].strip(), text))
    except Exception as exc:  # noqa: BLE001 - surface a non-zero exit to the caller
        print(f"simplex_send_group: {exc}", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()
