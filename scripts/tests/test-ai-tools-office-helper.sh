#!/usr/bin/env bash
# The ai-tools native-office helper's own unit tests.
#
# The helper is the only Python in this closure, and nothing else in the lean
# tier executes it: cargo cannot reach Python, and the Rust tests only cover the
# path validation either side of it. This is where the properties the tool
# surface promises are actually proven — every sheet is retained (which
# Collabora's convert-to cannot do), document order survives, and a failure is a
# JSON error rather than a traceback.
#
# The interpreter comes from the same nixpkgs the closure pins, so a test pass
# here is a pass against the versions that will actually run.

set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools nix

helper="$TESTS_REPO_ROOT/custom_apps/rust/apps/ai-tools/helper"
if [[ ! -d "$helper" ]]; then
  echo "office helper directory is missing; nothing to test" >&2
  exit 1
fi

# Keep the derivation path so an empty CI store can build this interpreter.
# Evaluating only its output path loses the build recipe when no cache has it.
interpreter_drv="$(
  flake_eval "
    interpreter =
      f.inputs.nixpkgs.legacyPackages.\"\${builtins.currentSystem}\".python3
        .withPackages (ps: [ ps.openpyxl ps.python-docx ]);
  in interpreter.drvPath
  "
)"

if [[ "$interpreter_drv" != /*.drv ]]; then
  echo "could not resolve the pinned office-helper interpreter" >&2
  exit 1
fi

interpreter="$(nix build --no-link --print-out-paths "$interpreter_drv^out")"
if [[ "$interpreter" != /* || "$interpreter" == *$'\n'* || ! -x "$interpreter/bin/python3" ]]; then
  echo "could not build the pinned office-helper interpreter" >&2
  exit 1
fi

bash "$helper/run-helper-tests.sh" "$interpreter/bin/python3"
