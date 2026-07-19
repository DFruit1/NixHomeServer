#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host_name="$(
  nix eval --json '.#nixosConfigurations' --apply builtins.attrNames \
    | jq -er '[.[] | select(endswith("-bootstrap") | not)] | first'
)"

serializable_settings="$(nix eval --json '.#lib.nixhomeserverSerializableSettings')"
jq -e --arg host "$host_name" '
  length == 1
  and has($host)
  and (.[ $host ].serverLanIP | type == "string" and length > 0)
  and (.[ $host ].localAdminUser | type == "string" and length > 0)
' <<<"$serializable_settings" >/dev/null || {
  echo "❌ Maintenance apps cannot evaluate the sole host transport settings as JSON."
  jq . <<<"$serializable_settings"
  exit 1
}

runtime_json="$(NIXHOMESERVER_TEST_HOST="$host_name" nix eval --impure --json --expr '
let
  f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr hostName f.nixosConfigurations).config;
in {
  dataPool = {
    forceImportRoot = cfg.boot.zfs.forceImportRoot;
    wantedBy = cfg.systemd.services.data-pool-layout.wantedBy;
    fileshareRequires = cfg.systemd.services.fileshare-user-root-sync.requires;
    fileshareAfter = cfg.systemd.services.fileshare-user-root-sync.after;
    kopiaBootstrapRequires = cfg.systemd.services.kopia-repository-bootstrap.requires;
    kopiaSnapshotRequires = cfg.systemd.services.kopia-persist-snapshot.requires;
    zfsMaintenanceOrdering = map
      (name: {
        inherit name;
        requires = cfg.systemd.services.${name}.requires;
        after = cfg.systemd.services.${name}.after;
      })
      [ "zfs-scrub" "zfs-snapshot-daily" "zfs-snapshot-hourly" "zfs-snapshot-weekly" ];
  };
  dns = {
    freebind = cfg.services.unbound.settings.server.ip-freebind;
    unboundBefore = cfg.systemd.services.unbound.before;
    netbirdAfter = cfg.systemd.services.netbird-main.after;
  };
  monitoring = {
    passwordAuthDisabled = cfg.services.beszel.hub.environment.DISABLE_PASSWORD_AUTH;
    trustedAuthHeader = cfg.services.beszel.hub.environment.TRUSTED_AUTH_HEADER or null;
    servicePatterns = cfg.systemd.services.beszel-agent.environment.SERVICE_PATTERNS;
  };
  syncthing = cfg.repo.authGateway.protectedApps.syncthing;
  backups = {
    sqliteSources = map (dump: dump.source) cfg.repo.backups.sqliteDumps;
    postgresqlDatabases = map (dump: dump.database) cfg.repo.backups.postgresqlDumps;
    snapshotRoots = cfg.repo.backups.snapshotRoots;
  };
  optionalFiles = {
    kanidmRequires = cfg.systemd.services.kanidm.requires;
    sftpRequires = cfg.systemd.services.files-sftp-sshd.requires;
    sftpWants = cfg.systemd.services.files-sftp-sshd.wants;
    filestashRequires = cfg.systemd.services.filestash.requires;
  };
  maintenance = {
    backupUnit = cfg.systemd.services.backup-prepare.unitConfig;
    backupServiceHasStartLimit = cfg.systemd.services.backup-prepare.serviceConfig ? StartLimitIntervalSec;
    kopiaSnapshotUnit = cfg.systemd.services.kopia-persist-snapshot.unitConfig;
    gcUnit = cfg.systemd.services.nixhomeserver-nix-gc.unitConfig;
  };
  persistence = {
    directories = cfg.repo.impermanence.inventory.persistenceDirectories;
    files = cfg.repo.impermanence.inventory.persistenceFiles;
  };
  localAdminPassword = {
    wantedBy = cfg.systemd.services.local-admin-bootstrap-password.wantedBy;
    before = cfg.systemd.services.local-admin-bootstrap-password.before;
    credentials = cfg.systemd.services.local-admin-bootstrap-password.serviceConfig.LoadCredential;
    execStart = toString cfg.systemd.services.local-admin-bootstrap-password.serviceConfig.ExecStart;
    restartTriggers = map toString cfg.systemd.services.local-admin-bootstrap-password.restartTriggers;
    expectedRestartTrigger = toString cfg.age.secrets.serverBootstrapSudoPassword.file;
    sshPasswordAuthentication = cfg.services.openssh.settings.PasswordAuthentication;
  };
  fileshareAclMigration = {
    wantedBy = cfg.systemd.services.fileshare-acl-migrate.wantedBy;
    after = cfg.systemd.services.fileshare-acl-migrate.after;
    script = cfg.systemd.services.fileshare-acl-migrate.script;
    policyVersion = cfg.repo.storage.userRoots.aclPolicyVersion;
  };
}')"

jq -e '
  (.dataPool.wantedBy | index("local-fs.target") != null)
  and (.dataPool.forceImportRoot == false)
  and (.dataPool.fileshareRequires | index("data-pool-layout.service") != null)
  and (.dataPool.fileshareAfter | index("kanidm-unixd.service") != null)
  and (.dataPool.kopiaBootstrapRequires | index("data-pool-layout.service") != null)
  and (.dataPool.kopiaSnapshotRequires | index("data-pool-layout.service") != null)
  and (.dataPool.kopiaSnapshotRequires | index("kopia-repository-bootstrap.service") != null)
  and (.dataPool.zfsMaintenanceOrdering | all(
    (.requires | index("data-pool-layout.service") != null)
    and (.after | index("data-pool-layout.service") != null)
  ))
  and (.dns.freebind == true)
  and (.dns.unboundBefore | index("netbird-main.service") != null)
  and (.dns.netbirdAfter | index("unbound.service") != null)
  and (.monitoring.passwordAuthDisabled == "false")
  and (.monitoring.trustedAuthHeader == null)
  and (.monitoring.servicePatterns | contains("groundwater-logger*"))
  and (.monitoring.servicePatterns | contains("prowlarr*"))
  and (.monitoring.servicePatterns | contains("qbittorrent*"))
  and (.monitoring.servicePatterns | contains("radarr*"))
  and (.monitoring.servicePatterns | contains("seerr*"))
  and (.monitoring.servicePatterns | contains("sonarr*"))
  and (.syncthing.host | startswith("syncthing."))
  and (.syncthing.upstream == "http://127.0.0.1:8384")
  and (.syncthing.allowedGroups == ["app-admin"])
  and (.backups.sqliteSources | index("/var/lib/seerr/db/db.sqlite3") == null)
  and (.backups.sqliteSources | index("/var/lib/audiobookshelf/config/absdatabase.sqlite") != null)
  and (.backups.sqliteSources | index("/var/lib/jellyfin/data/jellyfin.db") != null)
  and (.backups.postgresqlDatabases | index("immich") != null)
  and (.backups.snapshotRoots | index("/persist") != null)
  and (.backups.snapshotRoots | index("/mnt/data/paperless") != null)
  and (.optionalFiles.kanidmRequires | index("filestash-secret-materialize.service") == null)
  and (.optionalFiles.kanidmRequires | index("filestash-identity-secret-materialize.service") != null)
  and (.optionalFiles.sftpRequires | index("data-pool-layout.service") != null)
  and (.optionalFiles.sftpRequires | index("fileshare-user-root-sync.service") != null)
  and (.optionalFiles.sftpWants | index("filestash-secret-materialize.service") == null)
  and (.optionalFiles.filestashRequires | index("data-pool-layout.service") != null)
  and (.optionalFiles.filestashRequires | index("fileshare-user-root-sync.service") != null)
  and (.maintenance.backupUnit.StartLimitIntervalSec == "2h")
  and (.maintenance.backupServiceHasStartLimit == false)
  and (.maintenance.kopiaSnapshotUnit.StartLimitIntervalSec == "2h")
  and (.maintenance.gcUnit.StartLimitIntervalSec == "4h")
  and (.localAdminPassword.wantedBy | index("multi-user.target") != null)
  and (.localAdminPassword.before | index("systemd-user-sessions.service") != null)
  and (.localAdminPassword.credentials | index("bootstrap-password:/run/agenix/serverBootstrapSudoPassword") != null)
  and (.localAdminPassword.execStart | contains("local-admin-bootstrap-password"))
  and (.localAdminPassword as $localAdmin | ($localAdmin.restartTriggers | index($localAdmin.expectedRestartTrigger) != null))
  and (.localAdminPassword.sshPasswordAuthentication == false)
  and (.fileshareAclMigration.wantedBy | index("multi-user.target") != null)
  and (.fileshareAclMigration.after | index("fileshare-user-root-sync.service") != null)
  and (.fileshareAclMigration as $acl | ($acl.script | contains("fileshare-acl-policy-v" + ($acl.policyVersion | tostring))))
  and (.fileshareAclMigration.script | contains("install -D -m 0600 /dev/null \"$marker\""))
  and (.persistence.directories | index("/etc/nixos") != null)
  and (.persistence.directories | index("/var/lib/postgresql") != null)
  and (.persistence.directories | index("/var/log/caddy") != null)
  and (.persistence.files | index("/etc/machine-id") != null)
  and (.persistence.files | index("/var/lib/systemd/random-seed") != null)
' <<<"$runtime_json" >/dev/null || {
  echo "❌ Core runtime safety configuration regressed."
  jq . <<<"$runtime_json"
  exit 1
}

require_fixed modules/Core_Modules/storage/layout.nix \
  'Required ZFS pool ${vars.zfsDataPool.name} is not mounted at ${vars.dataRoot}' \
  "The data-pool layout must fail instead of writing beneath an absent pool mount."
require_fixed modules/Core_Modules/storage/layout.nix \
  'Required ZFS dataset $dataset is not mounted at $mountpoint' \
  "Every managed ZFS dataset must be checked after reconciliation."
require_fixed modules/Core_Modules/storage/layout.nix \
  'Refusing to hide existing files beneath unmounted data-pool path $mountpoint' \
  "Pool reconciliation must not conceal files written beneath a missing mount."
require_fixed modules/Core_Modules/storage/fileshare-user-roots.nix \
  'Refusing fileshare operation because ${vars.dataRoot} is not a mounted data pool' \
  "Fileshare reconciliation must recheck the data mount on every run."
forbid_match modules/Core_Modules/backups/default.nix '/var/lib/seerr/db/db[.]sqlite3' \
  "Disabled Seerr state must not be mandatory in the core backup module."
require_fixed modules/Core_Modules/backups/default.nix 'sha256sum -- "dumps/$output_name"' \
  "Published backup checksums must use generation-relative dump paths."
require_fixed modules/Core_Modules/backups/default.nix 'sha256sum --check metadata/SHA256SUMS' \
  "Backup preparation must verify its checksum manifest before publication."
require_fixed modules/Core_Modules/backups/default.nix 'mktemp -d ${lib.escapeShellArg stagingRoot}/.current-link.XXXXXX' \
  "Backup publication must use a unique temporary symlink directory."
forbid_match modules/Core_Modules/backups/default.nix 'successfulCurrentPath[}]?[.]new' \
  "Backup publication must not be wedged by a crash-persistent current.new path."
forbid_match modules/Core_Modules/backups/default.nix 'sha256sum .*[$]work/dumps' \
  "Backup checksum manifests must not retain transient staging paths."
require_fixed modules/seerr/backups.nix 'config = lib.mkIf config.repo.seerr.enable' \
  "Seerr backup declarations must remain conditional on the service being enabled."
require_fixed modules/Core_Modules/syncthing/default.nix 'repo.authGateway.protectedApps.syncthing' \
  "The Syncthing administrative GUI must remain behind the shared SSO gateway."
forbid_match modules/Core_Modules/syncthing/default.nix 'reverse_proxy http://127[.]0[.]0[.]1:8384' \
  "Syncthing must not regain a direct unauthenticated Caddy proxy."
require_fixed modules/files/services.nix 'webAccessGroups = [ webAccessGroup ];' \
  "Supplementary USB or backup groups must not independently grant Filestash login."
require_fixed modules/Core_Modules/kanidm/sftp-files.nix '${sftpAuthorizedKeysDir}/.filestash' \
  "The Filestash backend key must work for dynamically managed web users."
require_fixed modules/Core_Modules/rclone/service.nix '${pkgs.rclone}/bin/rclone check' \
  "Offsite sync must independently verify the uploaded repository."
require_fixed modules/Core_Modules/rclone/service.nix 'last-mega-sync-success.json' \
  "Offsite verification must publish an operator-visible success marker."
require_fixed documentation/operations.md 'rcloneMega.enable = true' \
  "Offsite setup documentation must explicitly enable the declarative service."
require_fixed documentation/restore-and-recovery.md 'Use `rclone copy`, never reverse `rclone sync`' \
  "Recovery documentation must guard the only offsite copy from reverse-sync deletion."
require_fixed documentation/quickstart.md 'mount --bind /mnt/persist/etc/nixos /mnt/etc/nixos' \
  "Fresh installs must seed the on-host repository into persisted storage before first rollback."
require_fixed modules/Core_Modules/impermanence/default.nix 'system.activationScripts.seedCorePersistence' \
  "Existing hosts must migrate newly centralized core persistence before bind mounts hide live state."
forbid_match modules/Core_Modules/monitoring/services.nix 'TRUSTED_AUTH_HEADER' \
  "Beszel must not trust a forgeable header from arbitrary local processes."
require_fixed scripts/test-homepage-ui.sh '--inputs-from "$repo_root"' \
  "Playwright must resolve from the flake-pinned nixpkgs input."
require_fixed scripts/test-homepage-ui.sh '#checks.${system}.homepage' \
  "Homepage browser tests must build and run the hermetic flake check output."
forbid_match scripts/test-homepage-ui.sh 'pnpm run build' \
  "Homepage browser tests must not rely on a pre-existing pnpm installation or node_modules tree."
forbid_match scripts/test-homepage-ui.sh 'rm -rf tests/e2e/node_modules' \
  "Homepage browser tests must not destructively remove a pre-existing node_modules tree."
require_fixed custom_apps/node/apps/homepage/tests/e2e/playwright.config.mjs 'HOMEPAGE_E2E_SERVER_COMMAND' \
  "Homepage browser tests must support the packaged server command supplied by the hermetic harness."
require_fixed custom_apps/node/apps/homepage/tests/e2e/playwright.config.mjs 'HOMEPAGE_E2E_STATIC_DIR' \
  "Homepage browser tests must support packaged static assets supplied by the hermetic harness."
require_fixed scripts/validate-repo.sh '"$repo_root/scripts/test-homepage-ui.sh"' \
  "The full validation gate must include the Homepage Playwright suite."
require_fixed flake/checks.nix 'nodejs' \
  "The hermetic repo-policy check must provide Node for canary render tests."
require_fixed flake/apps.nix 'settings_json="$(nix eval --json "$repo#lib.nixhomeserverSerializableSettings")"' \
  "Maintenance apps must discover the configured host instead of assuming a fixed hostname."
forbid_match flake/apps.nix 'nixhomeserverSettings[.]serverLanIP' \
  "Maintenance apps must not address host settings as though they were top-level attributes."
forbid_match scripts 'builtins[.]getFlake[[:space:]]*[(][[:space:]]*toString' \
  "Repository checks must use Git-filtered flake references so ignored build artifacts cannot break evaluation."
require_fixed scripts/helpers/repo-common.sh 'NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$repo_root"' \
  "Manifest-filtered deployment archives must remain evaluable without a .git directory."
forbid_match scripts/tests/module-removal-matrix.nix 'self = repo;' \
  "Module-removal checks must not coerce the unfiltered working tree into the Nix store."

echo "✅ Core runtime safety regression tests passed."
