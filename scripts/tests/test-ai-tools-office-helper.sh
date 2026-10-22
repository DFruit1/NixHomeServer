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

# Evaluated, not built: the helper tests need the libraries on an interpreter's
# path, and the built package is a closure with its own wrapper rather than a
# runnable interpreter. remote eval runs this against the host, where the build
# inputs are already present.
interpreter="$(
  flake_eval "
    interpreter =
      f.inputs.nixpkgs.legacyPackages.\"\${builtins.currentSystem}\".python3
        .withPackages (ps: [ ps.openpyxl ps.python-docx ]);
  in interpreter
  "
)"

if [[ -z "$interpreter" || "$interpreter" != /* ]]; then
  echo "could not resolve the pinned office-helper interpreter" >&2
  exit 1
fi

# The interpreter is a store path that evaluation names but nothing on this
# host has realised yet; nix build does, and is cheap once cached.
nix build --no-link "$interpreter" >/dev/null

bash "$helper/run-helper-tests.sh" "$interpreter/bin/python3"