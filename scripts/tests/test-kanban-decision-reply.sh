#!/usr/bin/env bash
# Test kanban-decision-reply.py: D-label extraction (plain and quoted), resolve,
# refusal for technical labels, and affirmative detection.
set -euo pipefail
cd "$(dirname "$0")/../.."
REPO="$PWD"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

helper="$TMP/owner-alerts.py"
cat >"$helper" <<'PY'
import json, sys
label = sys.argv[sys.argv.index('--resolve') + 1]
data = {
    'D49': {'label': 'D49', 'board': 'pcops', 'task_id': 't_a89e580a',
            'kind': 'decision', 'can_reply': True},
    'D50': {'label': 'D50', 'board': 'pcops', 'task_id': 't_ba29dd71',
            'kind': 'decision', 'can_reply': True},
    'B1': {'label': 'B1', 'board': 'pcops', 'task_id': 't_deadbeef',
           'kind': 'technical', 'can_reply': True},
}
print(json.dumps(data.get(label, {'label': label, 'kind': 'decision', 'can_reply': False})))
PY

export HERMES_OWNER_ALERTS_HELPER="$helper"
script="$REPO/scripts/hermes/kanban-decision-reply.py"

run_json() { python3 "$script" --text "$1" --json; }

# 1. Plain label + bare choice
out="$(run_json 'D49 A')"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d['label'] == 'D49', d
assert d['affirmative'] is True, d
assert d['reply'] == 'A', d
assert d['dry_run'] is True, d
PY

# 2. Quoted reply carries the label
out="$(run_json $'[Replying to: D50 · pcops\nQualify the staging receipts] reconstruct')"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d['label'] == 'D50', d
assert d['affirmative'] is True, d
assert d['reply'] == 'reconstruct', d
PY

# 3. Negation is not affirmative
out="$(run_json 'D49 do not proceed yet')"
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d['affirmative'] is False, d
PY

# 4. Technical (B) label is refused
set +e
out="$(run_json 'B1 recover it')"
rc=$?
set -e
[ "$rc" -eq 1 ] || { echo "expected exit 1 for B label, got $rc"; exit 1; }
python3 - "$out" <<'PY'
import json, sys
d = json.loads(sys.argv[1])
assert d['kind'] == 'technical', d
assert 'error' in d, d
PY

# 5. No label at all is refused
set +e
python3 "$script" --text 'just a thought' >/dev/null 2>&1
rc=$?
set -e
[ "$rc" -eq 2 ] || { echo "expected exit 2 for missing label, got $rc"; exit 1; }

echo "kanban decision reply: all checks passed"
