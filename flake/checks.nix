{ self
, lib
, pkgs
, rustApps
, nodeApps
, nixosConfigurations
, bootstrapConfigurations
, nixhomeserverSettings
, offlineInputSources
, enabledApps
, testAllApps ? false
}:

let
  checkNativeBuildInputs = with pkgs; [
    bash
    age
    coreutils
    findutils
    gawk
    gitMinimal
    getent
    gnugrep
    gnused
    gnutar
    jq
    nix
    nodejs
    openssl
    python3
    ripgrep
    sqlite
    util-linux
  ];

  hasApp = name: builtins.elem name enabledApps;
  rustAppOwners = {
    browsertrix-downloader = "browsertrix-downloader";
    kanidm-canary-bootstrap = null;
    mail-archive-ui = "mail-archive-ui";
    media-manager = null;
    mkvmaker = "mkvmaker";
  };
  selectedRustApps = lib.filterAttrs
    (name: _: rustAppOwners.${name} == null || hasApp rustAppOwners.${name})
    rustApps;
  rustChecks = lib.concatMapAttrs
    (name: app:
      lib.mapAttrs'
        (checkName: check: lib.nameValuePair "${name}-${checkName}" check)
        app.checks)
    selectedRustApps;
  hostName = builtins.head (builtins.attrNames nixosConfigurations);
  hostConfig = nixosConfigurations.${hostName}.config;
  hostModules = hostConfig.nixhomeserver.modules;
  hostSettings = removeAttrs nixhomeserverSettings.${hostName} [
    "kanidmIssuer"
    "kanidmDiscoveryUrl"
  ];
  cloudflaredTunnel = hostConfig.services.cloudflared.tunnels.${hostSettings.cloudflareTunnelName};
  secretManifest = import ../secrets/manifest.nix;
  inventoryJson = builtins.toJSON {
    schemaVersion = 2;
    host = hostName;
    settings = hostSettings;
    network = {
      caddyHosts = builtins.attrNames hostConfig.services.caddy.virtualHosts;
      cloudflaredHosts = builtins.attrNames cloudflaredTunnel.ingress;
      privateDnsHosts = hostConfig.services.unbound.privateHosts;
      ports = hostSettings.networking.ports;
    };
    identity = {
      kanidmGroups = builtins.attrNames hostConfig.services.kanidm.provision.groups;
      oauthClients = builtins.attrNames hostConfig.services.kanidm.provision.systems.oauth2;
    };
    storage = {
      profile = hostSettings.storageProfile;
      rootFsType = hostConfig.fileSystems."/".fsType;
      requiresZfs = hostSettings.enableZfsDataPool;
      dataRootIsMountPoint = hostSettings.dataRootIsMountPoint;
      dataRoot = hostSettings.dataRoot;
      usersRoot = hostSettings.usersRoot;
      sharedRoot = hostSettings.sharedRoot;
      backupRoot = hostSettings.backupRoot;
      dataPool = hostSettings.zfsDataPool;
      userContentSubdirs = hostConfig.repo.storage.userRoots.contentSubdirs;
      sharedContentSubdirs = hostConfig.repo.storage.sharedRoots.contentSubdirs;
    };
    backups = {
      inherit (hostConfig.repo.backups)
        appStateEntries
        criticalPaths
        pathInventories
        sqliteDumps
        postgresqlDumps
        successfulCurrentPath
        successfulGenerationRoot
        retainedSuccessfulGenerations
        minimumFreeBytes;
      retention = { }
        // lib.optionalAttrs (hostModules."groundwater-logger" or false) {
        groundwaterLogger = hostConfig.repo.groundwaterLogger.retention;
      }
        // lib.optionalAttrs (hostModules."youtube-downloader" or false) {
        youtubeDownloaderEventDays = hostConfig.repo.youtubeDownloader.eventRetentionDays;
      };
    };
    impermanence = {
      directories = hostConfig.repo.impermanence.inventory.persistenceDirectories;
      files = hostConfig.repo.impermanence.inventory.persistenceFiles;
    };
    secrets = {
      ageSecretNames = builtins.attrNames hostConfig.age.secrets;
      externalSecretNames = builtins.attrNames secretManifest.externalSecrets;
      requiredExternalSecretNames = builtins.attrNames (
        lib.filterAttrs (_: spec: spec.required or true) secretManifest.externalSecrets
      );
      optionalExternalSecretNames = builtins.attrNames (
        lib.filterAttrs (_: spec: !(spec.required or true)) secretManifest.externalSecrets
      );
    };
    systemd = {
      serviceNames = builtins.attrNames hostConfig.systemd.services;
    };
  };
  inventoryJsonFile = pkgs.writeText "nixhomeserver-inventory.json" inventoryJson;
  archiveViewHelper =
    if hostModules.files or false then
      hostConfig.systemd.services.files-archives-sync.environment.ARCHIVE_VIEW_HELPER
    else
      null;
  offlineInputSourcesFile = pkgs.writeText
    "nixhomeserver-offline-flake-inputs.json"
    (builtins.toJSON offlineInputSources);
in
{
  media-manager-package = rustApps.media-manager.package;

  shellcheck = pkgs.runCommand "shellcheck"
    {
      nativeBuildInputs = with pkgs; [
        shellcheck
      ];
    } ''
    cd ${self}
    shellcheck -x -e SC1091,SC2016,SC2154,SC2029 scripts/*.sh scripts/helpers/*.sh scripts/admin/*.sh scripts/tests/*.sh bootstrap/*.sh
    touch "$out"
  '';

  deadnix = pkgs.runCommand "deadnix"
    {
      nativeBuildInputs = with pkgs; [
        deadnix
      ];
    } ''
    cd ${self}
    deadnix --fail .
    touch "$out"
  '';

  statix = pkgs.runCommand "statix"
    {
      nativeBuildInputs = with pkgs; [
        statix
      ];
    } ''
    cd ${self}
    statix check .
    touch "$out"
  '';

  repo-policy = pkgs.runCommand "repo-policy"
    ({
      nativeBuildInputs = checkNativeBuildInputs;
      NIXHOMESERVER_DEFAULT_HOST = hostName;
      NIXHOMESERVER_INVENTORY_JSON_FILE = inventoryJsonFile;
      NIXHOMESERVER_SKIP_NESTED_BUILDS = "1";
      NIXHOMESERVER_TEST_ALL_APPS = if testAllApps then "1" else "0";
    } // lib.optionalAttrs (archiveViewHelper != null) {
      NIXHOMESERVER_ARCHIVE_VIEW_HELPER = archiveViewHelper;
    }) ''
    export HOME="$TMPDIR"
    export NIX_CONFIG="experimental-features = nix-command flakes
    accept-flake-config = true"
    cp -R ${self} "$TMPDIR/source"
    chmod -R u+w "$TMPDIR/source"
    cd "$TMPDIR/source"
    jq --slurpfile sources ${offlineInputSourcesFile} '
      reduce ($sources[0] | to_entries[]) as $source (.;
        if .nodes[$source.key] == null then
          error("offline input mapping references missing lock node: " + $source.key)
        else
          .nodes[$source.key].locked as $locked
          | .nodes[$source.key].locked = ({
              type: "path",
              path: $source.value.path,
              narHash: $source.value.narHash,
              lastModified: ($locked.lastModified // 0)
            } + if $locked.rev == null then {} else { rev: $locked.rev } end)
        end
      )
      | ([.nodes | keys[] | select(. != "root")] - ($sources[0] | keys)) as $unmapped
      | if $unmapped == [] then .
        else error("offline input mapping is missing lock nodes: " + ($unmapped | join(", ")))
        end
    ' flake.lock >flake.lock.offline
    mv flake.lock.offline flake.lock
    bash scripts/tests/run-script-tests.sh ${lib.optionalString testAllApps "--all-apps"}
    touch "$out"
  '';

  kopia-restore-roundtrip = pkgs.runCommand "kopia-restore-roundtrip"
    {
      nativeBuildInputs = with pkgs; [ bash coreutils diffutils jq kopia ];
    } ''
    set -euo pipefail
    for tool in cmp diff jq kopia readlink; do
      if ! command -v "$tool" >/dev/null 2>&1; then
        echo "❌ Missing restore-test dependency: $tool" >&2
        exit 1
      fi
    done

    test_root="$(mktemp -d)"
    cleanup() {
      rm -rf "$test_root"
    }
    trap cleanup EXIT

    repository="$test_root/repository"
    source_root="$test_root/source"
    restore_root="$test_root/restored"
    config_file="$test_root/repository.config"

    mkdir -p "$repository" "$source_root/nested" "$test_root/cache" "$test_root/log"
    printf 'NixHomeServer restore fixture\n' >"$source_root/important.txt"
    printf '\x00\x01\x02\xffbinary\n' >"$source_root/nested/binary.dat"
    printf 'target contents\n' >"$source_root/nested/target.txt"
    ln -s nested/target.txt "$source_root/link-to-target"
    chmod 0640 "$source_root/important.txt"

    export KOPIA_PASSWORD='nixhomeserver-restore-roundtrip-test'
    export KOPIA_CONFIG_PATH="$config_file"
    export KOPIA_CACHE_DIRECTORY="$test_root/cache"
    export KOPIA_LOG_DIR="$test_root/log"
    export KOPIA_CHECK_FOR_UPDATES=false
    export KOPIA_PERSIST_CREDENTIALS_ON_CONNECT=false

    kopia repository create filesystem \
      --path "$repository" \
      --disable-file-logging \
      --no-persist-credentials >/dev/null
    kopia snapshot create "$source_root" \
      --disable-file-logging \
      --no-progress >/dev/null

    snapshot_json="$(kopia snapshot list "$source_root" --json --disable-file-logging)"
    root_object="$(jq -er '.[0].rootEntry.obj | select(type == "string" and length > 0)' <<<"$snapshot_json")"

    # Reconnect from a fresh client configuration so this checks repository
    # recovery, not merely reuse of the snapshotting process's local state.
    kopia repository disconnect --disable-file-logging >/dev/null
    rm -f "$config_file"
    rm -rf "$test_root/cache"
    mkdir "$test_root/cache"
    kopia repository connect filesystem \
      --path "$repository" \
      --disable-file-logging \
      --no-persist-credentials >/dev/null
    kopia snapshot restore "$root_object" "$restore_root" \
      --disable-file-logging \
      --no-progress >/dev/null

    diff --recursive --no-dereference "$source_root" "$restore_root"
    cmp "$source_root/nested/binary.dat" "$restore_root/nested/binary.dat"
    [[ "$(readlink "$restore_root/link-to-target")" == 'nested/target.txt' ]]
    [[ "$(stat -c '%a' "$restore_root/important.txt")" == 640 ]]

    echo "✅ Kopia snapshot reconnect-and-restore round trip passed."
    touch "$out"
  '';
}
// lib.optionalAttrs (pkgs.system == hostSettings.hostPlatform) {
  # Keep the destructive layout fully evaluable/buildable in ordinary CI.
  # Running this derivation never touches disks; only `disko --mode disko` does.
  bootstrap-disko = bootstrapConfigurations."${hostName}-bootstrap".config.system.build.diskoScript;
}
// lib.optionalAttrs (hasApp "groundwater-logger") {
  groundwater-logger = nodeApps.groundwater-logger;
}
// {
  homepage = nodeApps.homepage;
}
// lib.optionalAttrs (hasApp "mkvmaker") {
  mkvmaker-package = rustApps.mkvmaker.package;
}
// lib.optionalAttrs (hasApp "browsertrix-downloader") {
  browsertrix-downloader = rustApps.browsertrix-downloader.package;
}
// lib.optionalAttrs (hasApp "youtube-downloader") {
  youtube-downloader = nodeApps.youtube-downloader;
}
  // rustChecks
