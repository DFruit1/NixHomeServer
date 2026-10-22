#!/usr/bin/env bash
# Regression test for modules/Core_Modules/temp-cleanup/default.nix.
#
# The daily unit deletes files on the server, so this pins the effective
# configuration: it runs as the local admin, applies the conservative script
# with scratch enabled, and fires once a day in a persistent window.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix

host_name="$(
  nix eval --json '.#nixosConfigurations' --apply builtins.attrNames \
    | jq -er '[.[] | select(endswith("-bootstrap") | not)] | first'
)"

json="$(NIXHOMESERVER_TEST_HOST="$host_name" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr hostName f.nixosConfigurations).config;
in {
  user = cfg.systemd.services.nixhomeserver-temp-cleanup.serviceConfig.User;
  execStart = cfg.systemd.services.nixhomeserver-temp-cleanup.serviceConfig.ExecStart;
  privateTmp = cfg.systemd.services.nixhomeserver-temp-cleanup.serviceConfig.PrivateTmp or null;
  timer = cfg.systemd.timers.nixhomeserver-temp-cleanup.timerConfig;
  wantedBy = cfg.systemd.timers.nixhomeserver-temp-cleanup.wantedBy;
  oom = cfg.systemd.services.nixhomeserver-temp-cleanup.serviceConfig.MemoryMax;
}')"

echo "▶ temp cleanup module contract"

local_admin="$(
  nix eval --json '.#lib.nixhomeserverSerializableSettings' \
    | jq -r --arg host "$host_name" '.[$host].localAdminUser'
)"

jq -e --arg user "$local_admin" '
  .user == $user
  and (.execStart | test("--apply --include-scratch$"))
  and .privateTmp == false
  and .timer.OnCalendar == "*-*-* 03:40:00"
  and .timer.Persistent == true
  and (.wantedBy | index("timers.target"))
  and .oom == "512M"
' <<<"$json" >/dev/null || {
  echo "❌ temp cleanup unit is not configured as a daily, user-owned, conservative apply." >&2
  jq . <<<"$json" >&2
  exit 1
}

echo "  ✅ daily timer runs the conservative cleanup as the owning user"
echo "✅ temp cleanup module contract passed"
