#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

surface_json="$(nix eval --json '.#nixosConfigurations.server.config' --apply 'cfg: {
  app = cfg.repo.mediaManager;
  gateway = cfg.repo.authGateway.protectedApps.mediaManager;
  privateDns = cfg.services.unbound.privateHosts.${cfg.repo.mediaManager.domain};
  group = cfg.services.kanidm.provision.groups."media-manager-editors";
  scopes = cfg.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps."media-manager-editors";
  persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
  backupApps = map (entry: entry.app) cfg.repo.backups.appStateEntries;
  sqliteSources = map (dump: dump.source) cfg.repo.backups.sqliteDumps;
  service = cfg.systemd.services.media-manager.serviceConfig;
  serviceEnvironment = cfg.systemd.services.media-manager.environment;
  brokerUserGroup = cfg.users.users.media-manager-broker.group;
  brokerUserExtraGroups = cfg.users.users.media-manager-broker.extraGroups;
  stateTmpfiles = cfg.systemd.tmpfiles.rules;
  ageSecretNames = builtins.attrNames cfg.age.secrets;
  broker = cfg.systemd.services.media-manager-broker.serviceConfig;
  brokerTimer = cfg.systemd.timers.media-manager-broker.timerConfig;
  integrations = cfg.repo.mediaManager.integrations;
  refreshPath = cfg.systemd.paths.media-manager-refresh-requests.pathConfig;
  refreshDispatcher = cfg.systemd.services.media-manager-refresh-dispatch.serviceConfig;
  jellyfinRefresh = cfg.systemd.services.media-manager-refresh-jellyfin.serviceConfig;
  audiobookshelfRefresh = cfg.systemd.services.media-manager-refresh-audiobookshelf.serviceConfig;
  syncthingRefresh = cfg.systemd.services.media-manager-refresh-syncthing.serviceConfig;
  storageAccessScript = cfg.systemd.services.media-manager-storage-access.script;
  wantedBy = cfg.systemd.services.media-manager.wantedBy;
}')"

jq -e '
  (.app.enable == true)
  and (.app.domain == "media.sydneybasiniot.org")
  and (.app.stateDir == "/var/lib/media-manager")
  and (.app.mutationMode == "enabled")
  and (.app.editorGroup == "media-manager-editors")
  and (.app.roots | map(.id) == [
    "shared-videos",
    "shared-music",
    "shared-audiobooks",
    "shared-books",
    "shared-dvd-inbox",
    "personal-videos",
    "personal-music",
    "personal-audiobooks",
    "personal-books"
  ])
  and (.gateway.host == .app.domain)
  and (.gateway.upstream == "http://127.0.0.1:8087")
  and (.gateway.allowedGroups == ["users"])
  and (.privateDns.target == "private")
  and (.group.overwriteMembers == false)
  and (.group.members | length == 1)
  and (.scopes | index("groups_name") != null)
  and (.persistence | index("/var/lib/media-manager") != null)
  and (.backupApps | index("media-manager") != null)
  and (.sqliteSources | index("/var/lib/media-manager/control.sqlite3") != null)
  and (.wantedBy | index("multi-user.target") != null)
  and (.service.User == "media-manager")
  and (.service.Group == "media-manager")
  and (.service.DynamicUser == false)
  and (.service.NoNewPrivileges == true)
  and (.service.ProtectSystem == "strict")
  and (.service.PrivateTmp == true)
  and (.service.ReadWritePaths == ["/var/lib/media-manager"])
  and (.serviceEnvironment.MEDIA_MANAGER_OPENSUBTITLES_CREDENTIALS_FILE == null)
  and (.ageSecretNames | index("openSubtitlesCredentials") == null)
  and (.brokerUserGroup == "media-manager")
  and (.brokerUserExtraGroups == ["media-manager-broker"])
  and (.broker.User == "media-manager-broker")
  and (.broker.Group == "media-manager")
  and (.broker.SupplementaryGroups == ["media-manager-broker"])
  and (.broker.PrivateNetwork == true)
  and (.broker.NoNewPrivileges == true)
  and (.broker.CapabilityBoundingSet == [])
  and (.broker.AmbientCapabilities == [])
  and (.broker.ReadWritePaths == [
    "/var/lib/media-manager",
    "/mnt/data/shared",
    "/mnt/data/users"
  ])
  and (.stateTmpfiles | index("d /var/lib/media-manager 0770 media-manager media-manager -") != null)
  and (.stateTmpfiles | index("d /var/lib/media-manager/refresh-requests 0750 media-manager media-manager -") != null)
  and (.stateTmpfiles | index("d /var/lib/media-manager/refresh-results 0750 media-manager media-manager -") != null)
  and (.stateTmpfiles | index("z /var/lib/media-manager/control.sqlite3 0660 media-manager media-manager -") != null)
  and (.stateTmpfiles | index("z /var/lib/media-manager/control.sqlite3-wal 0660 media-manager media-manager -") != null)
  and (.stateTmpfiles | index("z /var/lib/media-manager/control.sqlite3-shm 0660 media-manager media-manager -") != null)
  and (.brokerTimer.OnBootSec == "20s")
  and (.brokerTimer.OnUnitInactiveSec == "10s")
  and (.integrations.jellyfin.capabilities == ["library-refresh"])
  and (.integrations.audiobookshelf.capabilities == ["library-refresh"])
  and (.integrations.kavita.capabilities == [])
  and (.integrations.syncthing.capabilities == ["folder-rescan"])
  and (.refreshPath.PathChanged == "/var/lib/media-manager/refresh-requests")
  and (.refreshPath.Unit == "media-manager-refresh-dispatch.service")
  and (.refreshDispatcher.User == "root")
  and (.refreshDispatcher.Group == "media-manager")
  and (.refreshDispatcher.PrivateNetwork == true)
  and (.refreshDispatcher.RestrictAddressFamilies == ["AF_UNIX"])
  and (.refreshDispatcher.CapabilityBoundingSet == [])
  and (.jellyfinRefresh.IPAddressDeny == "any")
  and (.jellyfinRefresh.IPAddressAllow == ["localhost"])
  and (.jellyfinRefresh.ProtectProc == "invisible")
  and (.audiobookshelfRefresh.IPAddressDeny == "any")
  and (.audiobookshelfRefresh.IPAddressAllow == ["localhost"])
  and (.audiobookshelfRefresh.ProtectProc == "invisible")
  and (.syncthingRefresh.IPAddressDeny == "any")
  and (.syncthingRefresh.IPAddressAllow == ["localhost"])
  and (.syncthingRefresh.ProtectProc == "invisible")
  and (.storageAccessScript | contains("setfacl -x \"d:g:$group\" /mnt/data/shared"))
  and (.storageAccessScript | contains("-m g:media-manager-broker:r-x"))
  and (.storageAccessScript | contains("setfacl -P -R"))
' <<<"$surface_json" >/dev/null || {
  echo "❌ Media Manager core configuration is invalid." >&2
  jq . <<<"$surface_json"
  exit 1
}

require_fixed documentation/decisions/0001-media-manager-architecture.md \
  'The browser never supplies an arbitrary filesystem path' \
  "The Media Manager trust-boundary decision must remain documented."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/plans/{planId}/confirm:' \
  "The staged mutation confirmation contract must remain explicit."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  'If-Match' \
  "Mutation confirmation must bind to the previewed plan digest."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/integrations/{integrationId}/refresh:' \
  "Manual application refresh must remain a closed API contract."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'systemctl start --wait "$unit"' \
  "Refresh dispatch must wait for each adapter's eventual result."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'markers=("$request_dir"/*.request)' \
  "Refresh dispatch must drain requests that arrive while another adapter is running."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'result_dir=' \
  "Refresh dispatch must persist terminal results for browser polling."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'ScheduledTasks/Running/$task_id' \
  "Jellyfin refresh must use the current scheduled-task completion API."
require_fixed modules/Core_Modules/media-manager/services.nix \
  '$base_url/api/tasks' \
  "Audiobookshelf refresh must follow current library-scan task results."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  'Omit when the actual release year is unknown.' \
  "Unknown years must remain omitted from guided naming."
require_fixed custom_apps/rust/apps/media-manager/src/bin/media-manager-broker.rs \
  '.truncate(false)' \
  "The global broker lock must never truncate an existing lock inode on open."
require_fixed secrets/manifest.nix \
  'openSubtitlesCredentials = {' \
  "OpenSubtitles credentials must remain an optional encrypted external secret."

echo "✅ Media Manager core boundary, identity, persistence, and API contract are valid."
