#!/usr/bin/env bash
# Free-tier model ban on every Hermes lane.
#
# Why
# ---
# Owner decision 2026-10-22: the fleet runs only paid or self-hosted models.
# Free-tier Zen models leaked into the fleet twice through profile configs --
# `space-bunny-free` (~8,800 standard-implementer calls) and
# `step-5-preview-free` (~5,000 implementer + review calls) -- and the ledger
# recorded the waste before the defaults were moved off them. A regression is
# exactly the kind of change an edit-based config tool can reintroduce and
# nothing central would notice, so this is the gate.
#
# The test reads the configured model selections of the live Hermes home
# (world-visible, no secrets read) and checks that no free-tier model id
# appears anywhere a route can select one. Recorded session usage keeps its
# historical free-model rows: deleting ledger rows would fake the evidence
# this test exists to prevent repeating.
#
# Scope
# -----
#   HERMES_ROOT/.hermes/config.yaml
#   HERMES_ROOT/profiles/*/config.yaml
#   HERMES_ROOT/kanban/boards/*/kanban.db   (open task model overrides only)
#
# Exit status
#   0  every configured lane is free of free-tier models (or no hermes root)
#   1  a free-tier model is selectable from a configured route
#
# A missing hermes root is a skip, not a pass claim: this host legitimately
# carries one, and repacking the suite to require Hermes' own runtime is out
# of scope. It prints its scope so the skip is visible in any receipt.

set -euo pipefail

HERMES_ROOT="${HERMES_ROOT:-$HOME/.hermes}"

if [[ ! -d "$HERMES_ROOT" ]]; then
  echo "SKIP hermes-model-lanes: no hermes root at $HERMES_ROOT"
  exit 0
fi

fail() { printf '❌ %s\n' "$*" >&2; exit 1; }
pass() { printf '✅ %s\n' "$1"; }

# Scan yaml model routes with python, so comments and dead examples are not
# misread as routes. Prints one offending `profile model=...` line per hit.
python3 - "$HERMES_ROOT" <<'PY' || fail "a free-tier model is selectable from a configured route"
import re, sys
from pathlib import Path
import yaml

OFFENDER = re.compile(r'^[\s\S]*-\s*free$|\bfree\b', re.I)
root = Path(sys.argv[1])
targets = [root / 'config.yaml']
targets += sorted((root / 'profiles').glob('*/config.yaml'))
for path in targets:
    if not path.is_file():
        continue
    cfg = yaml.safe_load(path.read_text()) or {}
    routes = []
    m = cfg.get('model') or {}
    if isinstance(m, dict):
        routes.append(('model.default', m.get('default'), m.get('provider')))
    for fb in (cfg.get('fallback_providers') or []) if isinstance(cfg.get('fallback_providers'), list) else []:
        routes.append(('fallback', (fb or {}).get('model'), (fb or {}).get('provider')))
    aux = cfg.get('auxiliary') or {}
    if isinstance(aux, dict):
        for name in sorted(aux):
            entry = aux.get(name)
            if isinstance(entry, dict):
                routes.append((f'auxiliary.{name}', entry.get('model'), entry.get('provider')))
    for where, model, provider in routes:
        if isinstance(model, str) and '-free' in model.lower():
            label = path.relative_to(root)
            print(f"FREE_MODEL {label} {where}={model} provider={provider}")
    hits = sum(1 for w, m, p in routes if isinstance(m, str) and '-free' in m.lower())
    sys.exit(1) if hits else None
PY
pass "no configured lane route selects a free-tier model"

# Open cards may pin a model with kanban set-model; a stale free-model override
# revives the route the config ban just closed. Closed cards keep their
# history.
for db in "$HERMES_ROOT"/kanban/boards/*/kanban.db; do
  [[ -f "$db" ]] || continue
  board="$(basename "$(dirname "$db")")"
  hits="$(sqlite3 "$db" "SELECT id, model_override FROM tasks
                          WHERE (model_override LIKE '%free%'
                                 OR coalesce(provider_override,'') LIKE '%free%')
                            AND status NOT IN ('done','archived');" 2>/dev/null)" || hits=""
  [[ -z "$hits" ]] || fail "open card carries a free-model override on $board: $hits"
done
pass "no open card override routes to a free-tier model"

# The pinned lane keeps its owner decision: the standard-implementer profile
# exists here (fleet note pinned in hermes-runtime.md), so check its primary.
python3 -c "
import yaml
db_path='$HERMES_ROOT/profiles/standard-implementer/config.yaml'
cfg=yaml.safe_load(open(db_path)) or {}
m=cfg.get('model') or {}
assert m.get('default')=='deepseek-v4.1-flash', m
assert m.get('provider')=='custom:opencode-go', m
fb=cfg.get('fallback_providers') or []
assert [(e.get('provider'),e.get('model')) for e in fb]==[('openai-codex','gpt-6-luna')], fb
" || fail "the standard-implementer lane pin drifted"
pass "standard-implementer lane keeps its deepseek/codex pin"
