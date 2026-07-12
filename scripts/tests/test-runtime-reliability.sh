#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

runtime_json="$(nix eval --impure --json --expr '
let
  f = builtins.getFlake (toString ./.);
  cfg = f.nixosConfigurations.server.config;
in {
  snapshotRoots = cfg.repo.backups.snapshotRoots;
  repositoryPath = cfg.repo.backups.repositoryPath;
  sqliteDumpCount = builtins.length cfg.repo.backups.sqliteDumps;
  zfsSnapshots = {
    inherit (cfg.services.zfs.autoSnapshot) enable frequent hourly daily weekly monthly;
  };
  auth = {
    inherit (cfg.repo.authGateway) enable mode domain;
    protectedCount = builtins.length (builtins.attrNames cfg.repo.authGateway.protectedApps);
    gatewayWantedBy = cfg.systemd.services.auth-gateway-oauth2-proxy.wantedBy;
    kiwixSidecarWantedBy = cfg.systemd.services.kiwix-oauth2-proxy.wantedBy;
    gatewayExecStart = toString cfg.systemd.services.auth-gateway-oauth2-proxy.serviceConfig.ExecStart;
    kiwixCaddyConfig = cfg.services.caddy.virtualHosts."wiki.sydneybasiniot.org".extraConfig;
  };
  nixInlineOptimise = cfg.nix.settings.auto-optimise-store;
  nixGcAutomatic = cfg.nix.gc.automatic;
  smartdPath = map toString cfg.systemd.services.smartd.path;
  paperlessExporter = cfg.systemd.services.paperless-exporter.unitConfig;
  allCaddyVhostLogsDisabled = f.inputs.nixpkgs.lib.all
    (vhost: vhost.logFormat == null)
    (builtins.attrValues cfg.services.caddy.virtualHosts);
  rcloneStopsKopia = builtins.match
    ".*systemctl stop kopia[.]service.*"
    (toString cfg.systemd.services.rclone-mega-kopia-sync.serviceConfig.ExecStartPre) != null;
}')"

jq -e '
  (.snapshotRoots == ["/persist", "/mnt/data/paperless"])
  and (.repositoryPath as $repo | .snapshotRoots | all(. as $root | ($repo != $root and ($repo | startswith($root + "/") | not))))
  and (.sqliteDumpCount >= 13)
  and (.zfsSnapshots == {enable:true,frequent:0,hourly:24,daily:7,weekly:4,monthly:0})
  and (.auth.enable == true)
  and (.auth.mode == "gateway")
  and (.auth.protectedCount >= 12)
  and (.auth.gatewayWantedBy | index("multi-user.target") != null)
  and (.auth.kiwixSidecarWantedBy == [])
  and (.auth.gatewayExecStart | contains("--upstream=static://202"))
  and (.auth.kiwixCaddyConfig | contains("forward_auth http://127.0.0.1:4180"))
  and (.nixInlineOptimise == false)
  and (.nixGcAutomatic == false)
  and (.smartdPath | all(contains("-nix-") | not))
  and (.paperlessExporter | has("OnSuccess") | not)
  and (.paperlessExporter | has("OnFailure") | not)
  and (.allCaddyVhostLogsDisabled == true)
  and (.rcloneStopsKopia == true)
' <<<"$runtime_json" >/dev/null || {
  echo "❌ Runtime reliability configuration regressed."
  jq . <<<"$runtime_json"
  exit 1
}

require_fixed modules/kavita/services.nix '200|401|403) ready=1; break' \
  "Kavita readiness must accept authenticated HTTP responses without retrying for 60 seconds."
require_fixed modules/Core_Modules/data-disks/default.nix '--config-json-file ${discoveryConfig}' \
  "smartd discovery must use evaluated JSON rather than runtime Nix evaluation."
require_fixed modules/Core_Modules/backups/default.nix 'PRAGMA integrity_check;' \
  "SQLite backups must be integrity checked before publication."
require_fixed modules/Core_Modules/auth-gateway/default.nix '--client-secret-file=/run/auth-gateway/client-secret' \
  "The shared auth gateway must use the newline-normalized runtime client secret."
require_fixed modules/Core_Modules/rclone/service.nix '--mega-hard-delete' \
  "MEGA mirror deletions must not accumulate in the remote rubbish bin."
require_fixed modules/Core_Modules/rclone/service.nix '--delete-before' \
  "MEGA mirror deletions must free quota before new packs are uploaded."
require_fixed modules/Core_Modules/rclone/service.nix 'refusing MEGA upload' \
  "MEGA uploads must stop before consuming the reserved quota headroom."
require_fixed modules/Core_Modules/kopia/service.nix '--keep-monthly=2' \
  "Kopia retention must remain explicitly bounded for the 20 GiB offsite mirror."

echo "✅ Runtime reliability regression tests passed."
