#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix

host="$(test_default_host)"
services_json="$(
  nix eval --json ".#nixosConfigurations.${host}.config.systemd.services" \
    --apply 'services:
      builtins.mapAttrs
        (_: service: service.serviceConfig)
        (builtins.intersectAttrs {
          bonsai-llama = null;
          bonsai-model-prepare = null;
          groundwater-logger = null;
          homepage = null;
          kanidm-canary-bootstrap = null;
          mail-archive-paperless-tasks = null;
          mail-archive-ui = null;
          mail-archive-ui-paperless-db-snapshot = null;
          youtube-downloader = null;
        } services)'
)"

require_service_setting() {
  local service="$1"
  local jq_expression="$2"
  local description="$3"

  if ! jq -e --arg service "$service" ".[\$service] | ${jq_expression}" \
    >/dev/null <<<"$services_json"; then
    echo "❌ ${service}: ${description}" >&2
    jq --arg service "$service" '.[ $service ]' <<<"$services_json" >&2
    exit 1
  fi
}

for service in \
  bonsai-llama \
  bonsai-model-prepare \
  groundwater-logger \
  kanidm-canary-bootstrap \
  mail-archive-paperless-tasks \
  mail-archive-ui \
  mail-archive-ui-paperless-db-snapshot \
  youtube-downloader; do
  require_service_setting "$service" '.NoNewPrivileges == true' \
    "must prevent privilege acquisition"
  require_service_setting "$service" '.PrivateTmp == true' \
    "must use a private temporary directory"
  require_service_setting "$service" '.ProtectSystem == "strict"' \
    "must make the system filesystem read-only by default"
  require_service_setting "$service" '.ProtectHome == true' \
    "must hide home directories"
done

for service in bonsai-llama groundwater-logger mail-archive-ui youtube-downloader; do
  require_service_setting "$service" '.ProtectKernelModules == true' \
    "long-running custom apps must not access kernel modules"
  require_service_setting "$service" '.ProtectKernelTunables == true' \
    "long-running custom apps must not change kernel tunables"
  require_service_setting "$service" '.RestrictSUIDSGID == true' \
    "long-running custom apps must not create setuid/setgid files"
  require_service_setting "$service" '(.RestrictAddressFamilies | sort) == (["AF_INET", "AF_INET6", "AF_UNIX"] | sort)' \
    "must have an explicit socket-family allowlist"
done

# Homepage has narrowly-scoped sudo helpers, so NoNewPrivileges and
# RestrictSUIDSGID would break deliberate privilege transitions. Assert the
# surrounding sandbox explicitly so that exception cannot grow unnoticed.
for setting in \
  ProtectClock \
  ProtectControlGroups \
  ProtectHostname \
  ProtectKernelLogs \
  ProtectKernelModules \
  ProtectKernelTunables \
  LockPersonality; do
  require_service_setting homepage ".${setting} == true" \
    "the sudo-helper exception still requires ${setting}"
done
require_service_setting homepage '(.RestrictAddressFamilies | sort) == (["AF_INET", "AF_INET6", "AF_UNIX"] | sort)' \
  "must have an explicit socket-family allowlist"
require_service_setting homepage '.SystemCallArchitectures == "native"' \
  "must limit system calls to the native architecture"

echo "✅ Evaluated custom-service hardening checks passed."
