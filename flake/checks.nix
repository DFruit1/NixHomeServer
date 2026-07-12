{ self
, lib
, pkgs
, rustApps
, nodeApps
, nixosConfigurations
, nixhomeserverSettings
}:

let
  checkNativeBuildInputs = with pkgs; [
    bash
    coreutils
    findutils
    gitMinimal
    getent
    gnugrep
    gnused
    gnutar
    jq
    nix
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
  hostSettings = removeAttrs nixhomeserverSettings.${hostName} [
    "kanidmIssuer"
    "kanidmDiscoveryUrl"
  ];
  cloudflaredTunnel = hostConfig.services.cloudflared.tunnels.${hostSettings.cloudflareTunnelName};
  secretManifest = import ../secrets/manifest.nix;
  inventoryJson = builtins.toJSON {
    schemaVersion = 1;
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
        sqliteDumps;
    };
    impermanence = {
      directories = hostConfig.repo.impermanence.inventory.persistenceDirectories;
      files = hostConfig.repo.impermanence.inventory.persistenceFiles;
    };
    secrets = {
      ageSecretNames = builtins.attrNames hostConfig.age.secrets;
      externalSecretNames = builtins.attrNames secretManifest.externalSecrets;
    };
    systemd = {
      serviceNames = builtins.attrNames hostConfig.systemd.services;
    };
  };
  inventoryJsonFile = pkgs.writeText "nixhomeserver-inventory.json" inventoryJson;
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
    {
      nativeBuildInputs = checkNativeBuildInputs;
      NIXHOMESERVER_DEFAULT_HOST = hostName;
      NIXHOMESERVER_INVENTORY_JSON_FILE = inventoryJsonFile;
    } ''
    export HOME="$TMPDIR"
    export NIX_CONFIG="experimental-features = nix-command flakes"
    cp -R ${self} "$TMPDIR/source"
    chmod -R u+w "$TMPDIR/source"
    cd "$TMPDIR/source"
    bash scripts/tests/run-script-tests.sh
    touch "$out"
  '';
}
  // rustChecks
