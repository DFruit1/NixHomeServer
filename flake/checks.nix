{ self
, lib
, pkgs
, rustApps
, nodeApps
, nixosConfigurations
, bootstrapConfigurations
, nixhomeserverSettings
, offlineInputSources
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

  rustChecks = lib.concatMapAttrs
    (name: app:
      lib.mapAttrs'
        (checkName: check: lib.nameValuePair "${name}-${checkName}" check)
        app.checks)
    rustApps;
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
      retention = {
      }
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
  groundwater-logger = nodeApps.groundwater-logger;
  homepage = nodeApps.homepage;
  youtube-downloader = nodeApps.youtube-downloader;

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
    bash scripts/tests/run-script-tests.sh
    touch "$out"
  '';
}
  // lib.optionalAttrs (pkgs.system == hostSettings.hostPlatform) {
  # Keep the destructive layout fully evaluable/buildable in ordinary CI.
  # Running this derivation never touches disks; only `disko --mode disko` does.
  bootstrap-disko = bootstrapConfigurations."${hostName}-bootstrap".config.system.build.diskoScript;
  }
  // rustChecks
