"""Entry point the Rust server invokes: one JSON request on stdin, one on stdout.

The helper is deliberately a callable rather than an MCP server. An MCP server
would have to be spawned by llama.cpp, run as the inference account and take
absolute paths from the model, which is exactly the containment
`office::resolve_within` exists to provide. Here the Rust process chooses which
operation runs, hands over only an already-validated absolute path, and reads
the result back itself.

Request shape, either form:

    {"op": "read", "format": "xlsx", "document": "<base64>"}
    {"op": "write", "format": "xlsx", "path": "/abs/path", "spec": {...}}

A failure exits non-zero with a JSON error object on stderr, so the caller can
turn it into a tool error without parsing a Python traceback.
"""

from __future__ import annotations

import base64
import json
import sys

from ai_tools_office import spreadsheet, word

#: Format to module. Only the two native Microsoft formats reach this helper;
#: ODF and the legacy binary formats are converted by Collabora first, so there
#: is no native reader here for them and no second ODF writer in the closure.
MODULES = {
    "xlsx": spreadsheet,
    "docx": word,
}


def _dispatch(request: dict) -> dict:
    operation = request.get("op")
    module = MODULES.get(request.get("format"))
    if module is None:
        raise ValueError(
            f"helper format {request.get('format')!r} is not one of {sorted(MODULES)}"
        )

    if operation == "read":
        return module.read(base64.b64decode(request["document"]))
    if operation == "write":
        return module.write(request["spec"], request["path"])
    raise ValueError(f"unknown operation {operation!r}")


def main() -> int:
    """Read one request, write one result. Never raises, never prints a traceback.

    The handler wraps the whole call rather than living in a
    `if __name__ == "__main__"` guard, because the installed wrapper is a
    two-line script that imports `main` and calls it. A guard would protect only
    `python -m ai_tools_office`, leaving the wrapper the Rust server actually
    runs free to emit a raw traceback into a tool result.
    """
    try:
        request = json.load(sys.stdin)
        result = _dispatch(request)
    except Exception as error:  # noqa: BLE001 - reported to the caller as JSON
        json.dump({"error": str(error) or error.__class__.__name__}, sys.stderr)
        return 1

    json.dump(result, sys.stdout)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())