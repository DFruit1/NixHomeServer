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
  providerService = cfg.systemd.services.media-manager-provider-broker.serviceConfig;
  providerEnvironment = cfg.systemd.services.media-manager-provider-broker.environment;
  providerUserGroup = cfg.users.users.media-manager-provider.group;
  providerUserHome = cfg.users.users.media-manager-provider.home;
  brokerUserGroup = cfg.users.users.media-manager-broker.group;
  brokerUserExtraGroups = cfg.users.users.media-manager-broker.extraGroups;
  stateTmpfiles = cfg.systemd.tmpfiles.rules;
  ageSecretNames = builtins.attrNames cfg.age.secrets;
  broker = cfg.systemd.services.media-manager-broker.serviceConfig;
  brokerTimer = cfg.systemd.timers.media-manager-broker.timerConfig;
  scanner = cfg.systemd.services.media-manager-scanner.serviceConfig;
  scannerTimer = cfg.systemd.timers.media-manager-scanner.timerConfig;
  integrations = cfg.repo.mediaManager.integrations;
  refreshPath = cfg.systemd.paths.media-manager-refresh-requests.pathConfig;
  refreshDispatcher = cfg.systemd.services.media-manager-refresh-dispatch.serviceConfig;
  jellyfinRefresh = cfg.systemd.services.media-manager-refresh-jellyfin.serviceConfig;
  jellyfinMetadata = cfg.systemd.services.media-manager-jellyfin-metadata.serviceConfig;
  jellyfinMetadataTimer = cfg.systemd.timers.media-manager-jellyfin-metadata.timerConfig;
  audiobookshelfRefresh = cfg.systemd.services.media-manager-refresh-audiobookshelf.serviceConfig;
  audiobookshelfMetadata = cfg.systemd.services.media-manager-audiobookshelf-metadata.serviceConfig;
  audiobookshelfMetadataTimer = cfg.systemd.timers.media-manager-audiobookshelf-metadata.timerConfig;
  kavitaRefresh = cfg.systemd.services.media-manager-refresh-kavita.serviceConfig;
  kavitaMetadata = cfg.systemd.services.media-manager-kavita-metadata.serviceConfig;
  kavitaMetadataTimer = cfg.systemd.timers.media-manager-kavita-metadata.timerConfig;
  syncthingRefresh = cfg.systemd.services.media-manager-refresh-syncthing.serviceConfig;
  storageAccessScript = cfg.systemd.services.media-manager-storage-access.script;
  wantedBy = cfg.systemd.services.media-manager.wantedBy;
}')"

jq -e '
  (.app.enable == true)
  and (.app.domain == "media.sydneybasiniot.org")
  and (.app.stateDir == "/var/lib/media-manager")
  and (.app.providerStateDir == "/var/lib/media-manager-provider")
  and (.app.providerPort == 8089)
  and (.app.mutationMode == "enabled")
  and (.app.editorGroup == "media-manager-editors")
  and (.app.roots | map(.id) == [
    "shared-videos",
    "shared-music",
    "shared-audiobooks",
    "shared-podcasts",
    "shared-books",
    "personal-videos",
    "personal-music",
    "personal-audiobooks",
    "personal-podcasts",
    "personal-books"
  ])
  and (.gateway.host == .app.domain)
  and (.gateway.upstream == "http://127.0.0.1:8087")
  and (.gateway.authenticatedRoutes == [
    {
      "pathPrefix": "/api/v1/provider-accounts",
      "upstream": "http://127.0.0.1:8089"
    },
    {
      "pathPrefix": "/api/v1/provider-lookups",
      "upstream": "http://127.0.0.1:8089"
    }
  ])
  and (.gateway.allowedGroups == ["users"])
  and (.privateDns.target == "private")
  and (.group.overwriteMembers == false)
  and (.group.members | length == 1)
  and (.scopes | index("groups_name") != null)
  and (.persistence | index("/var/lib/media-manager") != null)
  and (.persistence | index("/var/lib/media-manager-provider") != null)
  and (.backupApps | index("media-manager") != null)
  and (.sqliteSources | index("/var/lib/media-manager/control.sqlite3") != null)
  and (.sqliteSources | index("/var/lib/media-manager-provider/provider-accounts.sqlite3") != null)
  and (.wantedBy | index("multi-user.target") != null)
  and (.service.User == "media-manager")
  and (.service.Group == "media-manager")
  and (.service.DynamicUser == false)
  and (.service.NoNewPrivileges == true)
  and (.service.ProtectSystem == "strict")
  and (.service.PrivateTmp == true)
  and ((.service.RestrictSUIDSGID // false) == false)
  and (.service.ReadWritePaths == ["/var/lib/media-manager"])
  and (.providerUserGroup == "media-manager-provider")
  and (.providerUserHome == "/var/lib/media-manager-provider")
  and (.providerService.User == "media-manager-provider")
  and (.providerService.Group == "media-manager-provider")
  and (.providerService.StateDirectory == "media-manager-provider")
  and (.providerService.StateDirectoryMode == "0700")
  and (.providerService.UMask == "0077")
  and (.providerService.NoNewPrivileges == true)
  and (.providerService.ProtectSystem == "strict")
  and (.providerService.ProtectHome == true)
  and (.providerService.PrivateDevices == true)
  and (.providerService.CapabilityBoundingSet == [])
  and (.providerService.AmbientCapabilities == [])
  and (.providerService.RestrictAddressFamilies == ["AF_INET", "AF_INET6"])
  and (.providerService.ReadWritePaths == ["/var/lib/media-manager-provider"])
  and (.providerEnvironment.MEDIA_MANAGER_PROVIDER_ADDRESS == "127.0.0.1")
  and (.providerEnvironment.MEDIA_MANAGER_PROVIDER_PORT == "8089")
  and (.providerEnvironment.MEDIA_MANAGER_PROVIDER_STATE_DIR == "/var/lib/media-manager-provider")
  and (.serviceEnvironment.MEDIA_MANAGER_PROVIDER_BROKER_BASE_URL == "http://127.0.0.1:8089/")
  and ((.serviceEnvironment | has("MEDIA_MANAGER_OPENSUBTITLES_CREDENTIALS_FILE")) | not)
  and ((.serviceEnvironment | has("MEDIA_MANAGER_ACOUSTID_API_KEY_FILE")) | not)
  and (.serviceEnvironment.MEDIA_MANAGER_FPCALC_PATH | test(".*chromaprint.*/bin/fpcalc"))
  and (.serviceEnvironment.MEDIA_MANAGER_JELLYFIN_METADATA_CACHE_FILE == "/var/cache/media-manager-jellyfin/metadata.json")
  and (.serviceEnvironment.MEDIA_MANAGER_AUDIOBOOKSHELF_METADATA_CACHE_FILE == "/var/cache/media-manager-audiobookshelf/metadata.json")
  and (.serviceEnvironment.MEDIA_MANAGER_KAVITA_METADATA_CACHE_FILE == "/var/cache/media-manager-kavita/metadata.json")
  and (.serviceEnvironment.MEDIA_MANAGER_JELLYFIN_PUBLIC_URL == "https://videos.sydneybasiniot.org")
  and (.serviceEnvironment.MEDIA_MANAGER_AUDIOBOOKSHELF_PUBLIC_URL == "https://audiobooks.sydneybasiniot.org")
  and (.serviceEnvironment.MEDIA_MANAGER_KAVITA_PUBLIC_URL == "https://books.sydneybasiniot.org")
  and (.ageSecretNames | index("openSubtitlesCredentials") != null)
  and (.ageSecretNames | index("acoustidApiKey") != null)
  and (.service.ReadOnlyPaths | index("-/var/cache/media-manager-jellyfin") != null)
  and (.service.ReadOnlyPaths | index("-/var/cache/media-manager-audiobookshelf") != null)
  and (.service.ReadOnlyPaths | index("-/var/cache/media-manager-kavita") != null)
  and (.brokerUserGroup == "media-manager")
  and (.brokerUserExtraGroups == ["media-manager-broker"])
  and (.broker.User == "media-manager-broker")
  and (.broker.Group == "media-manager")
  and (.broker.SupplementaryGroups == ["media-manager-broker"])
  and (.broker.PrivateNetwork == true)
  and (.broker.NoNewPrivileges == true)
  and ((.broker.RestrictSUIDSGID // false) == false)
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
  and (.scanner.User == "media-manager")
  and (.scanner.Group == "media-manager")
  and (.scanner.Type == "oneshot")
  and (.scanner.ReadWritePaths == ["/var/lib/media-manager"])
  and (.scanner.RestrictAddressFamilies == [])
  and (.scannerTimer.OnBootSec == "2m")
  and (.scannerTimer.OnUnitInactiveSec == "15m")
  and (.scannerTimer.Unit == "media-manager-scanner.service")
  and (.integrations.jellyfin.capabilities == ["library-refresh"])
  and (.integrations.audiobookshelf.capabilities == ["library-refresh"])
  and (.integrations.kavita.capabilities == ["library-refresh"])
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
  and (.jellyfinMetadata.User == "root")
  and (.jellyfinMetadata.Group == "media-manager")
  and (.jellyfinMetadata.CacheDirectory == "media-manager-jellyfin")
  and (.jellyfinMetadata.CacheDirectoryMode == "0750")
  and (.jellyfinMetadata.IPAddressDeny == "any")
  and (.jellyfinMetadata.IPAddressAllow == ["localhost"])
  and (.jellyfinMetadata.ReadOnlyPaths == ["/var/lib/jellyfin/data/library-sync.api-key"])
  and (.jellyfinMetadata.TasksMax == 32)
  and (.jellyfinMetadataTimer.OnBootSec == "2m")
  and (.jellyfinMetadataTimer.OnUnitInactiveSec == "30m")
  and (.audiobookshelfRefresh.IPAddressDeny == "any")
  and (.audiobookshelfRefresh.IPAddressAllow == ["localhost"])
  and (.audiobookshelfRefresh.ProtectProc == "invisible")
  and (.audiobookshelfMetadata.User == "root")
  and (.audiobookshelfMetadata.Group == "media-manager")
  and (.audiobookshelfMetadata.CacheDirectory == "media-manager-audiobookshelf")
  and (.audiobookshelfMetadata.IPAddressDeny == "any")
  and (.audiobookshelfMetadata.IPAddressAllow == ["localhost"])
  and (.audiobookshelfMetadataTimer.OnUnitInactiveSec == "30m")
  and (.kavitaRefresh.IPAddressDeny == "any")
  and (.kavitaRefresh.IPAddressAllow == ["localhost"])
  and (.kavitaRefresh.ProtectProc == "invisible")
  and (.kavitaRefresh.User == "kavita")
  and (.kavitaRefresh.Group == "kavita")
  and (.kavitaRefresh.ReadOnlyPaths == ["/var/lib/kavita/config/kavita.db", "/run/agenix/kavitaTokenKey"])
  and (.kavitaRefresh.SystemCallFilter == ["@system-service", "~@privileged", "~@resources", "fchown"])
  and (.kavitaMetadata.User == "kavita")
  and (.kavitaMetadata.Group == "media-manager")
  and (.kavitaMetadata.CacheDirectory == "media-manager-kavita")
  and (.kavitaMetadata.IPAddressDeny == "any")
  and (.kavitaMetadata.IPAddressAllow == ["localhost"])
  and (.kavitaMetadata.SystemCallFilter == ["@system-service", "~@privileged", "~@resources", "fchown"])
  and (.kavitaMetadataTimer.OnUnitInactiveSec == "30m")
  and (.syncthingRefresh.IPAddressDeny == "any")
  and (.syncthingRefresh.IPAddressAllow == ["localhost"])
  and (.syncthingRefresh.ProtectProc == "invisible")
  and (.storageAccessScript | contains("setfacl -x \"d:g:$group\" /mnt/data/shared"))
  and (.storageAccessScript | contains("-m g:media-manager-broker:r-x"))
  and (.storageAccessScript | contains("setfacl -m g:media-manager:r-x -m g:media-manager-broker:r-x /mnt/data/shared/_ISO"))
  and (.storageAccessScript | contains("setfacl -P -R"))
' <<<"$surface_json" >/dev/null || {
  echo "❌ Media Manager core configuration is invalid." >&2
  jq . <<<"$surface_json"
  exit 1
}

require_fixed documentation/decisions/0001-media-manager-architecture.md \
  'The browser never supplies an arbitrary filesystem path' \
  "The Media Manager trust-boundary decision must remain documented."
require_fixed documentation/decisions/0005-media-provider-accounts-and-lookup.md \
  'Vaultwarden is not a live credential backend' \
  "Runtime provider credentials must remain separate from the password-manager backend."
forbid_match modules/Core_Modules/media-manager/services.nix \
  'compgen -G "\$work/results/\*[.]json"' \
  "Kavita metadata export must not depend on Bash completion builtins unavailable at runtime."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'shopt -s nullglob' \
  'result_files=("$work"/results/*.json)' \
  'jq -s '\''.'\'' "${result_files[@]}"' \
  "Kavita metadata export must collect result files with runtime-safe Bash builtins."
require_fixed custom_apps/rust/apps/media-manager/src/provider_accounts.rs \
  'XChaCha20Poly1305' \
  'associated_data(&identity.subject, provider_id)' \
  "Provider credentials must remain AEAD-bound to the stable subject and provider."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/plans/{planId}/confirm:' \
  "The staged mutation confirmation contract must remain explicit."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/provider-accounts/{providerId}/test:' \
  'Saved credential values are never returned.' \
  "Runtime provider accounts and write-only credential behavior must remain explicit."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/provider-lookups/tmdb/search:' \
  '/provider-lookups/opensubtitles/search:' \
  '/provider-lookups/acoustid/lookup:' \
  "Runtime lookup adapters must remain behind the per-user credential broker."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  'If-Match' \
  "Mutation confirmation must bind to the previewed plan digest."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/integrations/{integrationId}/refresh:' \
  "Manual application refresh must remain a closed API contract."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/items/{itemId}/metadata:' \
  "The read-only item metadata contract must remain explicit."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  '/items/{itemId}/subtitles/installed/{subtitleId}/content:' \
  "Installed subtitle inspection must remain an explicit contained API contract."
require_fixed documentation/decisions/0003-media-metadata-observation-and-propagation.md \
  'Application databases are private' \
  "Application metadata inspection must remain API-backed rather than database-coupled."
require_fixed documentation/decisions/0001-media-manager-architecture.md \
  '/var/cache/media-manager-jellyfin' \
  "Jellyfin metadata must remain separated from web-writable state."
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
  'Audiobookshelf did not become ready before metadata export' \
  "Audiobookshelf metadata export must tolerate service startup latency."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'Jellyfin did not become ready before metadata export' \
  "Jellyfin metadata export must tolerate service startup latency."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'Kavita did not become ready before metadata export' \
  "Kavita metadata export must tolerate service startup latency."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'ScheduledTasks/Running/$task_id' \
  "Jellyfin refresh must use the current scheduled-task completion API."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'subtitleStreams:((.MediaStreams // [])' \
  "Jellyfin metadata snapshots must retain bounded subtitle stream dispositions."
require_fixed modules/Core_Modules/media-manager/services.nix \
  '$base_url/api/tasks' \
  "Audiobookshelf refresh must follow current library-scan task results."
require_fixed modules/Core_Modules/media-manager/services.nix \
  '$base_url/api/library/scan-all?force=false' \
  "Kavita refresh must use the authenticated scan-all API."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'Authorization: Bearer' \
  "Kavita refresh must use a short-lived server-local bearer token."
require_fixed modules/Core_Modules/media-manager/services.nix \
  '"exp": now + 300' \
  "Kavita refresh bearer tokens must remain short-lived."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'A Kavita library was removed while its scan was running' \
  "Kavita refresh must fail promptly when a baseline library disappears."
require_fixed modules/Core_Modules/media-manager/services.nix \
  'Kavita admin username is malformed' \
  "Kavita refresh must validate the configured username before using it in SQL."
require_fixed custom_apps/rust/apps/media-manager/openapi.yaml \
  'Omit when the actual release year is unknown.' \
  "Unknown years must remain omitted from guided naming."
require_fixed custom_apps/rust/apps/media-manager/src/bin/media-manager-broker.rs \
  '.truncate(false)' \
  "The global broker lock must never truncate an existing lock inode on open."
require_fixed secrets/manifest.nix \
  'openSubtitlesCredentials = {' \
  "OpenSubtitles credentials must remain an optional encrypted external secret."
require_fixed secrets/manifest.nix \
  'acoustidApiKey = {' \
  "AcoustID credentials must remain an optional encrypted external secret."

kavita_baseline='[{"id":1,"lastScanned":"before-1"},{"id":2,"lastScanned":"before-2"}]'
kavita_complete='[{"id":1,"lastScanned":"after-1"},{"id":2,"lastScanned":"after-2"}]'
kavita_missing='[{"id":1,"lastScanned":"after-1"}]'
kavita_unchanged='[{"id":1,"lastScanned":"after-1"},{"id":2,"lastScanned":"before-2"}]'
kavita_all_present_filter='. as $current
  | all($before[]; . as $previous
    | any($current[]; .id == $previous.id))'
kavita_all_advanced_filter='. as $current
  | all($before[]; . as $previous
    | any($current[];
      .id == $previous.id and .lastScanned != $previous.lastScanned))'

jq -e --argjson before "$kavita_baseline" "$kavita_all_present_filter" \
  <<<"$kavita_complete" >/dev/null
if jq -e --argjson before "$kavita_baseline" "$kavita_all_present_filter" \
  <<<"$kavita_missing" >/dev/null; then
  echo "Expected a missing Kavita library to fail the completeness check." >&2
  exit 1
fi
jq -e --argjson before "$kavita_baseline" "$kavita_all_advanced_filter" \
  <<<"$kavita_complete" >/dev/null
if jq -e --argjson before "$kavita_baseline" "$kavita_all_advanced_filter" \
  <<<"$kavita_unchanged" >/dev/null; then
  echo "Expected an unchanged Kavita library to fail the advancement check." >&2
  exit 1
fi

echo "✅ Media Manager core boundary, identity, persistence, and API contract are valid."
