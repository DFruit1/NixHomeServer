#!/bin/sh
# Send stdin text to a SimpleX group via the local daemon (outbound only).
# Usage: simplex-send-group.sh GROUP_ID  < body
set -eu
group="${1:?usage: simplex-send-group.sh GROUP_ID < body}"
# Always use the shared/default root (HERMES_ROOT): the bundled Python, the
# Hermes source tree and the SimpleX credentials all live there, even when the
# caller is a named profile with its own HERMES_HOME.
root="${HERMES_ROOT:-$HOME/.hermes}"
py="$(ls -d "$root"/tools/python-*/bin/python3 2>/dev/null | head -n1)"
[ -n "$py" ] || { echo "simplex-send-group: Hermes python not found under $root/tools" >&2; exit 2; }
HERMES_HOME="$root" exec "$py" "$root/scripts/simplex_send_group.py" "$group"
