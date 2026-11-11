"""Bounded byte parser behind Rust's Landlock/seccomp exec boundary.

Production uses read/render/edit requests over stdin and returns JSON/base64.
The legacy write-path operation remains for existing standalone helper tests;
Landlock denies all filesystem writes in the production parser process.
"""

from __future__ import annotations

import base64
import json
import io
import sys

from ai_tools_office import spreadsheet, word, ooxml

#: Format to module. Only the two native Microsoft formats reach this helper;
#: ODF and the legacy binary formats are converted by Collabora first, so there
#: is no native reader here for them and no second ODF writer in the closure.
MODULES = {
    "xlsx": spreadsheet,
    "docx": word,
}


def _dispatch(request: dict) -> dict:
    operation = request.get("op")
    if operation == "probe":
        # Exercise actual native creation as well: openpyxl's default save
        # unexpectedly requires temp files even with a BytesIO destination.
        spreadsheet.write({"sheets": [{"name": "Probe", "rows": [[1]]}]}, io.BytesIO())
        word.write({"blocks": [{"text": "Probe"}]}, io.BytesIO())
        import socket
        try:
            with open("/etc/passwd", "rb") as source:
                source.read(1)
        except PermissionError:
            pass
        else:
            raise ValueError("parser filesystem isolation failed")
        try:
            socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        except PermissionError:
            return {"sandboxed": True}
        raise ValueError("parser socket isolation failed")
    module = MODULES.get(request.get("format"))
    if module is None:
        raise ValueError(
            f"helper format {request.get('format')!r} is not one of {sorted(MODULES)}"
        )

    if operation == "read":
        document = base64.b64decode(request["document"], validate=True)
        with ooxml.package(document):
            result = module.read(document)
            if "offset" not in request:
                return result
            offset = request["offset"]
            if not isinstance(offset, int) or isinstance(offset, bool) or not 0 <= offset <= 100000:
                raise ValueError("offset must be an integer from 0 to 100000")
            if request["format"] == "xlsx":
                items = [{"sheet": sheet["name"], "row": index + 1, "values": row}
                         for sheet in result.pop("sheets") for index, row in enumerate(sheet["rows"])]
            else:
                items = [{"block": index, **block} for index, block in enumerate(result.pop("blocks"))]
            selected = []
            spent = 0
            for item in items[offset:]:
                length = len(json.dumps(item, ensure_ascii=True))
                if length > 24000:
                    item = {key: item[key] for key in ("sheet", "row", "block") if key in item}
                    item["content_omitted"] = "Entry exceeds the 24000-character view limit"
                    length = len(json.dumps(item))
                if selected and spent + length > 24000:
                    break
                selected.append(item)
                spent += length
            result.update({"items": selected, "offset": offset, "next_offset": offset + len(selected) if offset + len(selected) < len(items) else None,
                           "view_only": True, "warning": "Use targeted edits on the original file; never rebuild from this bounded view."})
            return result
    if operation in {"render", "edit"}:
        if operation == "edit":
            document = ooxml.edit(base64.b64decode(request["document"], validate=True), request["format"], request["spec"])
        else:
            output = io.BytesIO()
            module.write(request["spec"], output)
            document = output.getvalue()
        if len(document) > ooxml.MAX_DOCUMENT_BYTES:
            raise ValueError("document exceeds the 32 MiB output limit")
        return {"document": base64.b64encode(document).decode("ascii"), "format": request["format"], "recalculated": False}
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
