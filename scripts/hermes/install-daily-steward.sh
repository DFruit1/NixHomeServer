#!/bin/sh
# Install the read-only steward policy, tool guard and regular report prompts.
# Existing jobs are updated in place; models and channel bindings are retained.
set -eu
src="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
exec python3 "$src/install-steward-readonly.py" "$@"
