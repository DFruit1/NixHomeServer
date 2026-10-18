#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/helpers/remote-run.sh"
fail() { echo "❌ $1" >&2; exit 1; }
spy_dir="$(mktemp -d "${TMPDIR:-/tmp}/remote-run-strict.XXXXXX")"
trap 'rm -rf "$spy_dir"' EXIT
cat >"$spy_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >>"$RUN_SPY"
exit 99
EOF
chmod +x "$spy_dir/ssh"
if PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD='' NIXHOMESERVER_EXPECTED_TREE='' \
    NIXHOMESERVER_EVIDENCE_DIR='' remote_run 'printf local' >/dev/null 2>&1; then
  fail "strict run accepted missing identity"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict preflight contacted SSH"
if PATH="$spy_dir:$PATH" RUN_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    REMOTE_RUN=0 remote_run 'printf local' >/dev/null 2>&1; then
  fail "strict run accepted local opt-out"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict opt-out contacted SSH"
out="$(PATH="$spy_dir:$PATH" REMOTE_RUN=0 remote_run 'printf "%s" "$1"')"
[[ "$out" == "$repo_root" ]] || fail "ordinary local snippet behavior changed"
echo "✅ remote-run strict preflight and ordinary opt-out tests passed"
