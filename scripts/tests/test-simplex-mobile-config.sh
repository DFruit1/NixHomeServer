#!/usr/bin/env bash
# Regression test for scripts/hermes/apply-simplex-mobile-config.py.
#
# What this pins, and why it is a test rather than a config edit:
#
#   1. The SimpleX toolset is DERIVED from the owner's `cli` entry rather than
#      written as a second literal list. A duplicated list is a list that drifts,
#      and the drift is invisible until a tool is missing from a chat channel.
#
#   2. `known_plugin_toolsets.simplex` must mirror `cli`. Without it, every
#      plugin toolset that is not default-off and not on the saved list is
#      ENABLED by default -- so homeassistant arrives on the chat surface unasked,
#      which is exactly the class of "the bot has a tool it should not have".
#
#   3. The display block lands under `display.platforms:`. A helper that cannot
#      find the block writes nothing and reports drift forever; a helper that
#      finds the wrong block writes into the live config under `personality:` or
#      `telemetry:` and changes how the whole profile behaves. Both are silent.
#
#   4. It is idempotent, and it reports "already applied" rather than drift.

set -uo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HELPER="$TESTS_REPO_ROOT/scripts/hermes/apply-simplex-mobile-config.py"

pass() { echo "  ✅ $1"; }
fail() { echo "  ❌ $1" >&2; FAILURES=$((FAILURES + 1)); }
FAILURES=0

[[ -f "$HELPER" ]] || { echo "  ❌ missing helper: $HELPER" >&2; exit 1; }
command -v python3 >/dev/null || { echo "  ❌ python3 not on PATH" >&2; exit 1; }

fixture="$(mktemp -d)"
trap 'rm -rf "$fixture"' EXIT

# A realistic cut of a profile config: the `display:` block is long and every
# section after it is introduced by a column-0 `# ====` banner, which is what a
# naive block-extent scan terminates on.
cat >"$fixture/config.yaml" <<'EOF'
model: gpt-6-luna

platform_toolsets:
  cli: [clarify, delegation, file, kanban, memory, session_search, skills, terminal, todo, vision, web]
  telegram: [hermes-telegram]
  desktop:
    - web
    - file

known_plugin_toolsets:
  cli:
    - a2a
    - homeassistant
    - spotify
  desktop:
    - homeassistant

display:
  compact: false

  # Tool progress display level
  tool_progress: all

# =============================================================================
# Model Aliases
# =============================================================================
# model_aliases:
#   opus:
#     model: claude-opus-4

telemetry:
  shared_metrics:
    enabled: false
EOF

echo "▶ simplex mobile chat surface"

# --- the toolset is derived, not duplicated ---------------------------------
apply_out="$(python3 "$HELPER" "$fixture/config.yaml")" || fail "apply failed: $apply_out"
grep -q 'platform_toolsets.simplex = \[clarify, delegation, file, kanban, memory, session_search, skills, terminal, todo, vision, web\]' <<<"$apply_out" ||
  fail "the SimpleX toolset was not derived from the cli list: $apply_out"
pass "derives platform_toolsets.simplex from the profile's cli list"

# --- known_plugin_toolsets mirrors cli, not an invented list ----------------
grep -q 'known_plugin_toolsets.simplex = a2a, homeassistant, spotify' <<<"$apply_out" ||
  fail "known_plugin_toolsets.simplex was not mirrored from cli: $apply_out"
pass "mirrors known_plugin_toolsets.simplex from cli"

# Exactly one simplex block at this indent: a duplicate means the writer found
# nothing and appended a second copy, which the reader would then treat as a
# two-entry toolset.
[[ "$(grep -c '^  simplex:$' "$fixture/config.yaml")" == 1 ]] ||
  fail "the known_plugin_toolsets simplex block is missing or duplicated: $(grep -n 'simplex' "$fixture/config.yaml")"
pass "writes exactly one known_plugin_toolsets.simplex block"

# --- the display block lands in the right place -----------------------------
# `platforms:` must be indented under display:, and must NOT be under telemetry
# or at top level. Both would parse silently and change unrelated behaviour.
grep -q '^  platforms:$' "$fixture/config.yaml" ||
  fail "display.platforms: is not a two-space child of display:: $(grep -n 'platforms:' "$fixture/config.yaml")"

python3 - "$fixture/config.yaml" <<'PY' || fail "display.platforms.simplex did not land under display:"
import re, sys
lines = open(sys.argv[1]).read().split("\n")
display_start = next(i for i, l in enumerate(lines) if l == "display:")
platforms = next((i for i in range(display_start + 1, len(lines)) if lines[i] == "  platforms:"), None)
if platforms is None:
    raise SystemExit("no display.platforms:")
# Nothing at column 0 may appear between `display:` and its `platforms:` child,
# or `platforms:` belongs to some other section. Keys BEFORE `display:` are
# expected and irrelevant, so only the slice is checked.
between = [l for l in lines[display_start + 1:platforms] if re.match(r"^[A-Za-z_]+:", l)]
assert between == [], between
PY
pass "places display.platforms.simplex under display:"

# --- idempotent, and honest about already being applied ---------------------
second_out="$(python3 "$HELPER" "$fixture/config.yaml")" || fail "second apply failed: $second_out"
[[ "$second_out" == ok:* ]] ||
  fail "the second run reported drift instead of ok: $second_out"
pass "a second run reports ok rather than drift"

check_out="$(python3 "$HELPER" --check "$fixture/config.yaml")" || fail "--check failed: $check_out"
[[ "$check_out" == ok:* ]] ||
  fail "--check reported drift on an already-applied file: $check_out"
pass "--check on an applied file reports ok"

# --- a changed cli list moves the SimpleX list with it ---------------------
sed -i 's/^  cli: \[.*\]$/  cli: [clarify, delegation, file, kanban, memory, session_search, skills, terminal, todo]/' "$fixture/config.yaml"
drift_out="$(python3 "$HELPER" "$fixture/config.yaml")" || fail "apply after a cli change failed: $drift_out"
grep -q 'platform_toolsets.simplex:' <<<"$drift_out" ||
  fail "a changed cli toolset did not move the SimpleX toolset with it: $drift_out"
grep -qx '  simplex: \[clarify, delegation, file, kanban, memory, session_search, skills, terminal, todo\]' "$fixture/config.yaml" ||
  fail "platform_toolsets.simplex does not match the new cli list: $(grep -n 'simplex:' "$fixture/config.yaml")"
pass "follows the cli list when it changes"

# --- a display value that drifted is corrected, not appended to ------------
sed -i 's/^      tool_progress: off$/      tool_progress: all/' "$fixture/config.yaml"
drift2="$(python3 "$HELPER" "$fixture/config.yaml")" || fail "apply after a display drift failed: $drift2"
grep -q 'display.platforms.simplex enforced' <<<"$drift2" ||
  fail "a drifted display value was not corrected: $drift2"
[[ "$(grep -c '^      tool_progress:' "$fixture/config.yaml")" == 1 ]] ||
  fail "the corrected tool_progress was appended instead of replaced: $(grep -c 'tool_progress' "$fixture/config.yaml")"
grep -qx '      tool_progress: off' "$fixture/config.yaml" ||
  fail "tool_progress was not returned to off"
pass "corrects a drifted display value in place"

# --- a config with no display: block fails loudly, not silently -------------
grep -v '^display:$' "$fixture/config.yaml" >"$fixture/nodisplay.yaml"
sed -i '/^  platforms:$/,$d' "$fixture/nodisplay.yaml"
no_display_rc=0
no_display="$(python3 "$HELPER" "$fixture/nodisplay.yaml" 2>&1)" || no_display_rc=$?
[[ "$no_display_rc" != 0 ]] ||
  fail "a config without a display: block was accepted silently"
grep -qi "no top-level \`display:\` block" <<<"$no_display" ||
  fail "the missing-display failure did not name the cause: $no_display"
pass "fails loudly on a config with no display: block"

# --- a config with no cli list cannot invent a toolset ---------------------
sed -i 's/^  cli: \[.*\]$//' "$fixture/nodisplay.yaml"
printf 'display:\n  compact: false\n' >>"$fixture/nodisplay.yaml"
no_cli_rc=0
no_cli="$(python3 "$HELPER" "$fixture/nodisplay.yaml" 2>&1)" || no_cli_rc=$?
[[ "$no_cli_rc" != 0 ]] ||
  fail "a profile with no cli list was given a toolset invented from nothing"
grep -qi "cannot derive" <<<"$no_cli" ||
  fail "the no-cli failure did not name the cause: $no_cli"
pass "refuses to invent a toolset when the profile has no cli list"

if ((FAILURES > 0)); then
  echo "▶ simplex mobile chat surface: $FAILURES check(s) failed"
  exit 1
fi
echo "▶ simplex mobile chat surface: all checks passed"
