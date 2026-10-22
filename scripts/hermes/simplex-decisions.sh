#!/bin/sh
# Manage messages in the coordinator's current-decisions SimpleX group.
# Usage: simplex-decisions.sh --check
#        simplex-decisions.sh --list
#        simplex-decisions.sh post KEY   < body
#        simplex-decisions.sh edit KEY   < body
#        simplex-decisions.sh delete KEY
set -eu
# Always use the shared/default root (HERMES_ROOT): the bundled Python, the
# Hermes source tree and the SimpleX credentials all live there, even when the
# caller is a named profile with its own HERMES_HOME.
root="${HERMES_ROOT:-$HOME/.hermes}"
py="$(ls -d "$root"/tools/python-*/bin/python3 2>/dev/null | head -n1)"
[ -n "$py" ] || { echo "simplex-decisions: Hermes python not found under $root/tools" >&2; exit 2; }
HERMES_HOME="$root" exec "$py" "$root/scripts/simplex_decisions.py" "$@"
