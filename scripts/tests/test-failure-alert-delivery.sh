#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools jq nix rg
host="$(test_default_host)"

alert_json="$(
  NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
    host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    cfg = (builtins.getAttr host f.nixosConfigurations).config;
    monitored = [
      "backup-prepare"
      "homepage-canary"
      "kopia-persist-snapshot"
      "kopia-snapshot-health"
      "nixhomeserver-nix-gc"
      "rclone-mega-capacity-check"
      "rclone-mega-kopia-sync"
      "storage-smart-long"
      "storage-smart-short"
      "zfs-snapshot-health"
    ];
  in {
    inherit (cfg.repo.monitoring.failureAlerts) enable format targetUnit webhookUrlFile;
    handler = cfg.systemd.services."nixhomeserver-failure-alert@".serviceConfig;
    targets = builtins.listToAttrs (map
      (name: {
        inherit name;
        value = {
          onFailure = cfg.systemd.services.${name}.unitConfig.OnFailure;
          mode = cfg.systemd.services.${name}.unitConfig.OnFailureJobMode;
        };
      }) monitored);
  }
')"

jq -e '
  .enable == true
  and .format == "json"
  and .webhookUrlFile == null
  and .targetUnit == "nixhomeserver-failure-alert@%n.service"
  and (.handler.Type == "oneshot")
  and (.handler.DynamicUser == true)
  and (.handler.NoNewPrivileges == true)
  and (.handler.ProtectSystem == "strict")
  and (.handler.ProtectHome == true)
  and (.handler.RestrictSUIDSGID == true)
  and ([.targets[] | .onFailure == ["nixhomeserver-failure-alert@%n.service"]] | all)
  and ([.targets[] | .mode == "replace-irreversibly"] | all)
' <<<"$alert_json" >/dev/null || {
  echo "❌ Evaluated failure-alert delivery configuration regressed." >&2
  jq . <<<"$alert_json" >&2
  exit 1
}

require_fixed modules/Core_Modules/monitoring/alerts.nix '--retry-all-errors' \
  "failure alerts must retry transient webhook failures"
require_fixed modules/Core_Modules/monitoring/alerts.nix 'daemon.alert' \
  "failure alerts must always leave a high-priority local journal record"
require_fixed modules/Core_Modules/monitoring/alerts.nix 'https://*)' \
  "failure-alert delivery must reject plaintext HTTP endpoints"
require_fixed secrets/manifest.nix 'failureAlertWebhookUrl' \
  "failure-alert webhook configuration must use the encrypted secret workflow"
require_fixed scripts/helpers/secrets-common.sh 'validate_https_url' \
  "failure-alert URLs must be validated before encryption"

echo "✅ Actionable failure-alert delivery checks passed."
