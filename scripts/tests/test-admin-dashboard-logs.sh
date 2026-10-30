#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq python3

python3 scripts/tests/test-admin-dashboard-logs.py

host="$(test_default_host)"
host_literal="$(printf '%s' "$host" | jq -Rs .)"
logs_json="$(remote_eval_batch_json "logs=
  let
    cfg = builtins.getAttr $host_literal f.nixosConfigurations;
    c = cfg.config;
    vars = import ./vars.nix { inherit lib; };
    service = c.systemd.services.homepage-admin-dashboard-logs;
    timer = c.systemd.timers.homepage-admin-dashboard-logs;
    manifestPath = c.systemd.services.homepage.environment.HOMEPAGE_ADMIN_LOG_UNITS_FILE;
    manifest = builtins.fromJSON (builtins.readFile manifestPath);
  in {
    serviceUser = service.serviceConfig.User;
    serviceGroup = service.serviceConfig.Group;
    readWritePaths = service.serviceConfig.ReadWritePaths;
    runtimeDirectory = service.serviceConfig.RuntimeDirectory;
    runtimeDirectoryPreserve = service.serviceConfig.RuntimeDirectoryPreserve;
    privateNetwork = service.serviceConfig.PrivateNetwork;
    restrictAddressFamilies = service.serviceConfig.RestrictAddressFamilies;
    noNewPrivileges = service.serviceConfig.NoNewPrivileges;
    timeout = service.serviceConfig.TimeoutStartSec;
    maxMemory = service.serviceConfig.MemoryMax;
    execStart = service.serviceConfig.ExecStart;
    interval = timer.timerConfig.OnUnitActiveSec;
    timerEnabled = builtins.elem \"timers.target\" timer.wantedBy;
    statusFile = c.systemd.services.homepage.environment.HOMEPAGE_ADMIN_LOG_STATUS_FILE;
    unitIds = map (unit: unit.id) manifest.units;
    unitNames = map (unit: unit.unit) manifest.units;
    offsiteEnabled = (vars.rcloneMega.enable or false) == true;
  }")"
jq -e '
  .logs.serviceUser == "root"
  and .logs.serviceGroup == "homepage"
  and .logs.runtimeDirectory == "homepage-admin-dashboard-logs"
  and .logs.runtimeDirectoryPreserve == "yes"
  and .logs.privateNetwork == true
  and .logs.noNewPrivileges == true
  and (.logs.restrictAddressFamilies == ["AF_UNIX"])
  and .logs.timeout == "30s"
  and .logs.maxMemory == "128M"
  and .logs.interval == "5min"
  and .logs.timerEnabled == true
  and (.logs.readWritePaths | index("/run/homepage-admin-dashboard-logs") != null)
  and (.logs.execStart | contains("--output /run/homepage-admin-dashboard-logs/status.json"))
  and (.logs.execStart | contains("--manifest"))
  and (.logs.execStart | contains("--journalctl"))
  and .logs.statusFile == "/run/homepage-admin-dashboard-logs/status.json"
  and (.logs.unitIds | index("homepage") != null)
  and (.logs.unitIds | index("service-access-canary") != null)
  and (.logs.unitNames | index("homepage.service") != null)
  and (.logs.unitNames | index("homepage-canary.service") != null)
  and (if .logs.offsiteEnabled
    then ((.logs.unitIds | length) == 3 and (.logs.unitIds | index("offsite-backup") != null)
      and (.logs.unitNames | index("rclone-mega-kopia-sync.service") != null))
    else ((.logs.unitIds | length) == 2 and (.logs.unitIds | index("offsite-backup") == null)
      and (.logs.unitNames | index("rclone-mega-kopia-sync.service") == null))
    end)
' <<<"$logs_json" >/dev/null
printf 'Homepage log collector tests and effective Nix service evaluation passed.\n'
