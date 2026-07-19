#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools rg

require_match modules/seerr/bootstrap.nix \
  'config\.assertions = lib\.mkIf config\.repo\.seerr\.enable' \
  "disabled Seerr must not require Seerr-only secrets"

for identity_file in \
  modules/immich/identity.nix \
  modules/youtube-downloader/identity.nix \
  modules/groundwater-logger/identity.nix; do
  forbid_match "$identity_file" '(uid|gid)[[:space:]]*=[[:space:]]*[0-9]+' \
    "portable app identities in $identity_file must not reserve fixed numeric IDs"
done
for service_file in \
  modules/immich/public-proxy.nix \
  modules/groundwater-logger/services.nix; do
  require_fixed "$service_file" 'chown -R' \
    "dynamic app identities in $service_file must migrate persistent state ownership"
done
require_fixed modules/youtube-downloader/services.nix 'youtube-downloader-ownership-v1' \
  "YouTube Downloader ownership migration must use a durable identity marker"
require_fixed modules/youtube-downloader/services.nix 'youtube-downloader-ownership-migration.service' \
  "YouTube Downloader restarts must skip completed recursive ownership migration"
forbid_match modules/immich/public-proxy.nix 'toString proxyUid|config\.users\.users.*\.uid' \
  "Immich public proxy must resolve its dynamic UID at runtime"

youtube_module=modules/youtube-downloader/services.nix
youtube_paths=modules/youtube-downloader/filepaths.nix
youtube_http=custom_apps/node/apps/youtube-downloader/src/server/http.ts
youtube_db=custom_apps/node/apps/youtube-downloader/src/server/db.ts
groundwater_network=modules/groundwater-logger/networking.nix
canary_module=modules/homepage/canary.nix
canary_runner=modules/homepage/canary-runner.mjs
jellyfin_bootstrap=modules/jellyfin/bootstrap.nix
archive_module=modules/files/archives.nix

forbid_match "$youtube_module" 'yt-dlp-nightly-builds|youtube-downloader-yt-dlp-update' \
  "YouTube Downloader must use the flake-locked yt-dlp package"
require_fixed "$youtube_module" 'files-shared-users' \
  "YouTube Downloader must join the shared write group"
require_fixed "$youtube_paths" '1770 youtube-downloader ${sharedAccessGroup}' \
  "shared download roots must be writable by the downloader service"
require_fixed "$youtube_http" 'db.listJobs(user.username)' \
  "job history must be scoped to the authenticated user"
require_fixed "$youtube_http" 'db.getJobForUser(jobId, user.username)' \
  "job access must check ownership"
require_fixed "$youtube_db" 'claimNextQueuedJob' \
  "queue workers must atomically claim jobs"

require_fixed "$groundwater_network" 'repo.authGateway.protectedApps.groundwater' \
  "the MQTT command console must use the authentication gateway"
require_fixed "$groundwater_network" 'allowedGroups = [ "app-admin" ];' \
  "the MQTT command console must be limited to administrators"
require_match modules/groundwater-logger/services.nix \
  'unitConfig = \{[^}]*StartLimitIntervalSec[^}]*StartLimitBurst' \
  "Groundwater restart throttling must use systemd unit settings"
forbid_match modules/groundwater-logger/services.nix \
  'serviceConfig = \{[^}]*StartLimitIntervalSec' \
  "Groundwater restart throttling must not be emitted as invalid service settings"

forbid_match "$canary_module" 'SuccessExitStatus[[:space:]]*=[[:space:]]*\[[[:space:]]*1' \
  "failed canary runs must fail their systemd unit"
require_fixed "$canary_runner" 'loginControls' \
  "the canary must inspect concrete login controls"
forbid_match "$canary_runner" 'run[.]lock' \
  "canary locking must not use a crash-persistent sentinel file"
require_fixed "$canary_module" '/run/homepage-canary/run.lock' \
  "canary overlap protection must use a kernel-released runtime flock"
require_fixed "$canary_module" 'ExecStopPost = cleanupRunningState' \
  "canary termination must remove stale running state"
forbid_match "$canary_runner" '\|\| /sign in\|log in\|login\|authenticate\|kanidm\|password/i' \
  "generic page words must not count as an authentication boundary"

require_match "$jellyfin_bootstrap" \
  '(?s)desired_policy=.*\.IsAdministrator = \$isAdmin.*\.IsHidden = false.*\.IsDisabled = false' \
  "managed Jellyfin members must be enabled"
require_fixed "$jellyfin_bootstrap" 'initial-credential-state.json' \
  "Jellyfin initial credential handoff must be durable"
require_fixed "$jellyfin_bootstrap" 'install -m 0600 -o root -g root "$temporary" "$credential_file"' \
  "Jellyfin initial credentials must be root-only"
require_fixed "$jellyfin_bootstrap" 'set_initial_password "$user_id" "$password"' \
  "legacy Jellyfin managed users must receive a recoverable initial credential"
require_fixed "$jellyfin_bootstrap" 'sharedVideoLibraries ++ sharedMusicLibraries' \
  "configured Jellyfin shared music libraries must be provisioned"
require_fixed modules/jellyfin/filepaths.nix 'cfg.paths.sharedMusicRoot' \
  "Jellyfin shared music paths must receive layout and ACL handling"

require_fixed modules/audiobookshelf/filepaths.nix 'rootTraverseGroups' \
  "Audiobookshelf must only traverse user roots"
forbid_match modules/audiobookshelf/filepaths.nix 'rootWritableGroups' \
  "Audiobookshelf must not receive writable ACLs on entire user roots"

require_fixed modules/immich/oidc-reconcile.nix "--set=kanidm_uuid=\"\$kanidm_uuid\"" \
  "Immich reconciliation must bind PostgreSQL values"
require_fixed modules/immich/oidc-reconcile.nix ":'kanidm_uuid'" \
  "Immich reconciliation SQL must use psql literal variables"

require_fixed "$archive_module" 'maximumExpandedBytes' \
  "archive extraction must enforce an expanded-size ceiling"
require_fixed "$archive_module" 'maximumEntries' \
  "archive extraction must enforce an entry-count ceiling"
require_fixed "$archive_module" 'Refusing unsafe archive member path' \
  "archive extraction must reject traversal paths"
require_fixed "$archive_module" 'find "$tmp_path" -type l -delete' \
  "archive views must not expose symlinks"
require_fixed "$archive_module" 'RequiresMountsFor = [ vars.dataRoot ];' \
  "archive writers must require the data filesystem"

for service_file in \
  modules/youtube-downloader/services.nix \
  modules/jellyfin/services.nix \
  modules/audiobookshelf/services.nix \
  modules/files/archives.nix; do
  require_fixed "$service_file" 'requires = [' \
    "data-writing services in $service_file must fail closed on failed dependencies"
done

echo "✅ Application hardening regression checks passed."
