#!/usr/bin/env bash
# Run the office helper's unit tests against a pinned interpreter.
#
# Kept as a script rather than an inline command so the Nix check, a developer
# shell and this card's own verification all invoke exactly the same thing, and
# so no step has to set PYTHONPATH in the environment of a shell it does not
# control. The package is put on the path with an explicit `-c`/`-m` argument
# rather than an exported variable.
#
# Usage: run-helper-tests.sh <python3-with-openpyxl-and-python-docx>

set -euo pipefail

if (($# != 1)); then
  echo "usage: ${BASH_SOURCE[0]} <python3 interpreter>" >&2
  exit 1
fi

python="${1}"
helper_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$helper_root"
exec "$python" -m unittest discover --start-directory tests --verbose