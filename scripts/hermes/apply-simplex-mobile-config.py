#!/usr/bin/env python3
"""Apply the SimpleX mobile-chat surface to one profile's config.yaml.

This is the durable half of two fixes, both of which failed silently until a
human noticed:

1. ``platform_toolsets`` had no ``simplex`` entry, so toolset resolution fell
   back to the ``hermes-simplex`` composite -- a name that is not registered
   anywhere. The result was a channel that was MISSING kanban (the head
   coordinator's main tool) while granting eight toolsets the CLI profile
   deliberately does not grant.

2. ``display`` had no ``platforms.simplex`` entry, so the channel took the
   global defaults. SimpleX cannot edit messages (the adapter does not
   implement ``edit_message``), so every one of those defaults degrades into a
   NEW chat message rather than an edit in place: interim assistant commentary
   arrived one message at a time, and the long-running heartbeat posted a fresh
   "Working" bubble every ``agent.gateway_notify_interval`` seconds with the
   iteration counter attached.

The display values below are the ``_TIER_LOW`` set the gateway already uses for
every other non-editable platform (signal, photon, bluebubbles, weixin), plus
``interim_assistant_messages: false`` -- a chat operator wants the answer after
the turn, not a narration stream during it.

Stdlib only: this runs on a workstation whose hermes python is not on PATH, and
a helper that needed ruamel would fail on the one machine that has to run it.
"""

from __future__ import annotations

import argparse
import re
import sys

# The mobile surface. Written under ``display.platforms.simplex``. The comment
# leads the block so the reader meets the reason before the settings.
DISPLAY_BLOCK = [
    "    # SimpleX is a phone channel and the adapter cannot edit messages, so",
    "    # every progress surface would become a NEW message rather than an edit",
    "    # in place. This is the tier the gateway already uses for the other",
    "    # non-editable platforms (signal, photon, bluebubbles, weixin), plus",
    "    # interim_assistant_messages off: the answer lands once, after the turn,",
    "    # instead of arriving as a narration stream during it.",
    "    # Written by scripts/hermes/apply-simplex-mobile-config.py.",
    "    simplex:",
    "      tool_progress: off",
    "      show_reasoning: false",
    "      interim_assistant_messages: false",
    "      long_running_notifications: false",
    "      busy_ack_detail: false",
    "      busy_steer_ack_enabled: false",
    "      streaming: false",
    "      tool_preview_length: 0",
    "      cleanup_progress: true",
]

_WANTED = {
    "tool_progress": "off",
    "show_reasoning": "false",
    "interim_assistant_messages": "false",
    "long_running_notifications": "false",
    "busy_ack_detail": "false",
    "busy_steer_ack_enabled": "false",
    "streaming": "false",
    "tool_preview_length": "0",
    "cleanup_progress": "true",
}

# The owner's toolset comes from its ``cli`` entry, so "SimpleX has the same
# powers as the CLI" is a property of this file rather than a list duplicated
# into a third place to drift.
_CLI_KEY_RE = re.compile(r"^(\s*)cli:\s*\[([^\]]*)\]\s*$", re.M)


def _strip_quoted(text: str, key: str) -> str | None:
    """One scalar's value under a two-space-indented YAML mapping."""
    m = re.search(r"^\s*%s:\s*(\S+)\s*$" % re.escape(key), text, re.M)
    return m.group(1) if m else None


def _block(text: str, key: str, indent: str = "") -> tuple[int, int] | None:
    """``(start, end)`` line span of the mapping ``<indent><key>:``.

    *indent* is the literal leading whitespace of the key, so a top-level block
    passes ``""`` and a nested one ``"  "``. Detecting the indent rather than
    assuming it is the difference between editing ``display:`` and silently
    not finding it -- which reads as "the config is already correct" while
    nothing was applied.
    """
    lines = text.split("\n")
    pad = re.compile(r"^%s%s:\s*$" % (indent, re.escape(key)))
    start = None
    for i, line in enumerate(lines):
        if pad.match(line):
            start = i
            break
    if start is None:
        return None
    end = start + 1
    # A block runs until a line that is neither deeper-indented nor blank. A
    # comment at column 0 does NOT end it: this config separates every section
    # with a `# ====` banner, and treating those banners as terminators stops
    # the span early -- `display:` then "ends" at its first banner and the
    # `platforms:` key that follows reads as absent, so the helper reports
    # drift on a file that is already correct and appends a second block.
    while end < len(lines):
        line = lines[end]
        if line == "" or line.lstrip().startswith("#") or line.startswith(indent + " "):
            end += 1
            continue
        break
    # Trim trailing blank lines from the span; they belong to what follows.
    while end > start + 1 and lines[end - 1] == "":
        end -= 1
    return start, end


def _yaml_list(value: str) -> str:
    return "[%s]" % ", ".join(v.strip() for v in value.split(",") if v.strip())


def apply(text: str, profile: str) -> tuple[str, list[str]]:
    """Return ``(new_text, changes)``; ``changes`` is empty when nothing moved."""
    changes: list[str] = []

    # --- 1. platform_toolsets.simplex = the owner's cli list -----------------
    cli = _CLI_KEY_RE.search(text)
    if cli is None:
        raise SystemExit(
            "apply-simplex-mobile-config: no `  cli: [...]` line under "
            "platform_toolsets: in %s; cannot derive the SimpleX toolset" % profile
        )
    indent, names = cli.group(1), cli.group(2).strip()
    want = _yaml_list(names)
    have = re.search(r"^\s*simplex:\s*\[([^\]]*)\]\s*$", text, re.M)
    if have is None:
        text = text[: cli.start()] + cli.group(0) + "\n" + indent + "simplex: " + want + text[cli.end():]
        changes.append("platform_toolsets.simplex = %s" % want)
    else:
        got = _yaml_list(have.group(1).strip())
        if got != want:
            changes.append("platform_toolsets.simplex: %s -> %s" % (got, want))
            text = text[: have.start()] + indent + "simplex: " + want + text[have.end():]

    # --- 2. known_plugin_toolsets.simplex, mirroring the owner's cli entry ---
    #
    # A plugin toolset that is not in ``known_plugin_toolsets[platform]`` and
    # not on the saved list is enabled by default. ``cli`` carries the
    # enumeration that keeps them off; a fresh ``simplex`` key has none, so
    # homeassistant arrives unasked. Mirroring ``cli`` is the fix.
    span = _block(text, "known_plugin_toolsets", "")
    if span is not None:
        block = text.split("\n")[span[0]: span[1]]
        cli_sub = None
        for i, line in enumerate(block):
            if re.match(r"^  cli:\s*$", line):
                cli_sub = i
                break
        if cli_sub is not None:
            j = cli_sub + 1
            plugins: list[str] = []
            while j < len(block) and block[j].startswith("    - "):
                plugins.append(block[j].strip()[2:].strip())
                j += 1
            if plugins:
                lines = text.split("\n")
                at = span[0] + j
                if not any(re.match(r"^  simplex:\s*$", l) for l in lines[span[0]:span[1]]):
                    lines[at:at] = ["  simplex:"] + ["    - %s" % p for p in plugins]
                    text = "\n".join(lines)
                    changes.append("known_plugin_toolsets.simplex = %s" % ", ".join(plugins))
                else:
                    for i, line in enumerate(lines[span[0]:span[1]], start=span[0]):
                        if re.match(r"^  simplex:\s*$", line):
                            j = i + 1
                            got = []
                            while j < len(lines) and lines[j].startswith("    - "):
                                got.append(lines[j].strip()[2:].strip())
                                j += 1
                            if got != plugins:
                                lines[i + 1:j] = ["    - %s" % p for p in plugins]
                                text = "\n".join(lines)
                                changes.append("known_plugin_toolsets.simplex corrected")
                            break

    # --- 3. display.platforms.simplex ---------------------------------------
    display_top = re.search(r"^display:\s*$", text, re.M)
    if display_top is None:
        raise SystemExit(
            "apply-simplex-mobile-config: no top-level `display:` block in %s" % profile
        )
    existing = _block(text, "display", "")
    if existing is None:
        raise SystemExit(
            "apply-simplex-mobile-config: the top-level `display:` block in %s is empty" % profile
        )
    lines = text.split("\n")
    d0, d1 = existing
    sub_at = None
    for i in range(d0 + 1, d1):
        if lines[i].startswith("  platforms:"):
            sub_at = i
            break

    desired = DISPLAY_BLOCK
    if sub_at is None:
        # No `display.platforms:` at all: append one at the END of the display
        # block. Putting it directly after `display:` would read as the block's
        # first key and push the operator's own keys below a comment wall.
        lines = text.split("\n")
        lines[d1:d1] = ["", "  platforms:"] + desired
        text = "\n".join(lines)
        changes.append("display.platforms.simplex created (%d keys)" % len(_WANTED))
    else:
        # Locate the simplex mapping under platforms:, if there is one.
        end = sub_at + 1
        while end < len(lines) and (lines[end].startswith("    ") or lines[end] == ""):
            end += 1
        while end > sub_at + 1 and lines[end - 1] == "":
            end -= 1
        sx_at = None
        for i in range(sub_at + 1, end):
            if re.match(r"^    simplex:\s*$", lines[i]):
                sx_at = i
                break
        if sx_at is None:
            # Append after the last sibling, keeping the file's own ordering.
            anchor = sub_at + 1
            for i in range(sub_at + 1, end):
                if re.match(r"^    [A-Za-z_]+:", lines[i]):
                    anchor = i + 1
            lines[anchor:anchor] = desired
            text = "\n".join(lines)
            changes.append("display.platforms.simplex created (%d keys)" % len(_WANTED))
        else:
            stop = sx_at + 1
            while stop < len(lines) and (lines[stop].startswith("      ") or lines[stop] == ""):
                stop += 1
            while stop > sx_at + 1 and lines[stop - 1] == "":
                stop -= 1
            sub = lines[sx_at + 1:stop]
            edited = False
            for key, want_v in _WANTED.items():
                at = next((i for i, l in enumerate(sub) if re.match(r"^      %s:" % re.escape(key), l)), None)
                if at is None:
                    sub.append("      %s: %s" % (key, want_v))
                    edited = True
                else:
                    cur = sub[at].split(":", 1)[1].strip()
                    if cur != want_v:
                        sub[at] = "      %s: %s" % (key, want_v)
                        edited = True
            if edited:
                # Keep the operator's own ordering where it already exists; the
                # written block is the documented set, not a merge of two.
                lines[sx_at + 1:stop] = sub
                text = "\n".join(lines)
                changes.append("display.platforms.simplex enforced")
    return text, changes


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n", 1)[0])
    ap.add_argument("config", help="profile config.yaml to edit in place")
    ap.add_argument("--check", action="store_true", help="report drift, change nothing")
    args = ap.parse_args(argv)

    try:
        text = open(args.config, encoding="utf-8").read()
    except OSError as exc:
        sys.stderr.write("apply-simplex-mobile-config: cannot read %s: %s\n" % (args.config, exc))
        return 2

    try:
        new_text, changes = apply(text, args.config)
    except SystemExit as exc:
        sys.stderr.write("%s\n" % exc)
        return 2

    if not changes:
        print("ok: %s already carries the SimpleX mobile surface" % args.config)
        return 0
    for line in changes:
        print("would change: %s" % line if args.check else "changed: %s" % line)
    if args.check:
        return 0
    with open(args.config, "w", encoding="utf-8") as handle:
        handle.write(new_text)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
