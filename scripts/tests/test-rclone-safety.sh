#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

validation_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  validation = import ./lib/rclone-validation.nix { lib = f.inputs.nixpkgs.lib; };
in {
  acceptsRemoteName = validation.validRemoteName "mega_backup-1";
  rejectsRemoteColon = !(validation.validRemoteName "mega:");
  rejectsRemoteSlash = !(validation.validRemoteName "mega/backup");
  rejectsNonStringRemote = !(validation.validRemoteName {});
  acceptsOwnedSubdirectory = validation.validDestination "mega" "mega:NixHomeServer/kopia";
  rejectsRemoteRoot = !(validation.validDestination "mega" "mega:");
  rejectsAbsoluteRemoteRoot = !(validation.validDestination "mega" "mega:/");
  rejectsWrongRemote = !(validation.validDestination "mega" "other:NixHomeServer/kopia");
  rejectsParentTraversal = !(validation.validDestination "mega" "mega:NixHomeServer/../kopia");
  rejectsCurrentDirectory = !(validation.validDestination "mega" "mega:NixHomeServer/./kopia");
  rejectsNonStringDestination = !(validation.validDestination "mega" []);
  rejectsNonStringRemoteInDestination = !(validation.validDestination {} "mega:NixHomeServer/kopia");
}
')"

jq -e '[to_entries[] | select(.value != true)] | length == 0' \
  <<<"$validation_json" >/dev/null || {
  echo "Rclone destination validation accepted an unsafe target or rejected a safe one." >&2
  jq . <<<"$validation_json"
  exit 1
}

malformed_log="$(mktemp)"
trap 'rm -f "$malformed_log"' EXIT
malformed_expr='
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  lib = f.inputs.nixpkgs.lib;
  base = import ./vars.nix { inherit lib; };
  vars = base // {
    rcloneMega = base.rcloneMega // {
      enable = true;
      email = "operator@example.invalid\nbackend = local";
      remoteName = {};
      destination = [];
      transfers = "4";
      checkers = [8];
      warnPercent = "80";
      criticalPercent = {};
      repositoryLimitBytes = "19327352832";
    };
  };
  pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
  packages = import ./flake/packages.nix {
    inherit lib pkgs;
    crane = f.inputs.crane;
  };
  system = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs;
    system = base.hostPlatform;
    appPackages = packages.appPackages;
  };
in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'
if nix eval --impure --raw --expr "$malformed_expr" >"$malformed_log" 2>&1; then
  echo "Rclone configuration accepted malformed scalar settings." >&2
  exit 1
fi
for expected_message in \
  'vars.rcloneMega.email must be a single-line email address' \
  'vars.rcloneMega.remoteName must be a simple Rclone remote name' \
  'vars.rcloneMega.destination must be a non-root path' \
  'vars.rcloneMega transfers/checkers must be positive' \
  'vars.rcloneMega quota thresholds and repositoryLimitBytes must be positive'; do
  if ! rg -Fq "$expected_message" "$malformed_log"; then
    echo "Malformed Rclone setting failed without the actionable assertion: $expected_message" >&2
    cat "$malformed_log" >&2
    exit 1
  fi
done

runtime_json="$(nix eval --json '.#nixosConfigurations.server.config.systemd.services.rclone-mega-kopia-sync' \
  --apply 'service: {
    script = service.script;
    type = service.serviceConfig.Type;
    restart = service.serviceConfig.Restart;
    restartSec = service.serviceConfig.RestartSec;
    restartMode = service.serviceConfig.RestartMode;
    successExitStatus = service.serviceConfig.SuccessExitStatus;
    restartPreventExitStatus = service.serviceConfig.RestartPreventExitStatus;
    startLimit = service.unitConfig.StartLimitIntervalSec;
  }')"

jq -e '
  .type == "exec"
  and .restart == "on-failure"
  and .restartSec == "30min"
  and .restartMode == "direct"
  and (.successExitStatus | index(76) != null)
  and (.restartPreventExitStatus | sort == [64,76,77,78])
  and .startLimit == "6h"
  and (.script | contains("Kopia ownership marker is missing"))
  and (.script | contains("check-freshness-marker"))
  and (.script | contains("invalid, stale, or future-dated"))
  and (.script | contains("rclone-mega-preflight"))
  and (.script | contains("--source /mnt/data/backups/kopia"))
  and (.script | contains("--control-reserve-bytes 1048576"))
  and (.script | contains("--result-file"))
  and (.script | contains("rclone-mega-status-event"))
  and (.script | contains("last-mega-sync-status.json"))
  and (.script | contains("--identifier=backup-offsite"))
  and (.script | contains("run_rclone_phase"))
  and (.script | contains("3|4|5"))
  and (.script | contains("data_root_unmounted"))
  and (.script | contains("preflight_helper_failed"))
  and (.script | contains("exit 64"))
  and (.script | contains("--always-transfer-from"))
  and (.script | contains("--check-first"))
  and (.script | contains("copy") and contains("--ignore-times"))
  and (.script | contains("check") and contains("--download"))
  and (.script | contains("rclone-owner.json"))
  and (.script | contains("--exclude /.nixhomeserver-rclone-owner.json"))
' <<<"$runtime_json" >/dev/null || {
  echo "Rclone destructive-sync safety configuration regressed." >&2
  jq . <<<"$runtime_json"
  exit 1
}

capacity_json="$(nix eval --json '.#nixosConfigurations.server.config.systemd.services.rclone-mega-capacity-check' \
  --apply 'service: {
    execStart = service.serviceConfig.ExecStart;
    onFailure = service.unitConfig.OnFailure;
  }')"

jq -e '
  (.execStart | contains("rclone-mega-capacity-check"))
  and (.onFailure | length > 0)
' <<<"$capacity_json" >/dev/null || {
  echo "Rclone capacity warning and alert configuration regressed." >&2
  jq . <<<"$capacity_json"
  exit 1
}

app_state_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  baseVars = import ./vars.nix { lib = f.inputs.nixpkgs.lib; };
  enabledApps = import ./flake/apps.nix { inherit pkgs; vars = baseVars; };
  disabledApps = import ./flake/apps.nix {
    inherit pkgs;
    vars = baseVars // { rcloneMega = baseVars.rcloneMega // { enable = false; }; };
  };
in {
  enabled = builtins.hasAttr "backup-mega-sync-now" enabledApps;
  disabled = !(builtins.hasAttr "backup-mega-sync-now" disabledApps);
  disabledStillHasSnapshot = builtins.hasAttr "backup-snapshot-now" disabledApps;
}
')"

jq -e '.enabled and .disabled and .disabledStillHasSnapshot' \
  <<<"$app_state_json" >/dev/null || {
  echo "MEGA maintenance app availability does not follow rcloneMega.enable." >&2
  jq . <<<"$app_state_json"
  exit 1
}

echo "✅ Rclone destructive-sync safety regression tests passed."
