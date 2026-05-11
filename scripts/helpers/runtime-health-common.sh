#!/usr/bin/env bash

runtime_health_snapshot_expr() {
  cat <<'EOF'
let
  host = builtins.getAttr vars.hostname flake.nixosConfigurations;
  pkgs = host.pkgs;
  bool = value: if value then true else false;
  optional = cond: value: if cond then [ value ] else [ ];
  optionalString = cond: value: if cond then value else "";
  optionalAttrs = cond: attrs: if cond then attrs else { };
  dataDatasetMounts = map (dataset: "${vars.zfsDataPool.mountPoint}/${dataset}") vars.zfsDataPool.datasets;
  mailArchiveEnabled = cfg.services.mail-archive-ui.enable or false;
  kiwixEnabled = cfg.services.kiwixServe.enable or false;
  metubeEnabled = cfg.systemd.services ? metube-oauth2-proxy;
  intersects = left: right: builtins.any (value: builtins.elem value right) left;
  persistBackedStateRoot =
    stateRoot:
    if lib.hasPrefix "/persist/" stateRoot then
      stateRoot
    else if cfg.repo.impermanence.enablePersistence then
      "/persist${stateRoot}"
    else
      stateRoot;
  localDnsPrivateAnswer = if vars.dnsMode == "split-horizon" then vars.serverLanIP else vars.nbIP;
  appStateEntries = [
    {
      app = "kanidm";
      component = "server";
      stateRoot = "/var/lib/kanidm";
      persistentStateRoot = persistBackedStateRoot "/var/lib/kanidm";
      payloadRoots = [ ];
    }
    {
      app = "caddy";
      component = "acme";
      stateRoot = "/var/lib/acme";
      persistentStateRoot = persistBackedStateRoot "/var/lib/acme";
      payloadRoots = [ ];
    }
    {
      app = "netbird";
      component = "service";
      stateRoot = "/var/lib/netbird-main";
      persistentStateRoot = persistBackedStateRoot "/var/lib/netbird-main";
      payloadRoots = [ ];
    }
    {
      app = "unbound";
      component = "service";
      stateRoot = "/var/lib/unbound";
      persistentStateRoot = persistBackedStateRoot "/var/lib/unbound";
      payloadRoots = [ ];
    }
    {
      app = "immich";
      component = "app";
      stateRoot = "/var/lib/immich";
      persistentStateRoot = persistBackedStateRoot "/var/lib/immich";
      payloadRoots = [ vars.immichRoot ];
    }
    {
      app = "audiobookshelf";
      component = "app";
      stateRoot = "/var/lib/audiobookshelf";
      persistentStateRoot = persistBackedStateRoot "/var/lib/audiobookshelf";
      payloadRoots = [ vars.sharedAudiobooksRoot vars.usersRoot ];
    }
    {
      app = "jellyfin";
      component = "app";
      stateRoot = "/var/lib/jellyfin";
      persistentStateRoot = persistBackedStateRoot "/var/lib/jellyfin";
      payloadRoots = [ vars.sharedVideosRoot vars.usersRoot ];
    }
    {
      app = "kavita";
      component = "app";
      stateRoot = "/var/lib/kavita";
      persistentStateRoot = persistBackedStateRoot "/var/lib/kavita";
      payloadRoots = [ vars.sharedBooksRoot vars.usersRoot ];
    }
    {
      app = "metube";
      component = "app";
      stateRoot = "/var/lib/metube";
      persistentStateRoot = persistBackedStateRoot "/var/lib/metube";
      payloadRoots = [ vars.sharedYouTubeRoot ];
    }
    {
      app = "paperless";
      component = "app";
      stateRoot = "/var/lib/paperless";
      persistentStateRoot = persistBackedStateRoot "/var/lib/paperless";
      payloadRoots = [ vars.paperlessRoot ];
    }
    {
      app = "vaultwarden";
      component = "app";
      stateRoot = "/var/lib/vaultwarden";
      persistentStateRoot = persistBackedStateRoot "/var/lib/vaultwarden";
      payloadRoots = [ ];
    }
    {
      app = "paperless";
      component = "redis";
      stateRoot = cfg.services.redis.servers.paperless.settings.dir;
      persistentStateRoot = persistBackedStateRoot cfg.services.redis.servers.paperless.settings.dir;
      payloadRoots = [ vars.paperlessRoot ];
    }
    {
      app = "immich";
      component = "postgresql";
      stateRoot = cfg.services.postgresql.dataDir;
      persistentStateRoot = persistBackedStateRoot cfg.services.postgresql.dataDir;
      payloadRoots = [ vars.immichManagedRoot ];
    }
    {
      app = "immich";
      component = "redis";
      stateRoot = cfg.services.redis.servers.immich.settings.dir;
      persistentStateRoot = persistBackedStateRoot cfg.services.redis.servers.immich.settings.dir;
      payloadRoots = [ vars.immichManagedRoot ];
    }
    {
      app = "copyparty";
      component = "app";
      stateRoot = "/var/lib/copyparty";
      persistentStateRoot = persistBackedStateRoot "/var/lib/copyparty";
      payloadRoots = [ vars.usersRoot vars.sharedRoot vars.paperlessRoot ];
    }
    {
      app = "filebrowser-quantum";
      component = "app";
      stateRoot = vars.filebrowserStateDir;
      persistentStateRoot = persistBackedStateRoot vars.filebrowserStateDir;
      payloadRoots = [ vars.usersRoot vars.sharedRoot vars.kiwixLibraryRoot ];
    }
    {
      app = "mail-archive-ui";
      component = "app";
      stateRoot = cfg.services.mail-archive-ui.dataDir;
      persistentStateRoot = persistBackedStateRoot cfg.services.mail-archive-ui.dataDir;
      payloadRoots = [ vars.usersRoot vars.sharedEmailsRoot ];
    }
  ];
  requiredPathEntries =
    [
      { label = "copyparty-archive-metadata"; path = "${vars.paperlessArchiveRoot}/.hist"; }
    ]
    ++ optional mailArchiveEnabled { label = "mail-archive-ui-data"; path = cfg.services.mail-archive-ui.dataDir; }
    ++ optional mailArchiveEnabled { label = "mail-archive-ui-runtime"; path = cfg.services.mail-archive-ui.runtimeDir; }
    ++ optional mailArchiveEnabled { label = "mail-archive-ui-locks"; path = cfg.services.mail-archive-ui.lockDir; }
    ++ optional mailArchiveEnabled { label = "mail-archive-ui-store-root"; path = cfg.services.mail-archive-ui.storeRoot; };
  accessCheckApps =
    [
      {
        name = "uploads";
        kind = "oauth2-proxy";
        entryUrl = "https://${vars.uploadsDomain}/";
        expectedLandingUrl = "https://${vars.uploadsDomain}/";
        allowedGroups = [ "user-files" ];
        localUnauthCheck = {
          host = vars.uploadsDomain;
          path = "/";
          expected = [ 302 303 ];
          redirectPrefix = "https://id.${vars.domain}/ui/oauth2";
        };
        verification = {
          finalUrlPrefix = "https://${vars.uploadsDomain}/";
          markerText = "copyparty";
        };
      }
      {
        name = "files";
        kind = "oidc-direct";
        entryUrl = "https://${vars.filebrowserDomain}/";
        expectedLandingUrl = "https://${vars.filebrowserDomain}/";
        allowedGroups = [ "user-files" "shared-files-read-write-access" ];
        localUnauthCheck = {
          host = vars.filebrowserDomain;
          path = "/login";
          expected = [ 302 303 ];
          redirectPrefix = "/api/auth/oidc/login";
        };
        verification = {
          finalUrlPrefix = "https://${vars.filebrowserDomain}/";
          markerText = "Files";
        };
      }
      {
        name = "paperless";
        kind = "oidc-direct";
        entryUrl = "https://paperless.${vars.domain}/";
        expectedLandingUrl = "https://paperless.${vars.domain}";
        allowedGroups = [ "paperless-users" ];
        localUnauthCheck = null;
        verification = {
          finalUrlPrefix = "https://paperless.${vars.domain}";
          markerText = "Paperless";
        };
      }
      {
        name = "photos";
        kind = "oidc-direct";
        entryUrl = "https://${vars.photosDomain}/";
        expectedLandingUrl = "https://${vars.photosDomain}";
        allowedGroups = [ "immich-users" ];
        localUnauthCheck = null;
        verification = {
          finalUrlPrefix = "https://${vars.photosDomain}";
          markerText = "Immich";
        };
      }
      {
        name = "audiobooks";
        kind = "oidc-direct";
        entryUrl = "https://${vars.audiobooksDomain}/audiobookshelf/";
        expectedLandingUrl = "https://${vars.audiobooksDomain}/audiobookshelf/";
        allowedGroups = [ "audiobookshelf-users" ];
        localUnauthCheck = null;
        verification = {
          finalUrlPrefix = "https://${vars.audiobooksDomain}/audiobookshelf/";
          markerText = "Audiobookshelf";
        };
      }
      {
        name = "books";
        kind = "oidc-direct";
        entryUrl = "https://${vars.kavitaDomain}/";
        expectedLandingUrl = "https://${vars.kavitaDomain}/";
        allowedGroups = [ "kavita-users" ];
        localUnauthCheck = null;
        verification = {
          finalUrlPrefix = "https://${vars.kavitaDomain}/";
          markerText = "Kavita";
        };
      }
      {
        name = "monitor";
        kind = "oauth2-proxy";
        entryUrl = "https://${vars.monitorDomain}/";
        expectedLandingUrl = "https://${vars.monitorDomain}";
        allowedGroups = [ "glances-users" ];
        localUnauthCheck = {
          host = vars.monitorDomain;
          path = "/";
          expected = [ 302 303 ];
          redirectPrefix = "https://id.${vars.domain}/ui/oauth2";
        };
        verification = {
          finalUrlPrefix = "https://${vars.monitorDomain}";
          markerText = vars.monitorDomain;
        };
      }
    ]
    ++ optional kiwixEnabled {
      name = "kiwix";
      kind = "oauth2-proxy";
      entryUrl = "https://${vars.kiwixDomain}/";
      expectedLandingUrl = "https://${vars.kiwixDomain}";
      allowedGroups = [ "users" ];
      localUnauthCheck = {
        host = vars.kiwixDomain;
        path = "/";
        expected = [ 302 303 ];
        redirectPrefix = "https://id.${vars.domain}/ui/oauth2";
      };
      verification = {
        finalUrlPrefix = "https://${vars.kiwixDomain}";
        markerText = vars.kiwixDomain;
      };
    }
    ++ optional mailArchiveEnabled {
      name = "emails";
      kind = "oauth2-proxy";
      entryUrl = "https://${vars.emailsDomain}/";
      expectedLandingUrl = "https://${vars.emailsDomain}";
      allowedGroups = [ "mail-archive-users" ];
      localUnauthCheck = {
        host = vars.emailsDomain;
        path = "/";
        expected = [ 302 303 ];
        redirectPrefix = "https://id.${vars.domain}/ui/oauth2";
      };
      verification = {
        finalUrlPrefix = "https://${vars.emailsDomain}";
        markerText = "Mail Archive";
      };
    }
    ++ optional metubeEnabled {
      name = "metube";
      kind = "oauth2-proxy";
      entryUrl = "https://${vars.metubeDomain}/";
      expectedLandingUrl = "https://${vars.metubeDomain}";
      allowedGroups = [ "metube-users" ];
      localUnauthCheck = {
        host = vars.metubeDomain;
        path = "/";
        expected = [ 302 303 ];
        redirectPrefix = "https://id.${vars.domain}/ui/oauth2";
      };
      verification = {
        finalUrlPrefix = "https://${vars.metubeDomain}";
        markerText = vars.metubeDomain;
      };
    };
  accessCheckCanaries = lib.mapAttrsToList (
    accountId: canary:
    {
      inherit accountId;
      displayName = canary.displayName;
      mailAddress = canary.mailAddress;
      groups = canary.groups;
      passwordSecret = canary.passwordSecret;
      expectedApps = map (
        app:
        {
          name = app.name;
          kind = app.kind;
          expectedLandingUrl = app.expectedLandingUrl;
        }
      ) (lib.filter (app: intersects canary.groups app.allowedGroups) accessCheckApps);
    }
  ) vars.runtimeAccessCanaries;
  backupMetadataRoot = "/persist/appdata/system-state-backup/metadata";
  backupDumpsRoot = "/persist/appdata/system-state-backup/dumps";
in
{
  host = {
    hostname = vars.hostname;
    domain = vars.domain;
    lanDnsDomain = vars.lanDnsDomain;
    dnsMode = vars.dnsMode;
    serverLanIP = vars.serverLanIP;
    nbIP = vars.nbIP;
    localDnsPrivateAnswer = localDnsPrivateAnswer;
  };

  services = {
    requiredUnits =
      [
        "kanidm.service"
        "caddy.service"
        "unbound.service"
        "copyparty.service"
        "immich-server.service"
        "paperless-web.service"
        "vaultwarden.service"
        "audiobookshelf.service"
        "audiobookshelf-library-sync.timer"
        "filebrowser-quantum.service"
        "kavita.service"
        "jellyfin.service"
        "glances.service"
        "glances-oauth2-proxy.service"
      ]
      ++ optional cfg.services.cloudflared.enable "cloudflared-tunnel-${vars.cloudflareTunnelName}.service"
      ++ optional cfg.services.oauth2-proxy.enable "oauth2-proxy.service"
      ++ optional (cfg.services.netbird.clients ? myNetbirdClient) "netbird-main.service"
      ++ optional kiwixEnabled "kiwix.service"
      ++ optional kiwixEnabled "kiwix-library-watch.service"
      ++ optional kiwixEnabled "kiwix-oauth2-proxy.service"
      ++ optional mailArchiveEnabled "mail-archive-ui.service"
      ++ optional mailArchiveEnabled "mail-archive-oauth2-proxy.service"
      ++ optional metubeEnabled "metube-oauth2-proxy.service";

    edgeHttp = [
      { name = "kanidm"; url = "https://${vars.kanidmDomain}/"; expected = [ 200 303 ]; }
      { name = "uploads"; url = "https://${vars.uploadsDomain}/"; expected = [ 200 302 303 401 403 ]; }
      { name = "files"; url = "https://${vars.filebrowserDomain}/"; expected = [ 200 302 303 ]; }
      { name = "paperless"; url = "https://paperless.${vars.domain}/"; expected = [ 200 302 ]; }
      { name = "vaultwarden"; url = "https://${vars.vaultwardenDomain}/"; expected = [ 200 302 303 ]; }
      { name = "photos"; url = "https://${vars.photosDomain}/"; expected = [ 200 302 ]; }
      { name = "sharephotos"; url = "https://${vars.sharePhotosDomain}/share/healthcheck"; expected = [ 200 ]; }
      { name = "audiobooks"; url = "https://${vars.audiobooksDomain}/"; expected = [ 200 302 ]; }
      { name = "books"; url = "https://${vars.kavitaDomain}/"; expected = [ 200 302 ]; }
      { name = "monitor"; url = "https://${vars.monitorDomain}/"; expected = [ 200 302 303 401 403 ]; }
      { name = "videos"; url = "https://${vars.jellyfinDomain}/"; expected = [ 200 302 ]; }
    ]
    ++ optional kiwixEnabled { name = "kiwix"; url = "https://${vars.kiwixDomain}/"; expected = [ 200 302 ]; }
    ++ optional mailArchiveEnabled { name = "mail-archive"; url = "https://${vars.emailsDomain}/"; expected = [ 200 302 303 401 403 ]; }
    ++ optional metubeEnabled { name = "metube"; url = "https://${vars.metubeDomain}/"; expected = [ 200 302 303 401 403 ]; };

    internalHttp = [
      { name = "copyparty"; url = "http://127.0.0.1:${toString cfg.services.copyparty.settings.p}/"; expected = [ 200 302 401 403 ]; }
      { name = "filebrowser-quantum-health"; url = "http://127.0.0.1:${toString vars.filebrowserPort}/health"; expected = [ 200 ]; }
      { name = "vaultwarden"; url = "http://127.0.0.1:8222/"; expected = [ 200 302 303 ]; }
      { name = "glances-web"; url = "http://127.0.0.1:61208/"; expected = [ 200 ]; }
      { name = "sharephotos"; url = "http://127.0.0.1:3300/share/healthcheck"; expected = [ 200 ]; }
    ]
    ++ optional mailArchiveEnabled { name = "mail-archive-ui-healthz"; url = "http://127.0.0.1:${toString cfg.services.mail-archive-ui.port}/healthz"; expected = [ 200 ]; }
    ++ optional metubeEnabled { name = "metube-upstream"; url = "http://127.0.0.1:8083/"; expected = [ 200 ]; };

    dns = {
      resolve = [ "example.com" "${vars.sharePhotosDomain}" ];
      private = [
        { host = "paperless.${vars.domain}"; expected = localDnsPrivateAnswer; }
        { host = "${vars.photosDomain}"; expected = localDnsPrivateAnswer; }
        { host = "${vars.audiobooksDomain}"; expected = localDnsPrivateAnswer; }
        { host = "${vars.filebrowserDomain}"; expected = localDnsPrivateAnswer; }
        { host = "${vars.vaultwardenDomain}"; expected = localDnsPrivateAnswer; }
        { host = "${vars.kavitaDomain}"; expected = localDnsPrivateAnswer; }
        { host = "${vars.jellyfinDomain}"; expected = localDnsPrivateAnswer; }
        { host = "${vars.monitorDomain}"; expected = localDnsPrivateAnswer; }
      ]
      ++ optional kiwixEnabled { host = "${vars.kiwixDomain}"; expected = localDnsPrivateAnswer; }
      ++ optional mailArchiveEnabled { host = "${vars.emailsDomain}"; expected = localDnsPrivateAnswer; }
      ++ optional metubeEnabled { host = "${vars.metubeDomain}"; expected = localDnsPrivateAnswer; };
      splitHorizon = {
        private = [
          { host = "${vars.kanidmDomain}"; expected = vars.serverLanIP; }
          { host = "${vars.filebrowserDomain}"; expected = vars.serverLanIP; }
          { host = "${vars.uploadsDomain}"; expected = vars.serverLanIP; }
          { host = "${vars.hostname}.${vars.lanDnsDomain}"; expected = vars.serverLanIP; }
        ];
        ptr = [
          { ip = vars.serverLanIP; expected = "${vars.hostname}.${vars.lanDnsDomain}"; }
        ];
      };
      netbirdOnly = {
        public = [
          { host = "${vars.kanidmDomain}"; forbidden = vars.nbIP; }
          { host = "${vars.uploadsDomain}"; forbidden = vars.nbIP; }
        ];
      };
    };
  };

  storage = {
    systemDisk = {
      diskId = vars.mainDisk;
      device = "/dev/disk/by-id/${vars.mainDisk}";
    };
    dataPool = {
      name = vars.zfsDataPool.name;
      mountPoint = vars.zfsDataPool.mountPoint;
      datasetMounts = dataDatasetMounts;
    };
  };

  uploadAccess = {
    copyparty = {
      serviceUser = "copyparty";
      requiredGroup = "users";
      uploadRootsParent = vars.usersRoot;
      uploadSubdir = "uploads";
    };
  };

  persistence = {
    enabled = bool cfg.repo.impermanence.enablePersistence;
    directories = cfg.repo.impermanence.inventory.persistenceDirectories;
    files = cfg.repo.impermanence.inventory.persistenceFiles;
  };

  backup = {
    service = "restic-backups-system-state.service";
    timer = "restic-backups-system-state.timer";
    selectionFile = "/persist/appdata/.nixos-managed/system-state-backup-device-selection/selected-device";
    mountPoint = "/mnt/backup-system-state";
    repositoryPath = "/mnt/backup-system-state/restic/system-state";
    metadataRoot = backupMetadataRoot;
    timestampFile = "${backupMetadataRoot}/timestamp.txt";
    appStateFile = "${backupMetadataRoot}/app-state-roots.tsv";
    criticalPathsFile = "${backupMetadataRoot}/critical-paths.tsv";
    zpoolStatusFile = "${backupMetadataRoot}/zpool-status.txt";
    zpoolListFile = "${backupMetadataRoot}/zpool-list.txt";
    zfsListFile = "${backupMetadataRoot}/zfs-list.txt";
    postgresqlDumpFile = "${backupDumpsRoot}/postgresql.sql";
    maxAgeSeconds = 129600;
  };

  appState = {
    entries = appStateEntries;
    criticalPaths = [
      vars.dataRoot
      vars.paperlessRoot
      vars.immichRoot
      vars.immichManagedRoot
      vars.usersRoot
      vars.sharedRoot
      vars.sharedEmailsRoot
      vars.kiwixLibraryRoot
    ];
    requiredPaths = requiredPathEntries;
  };

  databases = {
    sqliteBinary = "${lib.getExe pkgs.sqlite}";
    sqlite = [
      { name = "paperless"; path = "/var/lib/paperless/db.sqlite3"; }
      { name = "audiobookshelf"; path = "/var/lib/audiobookshelf/config/absdatabase.sqlite"; }
      { name = "kavita"; path = "/var/lib/kavita/config/kavita.db"; }
    ]
    ++ optional mailArchiveEnabled { name = "mail-archive-ui"; path = "${cfg.services.mail-archive-ui.dataDir}/mail-archive-ui.sqlite3"; };
    postgresql = {
      enabled = bool cfg.services.postgresql.enable;
      dataDir = optionalString cfg.services.postgresql.enable cfg.services.postgresql.dataDir;
      pgIsReadyBinary =
        optionalString cfg.services.postgresql.enable "${lib.getExe' cfg.services.postgresql.finalPackage "pg_isready"}";
    };
  };

  accessChecks = {
    bootstrapStateFile = "/var/lib/runtime-access-canaries/bootstrap-state.json";
    browserHelper = "scripts/helpers/runtime-access-browser-check.mjs";
    canaries = accessCheckCanaries;
    apps = accessCheckApps;
  };

  mailArchiveFilebrowser = optionalAttrs mailArchiveEnabled {
    serviceUser = "filebrowser-quantum";
    storeRoot = cfg.services.mail-archive-ui.storeRoot;
  };
}
EOF
}

runtime_health_load_snapshot() {
  if [[ -n "${RUNTIME_HEALTH_SNAPSHOT_JSON_FILE:-}" ]]; then
    RUNTIME_HEALTH_SNAPSHOT="$(cat "${RUNTIME_HEALTH_SNAPSHOT_JSON_FILE}")"
    export RUNTIME_HEALTH_SNAPSHOT
    return 0
  fi

  RUNTIME_HEALTH_SNAPSHOT="$(nix_json "$(runtime_health_snapshot_expr)")"
  export RUNTIME_HEALTH_SNAPSHOT
}

runtime_health_snapshot_query() {
  local query="$1"
  jq -c "$query" <<<"${RUNTIME_HEALTH_SNAPSHOT}"
}

runtime_health_storage_discovery_json() {
  if [[ -n "${RUNTIME_HEALTH_STORAGE_DISCOVERY:-}" ]]; then
    printf '%s\n' "$RUNTIME_HEALTH_STORAGE_DISCOVERY"
    return 0
  fi

  local discovery_script="${RUNTIME_HEALTH_STORAGE_DISCOVERY_SCRIPT:-$repo_root/scripts/discover-storage-devices.sh}"
  RUNTIME_HEALTH_STORAGE_DISCOVERY="$(bash "$discovery_script" --format json)"
  export RUNTIME_HEALTH_STORAGE_DISCOVERY
  printf '%s\n' "$RUNTIME_HEALTH_STORAGE_DISCOVERY"
}

runtime_health_storage_discovery_query() {
  local query="$1"
  jq -c "$query" <<<"$(runtime_health_storage_discovery_json)"
}

runtime_health_append_json_line() {
  local file="$1"
  local json="$2"
  printf '%s\n' "$json" >>"$file"
}

runtime_health_mount_result_json() {
  jq -nc \
    --arg label "$1" \
    --arg target "$2" \
    --arg expectedFstype "$3" \
    --arg actualFstype "$4" \
    --arg severity "$5" \
    --arg detail "$6" \
    --argjson present "$7" \
    '{
      label: $label,
      target: $target,
      expectedFstype: $expectedFstype,
      actualFstype: $actualFstype,
      present: $present,
      severity: $severity,
      detail: $detail
    }'
}

runtime_health_check_mount_json() {
  local label="$1"
  local target="$2"
  local expected_fstype="$3"
  local actual_fstype severity detail present access_output

  actual_fstype="$(findmnt -nro FSTYPE "$target" 2>/dev/null || true)"
  if [[ "$actual_fstype" == "$expected_fstype" ]]; then
    if access_output="$(ls -d "$target" 2>&1 >/dev/null)"; then
      severity="OK"
      detail="mounted and accessible"
      present=true
    else
      severity="CRITICAL"
      detail="mounted but inaccessible: ${access_output//$'\n'/ }"
      present=false
    fi
  else
    severity="CRITICAL"
    detail="expected ${expected_fstype}, got ${actual_fstype:-missing}"
    present=false
  fi

  runtime_health_mount_result_json "$label" "$target" "$expected_fstype" "$actual_fstype" "$severity" "$detail" "$present"
}

runtime_health_timer_result_json() {
  jq -nc \
    --arg unit "$1" \
    --arg activeState "$2" \
    --arg enabledState "$3" \
    --arg severity "$4" \
    --arg detail "$5" \
    '{
      unit: $unit,
      activeState: $activeState,
      enabledState: $enabledState,
      severity: $severity,
      detail: $detail
    }'
}

runtime_health_timer_state_json() {
  local unit="$1"
  local active_state enabled_state severity detail

  active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  enabled_state="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  severity="OK"
  detail="timer active and enabled"

  if [[ "$active_state" != "active" || "$enabled_state" != "enabled" ]]; then
    severity="WARN"
    detail="active=${active_state:-unknown}, enabled=${enabled_state:-unknown}"
  fi

  runtime_health_timer_result_json "$unit" "$active_state" "$enabled_state" "$severity" "$detail"
}

runtime_health_zfs_status_json() {
  jq -nc \
    --arg statusSummary "$1" \
    --arg statusSeverity "$2" \
    --arg datasetSummary "$3" \
    --arg datasetSeverity "$4" \
    --arg healthState "$5" \
    --arg runtimeState "$6" \
    '{
      statusSummary: $statusSummary,
      statusSeverity: $statusSeverity,
      datasetSummary: $datasetSummary,
      datasetSeverity: $datasetSeverity,
      healthState: $healthState,
      runtimeState: $runtimeState
    }'
}
