#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg
host="$(test_default_host)"

runtime_json="$(NIXHOMESERVER_TEST_HOST="$host" nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr host f.nixosConfigurations).config;
  settings = builtins.getAttr host f.lib.nixhomeserverSettings;
  kiwixHost = "wiki.${settings.domain}";
  seerrHost = "requests.${settings.domain}";
in {
  snapshotRoots = cfg.repo.backups.snapshotRoots;
  repositoryPath = cfg.repo.backups.repositoryPath;
  expectedPaperlessRoot = "${settings.dataRoot}/paperless";
  zfsEnabled = settings.enableZfsDataPool;
  sqliteDumpOutputs = map (dump: dump.outputName) cfg.repo.backups.sqliteDumps;
  postgresqlDumpOutputs = map (dump: dump.outputName) cfg.repo.backups.postgresqlDumps;
  seerrEnabled = cfg.repo.seerr.enable;
  zfsSnapshots = {
    inherit (cfg.services.zfs.autoSnapshot) enable frequent hourly daily weekly monthly;
  };
  auth = {
    inherit (cfg.repo.authGateway) enable mode domain;
    protectedCount = builtins.length (builtins.attrNames cfg.repo.authGateway.protectedApps);
    gatewayWantedBy = cfg.systemd.services.auth-gateway-oauth2-proxy.wantedBy;
    kiwixSidecarWantedBy = cfg.systemd.services.kiwix-oauth2-proxy.wantedBy;
    gatewayExecStart = toString cfg.systemd.services.auth-gateway-oauth2-proxy.serviceConfig.ExecStart;
    kiwixCaddyConfig = cfg.services.caddy.virtualHosts.${kiwixHost}.extraConfig;
    disabledSeerrPublished = builtins.hasAttr seerrHost cfg.services.caddy.virtualHosts;
  };
  nixInlineOptimise = cfg.nix.settings.auto-optimise-store;
  nixGcAutomatic = cfg.nix.gc.automatic;
  smartdPath = map toString cfg.systemd.services.smartd.path;
  paperlessExporter = cfg.systemd.services.paperless-exporter.unitConfig;
  canary = {
    bootstrapWantedBy = cfg.systemd.services.kanidm-canary-bootstrap.wantedBy;
    bootstrapBefore = cfg.systemd.services.kanidm-canary-bootstrap.before;
    canaryAfter = cfg.systemd.services.homepage-canary.after;
    canaryRequires = cfg.systemd.services.homepage-canary.requires;
    bootstrapExecStart = toString cfg.systemd.services.kanidm-canary-bootstrap.serviceConfig.ExecStart;
    bootstrapCredentials = cfg.systemd.services.kanidm-canary-bootstrap.serviceConfig.LoadCredential;
    runnerCredentials = cfg.systemd.services.homepage-canary.serviceConfig.LoadCredential;
    totpSeedIsExternal = builtins.hasAttr "canaryUserTotpSeed" cfg.age.secrets;
    credentialStatePersisted = builtins.elem "/var/lib/homepage-canary-credentials" cfg.repo.impermanence.inventory.persistenceDirectories;
  };
  allCaddyVhostLogsDisabled = f.inputs.nixpkgs.lib.all
    (vhost: vhost.logFormat == null)
    (builtins.attrValues cfg.services.caddy.virtualHosts);
  rcloneStopsKopia = builtins.match
    ".*systemctl stop kopia[.]service.*"
    (toString cfg.systemd.services.rclone-mega-kopia-sync.serviceConfig.ExecStartPre) != null;
  offlineMedia = {
    reconcileRequires = cfg.systemd.services.offline-media-reconcile.requires;
    reconcileAfter = cfg.systemd.services.offline-media-reconcile.after;
    reconcileExecStart = toString cfg.systemd.services.offline-media-reconcile.serviceConfig.ExecStart;
    timerWantedBy = cfg.systemd.timers.offline-media-reconcile.wantedBy;
    timerInterval = cfg.systemd.timers.offline-media-reconcile.timerConfig.OnUnitActiveSec;
    natEnabled = cfg.services.syncthing.settings.options.natEnabled;
    youtubeStartLimitInterval = cfg.systemd.services.youtube-downloader.unitConfig.StartLimitIntervalSec;
  };
}')"

jq -e '
  .expectedPaperlessRoot as $paperless
  | (.snapshotRoots | index("/persist") != null)
  and (.snapshotRoots | index($paperless) != null)
  and (.snapshotRoots | length == (unique | length))
  and (.snapshotRoots | all(startswith("/")))
  and (.repositoryPath as $repo | .snapshotRoots | all(. as $root | ($repo != $root and ($repo | startswith($root + "/") | not))))
  and (.sqliteDumpOutputs | index("beszel.sqlite") != null)
  and (.postgresqlDumpOutputs | index("immich.pgdump") != null)
  and (if .seerrEnabled then
    (.sqliteDumpOutputs | index("seerr.sqlite") != null)
  else
    (.sqliteDumpOutputs | index("seerr.sqlite") == null)
  end)
  and (if .zfsEnabled then .zfsSnapshots == {enable:true,frequent:0,hourly:24,daily:7,weekly:4,monthly:0} else .zfsSnapshots.enable == false end)
  and (.auth.enable == true)
  and (.auth.mode == "gateway")
  and (.auth.protectedCount >= 11)
  and (.auth.gatewayWantedBy | index("multi-user.target") != null)
  and (.auth.kiwixSidecarWantedBy == [])
  and (.auth.gatewayExecStart | contains("--upstream=static://202"))
  and (.auth.kiwixCaddyConfig | contains("forward_auth http://127.0.0.1:4180"))
  and (.auth.disabledSeerrPublished == false)
  and (.nixInlineOptimise == false)
  and (.nixGcAutomatic == false)
  and (.smartdPath | all(contains("-nix-") | not))
  and (.paperlessExporter | has("OnSuccess") | not)
  and (.paperlessExporter | has("OnFailure") | not)
  and (.canary.bootstrapWantedBy | index("multi-user.target") != null)
  and (.canary.bootstrapBefore | index("homepage-canary.service") != null)
  and (.canary.canaryAfter | index("kanidm-canary-bootstrap.service") != null)
  and (.canary.canaryRequires | index("kanidm-canary-bootstrap.service") != null)
  and (.canary.bootstrapExecStart | contains("kanidm-canary-bootstrap"))
  and (.canary.bootstrapCredentials | index("idm-admin-password:/run/agenix/kanidmAdminPass") != null)
  and (.canary.bootstrapCredentials | index("canary-password:/run/agenix/canaryUserPassword") != null)
  and (.canary.runnerCredentials | index("kanidm-totp-seed:/var/lib/homepage-canary-credentials/kanidm-totp-seed") != null)
  and (.canary.totpSeedIsExternal == false)
  and (.canary.credentialStatePersisted == true)
  and (.allCaddyVhostLogsDisabled == true)
  and (.rcloneStopsKopia == true)
  and (.offlineMedia.reconcileRequires | index("syncthing.service") != null)
  and (.offlineMedia.reconcileAfter | index("data-pool-layout.service") != null)
  and (.offlineMedia.reconcileExecStart | contains("offline-media-reconcile"))
  and (.offlineMedia.timerWantedBy | index("timers.target") != null)
  and (.offlineMedia.timerInterval == "15min")
  and (.offlineMedia.natEnabled == false)
  and (.offlineMedia.youtubeStartLimitInterval == "5min")
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
require_fixed modules/Core_Modules/auth-gateway/default.nix 'http://:${toString cfg.internalPort}' \
  "The auth router must accept preserved application Host headers while binding only to loopback."
require_fixed modules/Core_Modules/rclone/service.nix '--mega-hard-delete' \
  "MEGA mirror deletions must not accumulate in the remote rubbish bin."
require_fixed modules/Core_Modules/rclone/service.nix '--delete-before' \
  "MEGA mirror deletions must free quota before new packs are uploaded."
require_fixed modules/Core_Modules/rclone/service.nix 'refusing MEGA upload' \
  "MEGA uploads must stop before consuming the reserved quota headroom."
require_fixed modules/Core_Modules/kopia/service.nix '--keep-monthly=2' \
  "Kopia retention must remain explicitly bounded for the 20 GiB offsite mirror."
require_fixed modules/Core_Modules/storage/fileshare-user-roots.nix '${vars.usersRoot}/%I' \
  "Per-user files paths must use systemd's unescaped instance name so hyphenated Kanidm usernames work."
require_fixed modules/Core_Modules/storage/fileshare-user-roots.nix '${sftpChrootBase}/%I' \
  "SFTP chroot paths must use systemd's unescaped instance name."
require_fixed modules/Core_Modules/storage/fileshare-user-roots.nix 'getfacl -cp "$path"' \
  "New user roots must detect and apply missing application ACL grants."
require_fixed modules/offline-music/services.nix '/rest/db/scan?folder=$folder_id' \
  "Offline media must force periodic Syncthing scans so missed filesystem events self-heal."
require_fixed modules/offline-music/services.nix '! -readable -print -quit' \
  "Offline media health checks must detect files Syncthing cannot read."
require_fixed modules/homepage/services.nix '/rest/db/completion?device=$enrolled_device_id&folder=$folder_id' \
  "The homepage must expose per-device sync backlog instead of treating enrollment as health."

echo "✅ Runtime reliability regression tests passed."
