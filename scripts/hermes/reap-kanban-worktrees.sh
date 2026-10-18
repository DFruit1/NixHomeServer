#!/usr/bin/env bash
# Worktree reclamation is paused pending ownership and retained-use clearance.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/hermes/reap-kanban-worktrees.sh [--apply] [--bytes] [--board <slug>]

Worktree reaping is paused while ownership and retained-use clearance are not
established. Operational invocations are refused; this command performs no
inventory, accounting, or removal.

  --apply          Previously selected removal mode (currently refused).
  --dry-run        Previously selected classification mode (currently refused).
  --bytes          Previously selected accounting mode (currently refused).
  --board <slug>   Previously selected board (currently refused).
  -h, --help       Show this help.
EOF
}

while (($# > 0)); do
  case "$1" in
    --apply|--dry-run|--bytes) shift ;;
    --board)
      [[ $# -ge 2 ]] || { echo "❌ --board needs a value" >&2; exit 2; }
      shift 2
      ;;
    -h|--help) usage; exit 0 ;;
    *) echo "❌ Unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
done

echo 'Worktree reaping paused: ownership and retained-use clearance are not established.' >&2
exit 2
