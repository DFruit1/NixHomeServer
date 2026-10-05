"""Native xlsx/docx editing for the ai-tools MCP server.

This is the only Python in the closure. It exists because the two native
Microsoft formats ai-tools has to round-trip do not have a mature Rust reader
or writer pair: the `docx` crate has been unmaintained since 2020 and
`docx-rs` is the least mature writer available, so a native Word round-trip in
Rust means hand-rolling WordprocessingML. `openpyxl` and `python-docx` are the
mature, widely deployed components for exactly these two formats.

It is a callable helper, never an MCP server. It holds no filesystem grant of
its own, it never resolves a path the caller did not hand it, and it reaches no
network. `ai-tools` validates every path against the shared root or the AI
workspace before anything here runs, and the systemd unit confines writes with
ReadWritePaths so a bug in that validation is still not a write anywhere else.

Reads are passed in as bytes on stdin rather than as a path. Collabora already
converts ods, odt, doc and rtf to xlsx/docx, so the caller normalises the
format first and this package only ever sees native OOXML. Writes are given an
absolute path that the caller has already resolved inside the workspace.
"""

__all__ = ["spreadsheet", "word"]