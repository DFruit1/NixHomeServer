#!/usr/bin/env bash
set -euo pipefail
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$repo_root/scripts/helpers/remote-build.sh"
fail() { echo "❌ $1" >&2; exit 1; }
spy_dir="$(mktemp -d "${TMPDIR:-/tmp}/remote-build-strict.XXXXXX")"
trap 'rm -rf "$spy_dir"' EXIT
cat >"$spy_dir/nix" <<'EOF'
#!/usr/bin/env bash
printf 'nix %s\n' "$*" >>"$BUILD_SPY"
printf '[]\n'
EOF
cat >"$spy_dir/ssh" <<'EOF'
#!/usr/bin/env bash
printf 'ssh\n' >>"$BUILD_SPY"
exit 99
EOF
chmod +x "$spy_dir/nix" "$spy_dir/ssh"
if PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    NIXHOMESERVER_EXPECTED_HEAD='' NIXHOMESERVER_EXPECTED_TREE='' \
    NIXHOMESERVER_EVIDENCE_DIR='' remote_build_flake .#checks.demo >/dev/null 2>&1; then
  fail "strict build accepted missing identity"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict preflight invoked local or remote work"
if PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" NIXHOMESERVER_REQUIRE_REMOTE=1 \
    REMOTE_BUILD=0 remote_build_flake .#checks.demo >/dev/null 2>&1; then
  fail "strict build accepted local opt-out"
fi
[[ ! -s "$spy_dir/calls" ]] || fail "strict opt-out invoked local or remote work"
out="$(PATH="$spy_dir:$PATH" BUILD_SPY="$spy_dir/calls" REMOTE_BUILD=0 remote_build_flake .#checks.demo)"
[[ "$out" == '[]' ]] || fail "ordinary local build behavior changed"
grep -q '^nix build' "$spy_dir/calls" || fail "ordinary opt-out did not run nix build"
echo "✅ remote-build strict preflight and ordinary opt-out tests passed"
