{ config, lib, pkgs, vars, ... }:

let
  cfg = vars.phoneBackup or { enable = false; };
  enabled = cfg.enable or false;
  sources = cfg.sources or { };
  syncthing = cfg.syncthing or { };
  placeholderDeviceId = "REPLACE_WITH_SYNCTHING_FORK_DEVICE_ID";
  backupStorageAccessGroup = vars.backupAccess.storageGroup or "backup-admin";
  backupStorageAccessGid = vars.fileAccessPosixGids.${backupStorageAccessGroup};
  stateDir = cfg.stateDir or "/persist/appdata/kopia-phone";
  cacheDir = "${stateDir}/cache";
  logDir = "${stateDir}/logs";
  configFile = "${stateDir}/repository.config";
  repositoryPath = cfg.repositoryPath or "${vars.backupRoot}/kopia-phone";
  maxRepositoryBytes = cfg.maxRepositoryBytes or (75 * 1024 * 1024 * 1024);
  minimumSuccessfulSnapshots = cfg.minimumSuccessfulSnapshots or 7;
  compression = cfg.compression or "zstd";
  includePersist = sources.includePersist or true;
  extraPaths = sources.extraPaths or [ ];
  excludePatterns = sources.excludePatterns or [ ];
  snapshotSources =
    (lib.optional includePersist {
      path = "/persist";
      tag = "persist";
      description = "/persist phone-scoped automatic snapshot";
    })
    ++ (map
      (path: {
        inherit path;
        tag = "extra";
        description = "phone-scoped automatic snapshot for ${path}";
      })
      extraPaths);
  policyIgnoreArgs = lib.concatMapStringsSep " "
    (pattern: "--add-ignore=${lib.escapeShellArg pattern}")
    excludePatterns;
  snapshotCommands = lib.concatMapStringsSep "\n\n"
    (source: ''
      if [[ ! -e ${lib.escapeShellArg source.path} ]]; then
        echo "phone backup source is missing: ${source.path}" >&2
        exit 1
      fi

      kopia snapshot create \
        --no-progress \
        --description=${lib.escapeShellArg source.description} \
        --tags=target:phone \
        --tags=source:${lib.escapeShellArg source.tag} \
        ${lib.escapeShellArg source.path}
    '')
    snapshotSources;
  commonPath = with pkgs; [
    acl
    coreutils
    findutils
    jq
    kopia
  ];
  credentials = {
    phonePassword = "kopia-phone-password";
  };
in
{
  config = lib.mkIf enabled {
    assertions = [
      {
        assertion = (syncthing.deviceId or placeholderDeviceId) != placeholderDeviceId;
        message = "nixhomeserver: vars.phoneBackup.syncthing.deviceId must be replaced before phoneBackup.enable is set.";
      }
      {
        assertion = snapshotSources != [ ];
        message = "nixhomeserver: phoneBackup requires at least one source.";
      }
    ];

    users.groups.${backupStorageAccessGroup}.gid = backupStorageAccessGid;

    systemd.tmpfiles.rules = [
      "d ${stateDir} 0700 root root -"
      "d ${cacheDir} 0700 root root -"
      "d ${logDir} 0700 root root -"
      "d ${repositoryPath} 0750 root ${toString backupStorageAccessGid} -"
      "a ${repositoryPath} - - - - u:syncthing:r-X,g:${toString backupStorageAccessGid}:r-X"
    ];

    systemd.services.kopia-phone-repository-bootstrap = {
      description = "Create or connect the phone-scoped Kopia repository";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "data-pool-layout.service"
        "kanidm-files-posix-groups.service"
      ];
      after = [
        "data-pool-layout.service"
        "kanidm-files-posix-groups.service"
      ];
      path = commonPath;
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [
          "${credentials.phonePassword}:${config.age.secrets.kopiaPhonePassword.path}"
        ];
      };
      script = ''
        set -euo pipefail

        password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.phonePassword}")"
        export KOPIA_CHECK_FOR_UPDATES=false
        export KOPIA_PASSWORD="$password"
        export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
        export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

        install -d -m 0700 ${lib.escapeShellArg stateDir} ${lib.escapeShellArg cacheDir} ${lib.escapeShellArg logDir}
        install -d -m 0750 -o root -g ${lib.escapeShellArg (toString backupStorageAccessGid)} ${lib.escapeShellArg repositoryPath}

        if [[ -f ${lib.escapeShellArg configFile} ]]; then
          storage_type="$(jq -r '.storage.type // empty' ${lib.escapeShellArg configFile} 2>/dev/null || true)"
          storage_path="$(jq -r '.storage.config.path // .storage.path // empty' ${lib.escapeShellArg configFile} 2>/dev/null || true)"
          if [[ "$storage_type" != "filesystem" || "$storage_path" != ${lib.escapeShellArg repositoryPath} ]]; then
            mv ${lib.escapeShellArg configFile} ${lib.escapeShellArg configFile}."legacy-$(date -u +%Y%m%dT%H%M%SZ)"
          fi
        fi

        if [[ ! -f ${lib.escapeShellArg configFile} ]]; then
          if [[ -f ${lib.escapeShellArg repositoryPath}/kopia.repository.f ]]; then
            kopia repository connect filesystem \
              --path=${lib.escapeShellArg repositoryPath} \
              --config-file=${lib.escapeShellArg configFile} \
              --cache-directory=${lib.escapeShellArg cacheDir} \
              --password="$password" \
              --persist-credentials \
              --no-use-keyring
          else
            kopia repository create filesystem \
              --path=${lib.escapeShellArg repositoryPath} \
              --config-file=${lib.escapeShellArg configFile} \
              --cache-directory=${lib.escapeShellArg cacheDir} \
              --password="$password" \
              --persist-credentials \
              --no-use-keyring \
              --description="NixHomeServer phone backup seed repository" \
              --owner-uid=0 \
              --owner-gid=${lib.escapeShellArg (toString backupStorageAccessGid)} \
              --file-mode=0640 \
              --dir-mode=0750
          fi
        fi

        kopia policy set \
          --global \
          --compression=${lib.escapeShellArg compression} \
          --metadata-compression=zstd-fastest \
          --clear-ignore \
          ${policyIgnoreArgs} \
          --ignore-cache-dirs=true \
          --ignore-identical-snapshots=true \
          --keep-latest=30 \
          --keep-daily=30 \
          --keep-weekly=8 \
          --keep-monthly=12

        chown -R root:${lib.escapeShellArg (toString backupStorageAccessGid)} ${lib.escapeShellArg repositoryPath}
        chmod 0750 ${lib.escapeShellArg repositoryPath}
        setfacl -R -m u:syncthing:r-X,g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-X ${lib.escapeShellArg repositoryPath}
        find ${lib.escapeShellArg repositoryPath} -type d -exec setfacl -m d:u:syncthing:r-x,d:g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-x '{}' +
      '';
    };

    systemd.services.kopia-phone-snapshot = {
      description = "Create an encrypted phone-scoped Kopia snapshot";
      wants = [ "kopia-phone-repository-bootstrap.service" ];
      after = [ "kopia-phone-repository-bootstrap.service" ];
      path = commonPath;
      serviceConfig = {
        Type = "oneshot";
        LoadCredential = [
          "${credentials.phonePassword}:${config.age.secrets.kopiaPhonePassword.path}"
        ];
        Nice = 10;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
      };
      script = ''
        set -euo pipefail

        if [[ ! -d /persist ]]; then
          echo "phone backup requires /persist to be mounted" >&2
          exit 1
        fi

        password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/${credentials.phonePassword}")"
        export KOPIA_CHECK_FOR_UPDATES=false
        export KOPIA_PASSWORD="$password"
        export KOPIA_CONFIG_PATH=${lib.escapeShellArg configFile}
        export KOPIA_CACHE_DIRECTORY=${lib.escapeShellArg cacheDir}

        ${snapshotCommands}

        kopia maintenance run --full --no-progress

        repo_bytes="$(du -sb ${lib.escapeShellArg repositoryPath} | awk '{print $1}')"
        snapshot_count="$(
          kopia snapshot list --all --json --tags=target:phone \
            | jq '[.. | objects | select(has("startTime") or has("manifestID") or has("id"))] | length'
        )"

        if (( repo_bytes > ${toString maxRepositoryBytes} )); then
          if (( snapshot_count < ${toString minimumSuccessfulSnapshots} )); then
            echo "phone Kopia repository is over ${toString maxRepositoryBytes} bytes before ${toString minimumSuccessfulSnapshots} successful snapshots exist: $repo_bytes bytes" >&2
          else
            echo "phone Kopia repository exceeds configured soft cap: $repo_bytes > ${toString maxRepositoryBytes} bytes" >&2
          fi
          exit 1
        fi

        setfacl -R -m u:syncthing:r-X,g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-X ${lib.escapeShellArg repositoryPath}
        find ${lib.escapeShellArg repositoryPath} -type d -exec setfacl -m d:u:syncthing:r-x,d:g:${lib.escapeShellArg (toString backupStorageAccessGid)}:r-x '{}' +
      '';
    };

    systemd.services.kopia-persist-snapshot.unitConfig.OnSuccess = [ "kopia-phone-snapshot.service" ];

    services.syncthing = {
      settings = {
        devices.${syncthing.deviceName}.id = syncthing.deviceId;

        folders.${syncthing.folderId} = {
          path = repositoryPath;
          devices = [ syncthing.deviceName ];
          type = "sendonly";
          fsWatcherEnabled = false;
          rescanIntervalS = 3600;
        };
      };
    };
  };
}
