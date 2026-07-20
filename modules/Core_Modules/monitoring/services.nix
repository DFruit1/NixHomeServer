{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  hubPort = vars.networking.ports.beszelHub;
  agentPort = vars.networking.ports.beszelAgent;
  hubDataDir = "/var/lib/beszel-hub";
  hubPocketbaseDataDir = "${hubDataDir}/beszel_data";
  hubPrivateKeyFile = "${hubDataDir}/beszel_data/id_ed25519";
  agentRuntimeDir = "/run/beszel-agent";
  hubPublicKeyFile = "${agentRuntimeDir}/hub-key.pub";

  smartDevicePaths =
    map (diskId: "/dev/disk/by-id/${diskId}")
      (lib.unique ([ vars.mainDisk ] ++ vars.zfsDataPoolDiskIds));

  extraFilesystems =
    if vars.dataRootIsMountPoint then
      [
        "${vars.dataRoot}__DataPool"
        "${vars.usersRoot}__Users"
        "${vars.sharedRoot}__Shared"
        "${vars.backupRoot}__Backups"
        "/persist__Persist"
      ]
    else
      [
        "/__Root"
        "${vars.dataRoot}__DataRoot"
        "/persist__Persist"
      ];

  servicePatterns = [
    "caddy*"
    "kanidm*"
    "cloudflared*"
    "netbird*"
    "unbound*"
    "dnscrypt-proxy*"
    "smartd*"
    "storage-smart*"
    "data-pool-layout*"
    "kopia*"
    "syncthing*"
    "audiobookshelf*"
    "filestash*"
    "homepage*"
    "immich*"
    "jellyfin*"
    "kiwix*"
    "kavita*"
    "mail-archive-ui*"
    "offline-media*"
    "offline-music*"
    "youtube-downloader*"
    "groundwater-logger*"
    "paperless*"
    "prowlarr*"
    "qbittorrent*"
    "radarr*"
    "seerr*"
    "sonarr*"
    "vaultwarden*"
    "postgresql*"
    "redis-*"
    "*oauth2-proxy*"
    "beszel*"
  ];

  beszelConfig = pkgs.writeText "beszel-config.yml" ''
    systems:
      - name: ${vars.hostname}
        host: ${loopback}
        port: ${toString agentPort}
        users:
          - ${vars.kanidmAdminEmail}
  '';
in
lib.mkMerge [
  {
    services.beszel.hub = {
      enable = true;
      host = loopback;
      port = hubPort;
      dataDir = hubDataDir;
      environment = {
        APP_URL = "https://${vars.monitorDomain}";
        CHECK_UPDATES = "false";
        CONTAINER_DETAILS = "false";
        # The OAuth2 proxy is the external access boundary, while Beszel keeps
        # its own login. Trusting an ordinary forwarded-email header would let
        # any compromised local process impersonate an administrator by
        # connecting directly to this loopback listener.
        DISABLE_PASSWORD_AUTH = "false";
        USER_CREATION = "true";
        USER_EMAIL = vars.kanidmAdminEmail;
      };
      environmentFile = config.age.secrets.beszelHubEnv.path;
    };

    services.beszel.agent = {
      enable = true;
      openFirewall = false;
      smartmon = {
        enable = true;
        deviceAllow = smartDevicePaths;
      };
      environment = {
        LISTEN = "${loopback}:${toString agentPort}";
        KEY_FILE = hubPublicKeyFile;
        SYSTEM_NAME = vars.hostname;
        DISK_USAGE_CACHE = "15m";
        SMART_INTERVAL = "1h";
        SMART_DEVICES = lib.concatStringsSep "," smartDevicePaths;
        EXTRA_FILESYSTEMS = lib.concatStringsSep "," extraFilesystems;
        SERVICE_PATTERNS = lib.concatStringsSep "," servicePatterns;
      };
    };

    systemd.services.beszel-hub.preStart = ''
      install -d -m 0750 -o beszel-hub -g beszel-hub ${hubPocketbaseDataDir}
      install -m 0640 -o beszel-hub -g beszel-hub ${beszelConfig} ${hubPocketbaseDataDir}/config.yml
    '';

    users.groups.beszel-hub = { };
    users.users.beszel-hub = {
      isSystemUser = true;
      group = "beszel-hub";
      home = hubDataDir;
    };

    systemd.services.beszel-hub.serviceConfig.DynamicUser = lib.mkForce false;

    systemd.services.beszel-agent = {
      wants = [ "beszel-hub.service" ];
      after = [ "beszel-hub.service" ];
      path = with pkgs; [
        coreutils
        openssh
      ];
      preStart = ''
        for _ in $(seq 1 60); do
          if [ -s ${hubPrivateKeyFile} ]; then
            ssh-keygen -y -f ${hubPrivateKeyFile} > ${hubPublicKeyFile}
            chmod 0444 ${hubPublicKeyFile}
            exit 0
          fi
          sleep 1
        done

        echo "Timed out waiting for Beszel hub key at ${hubPrivateKeyFile}" >&2
        exit 1
      '';
      serviceConfig = {
        PermissionsStartOnly = true;
        RuntimeDirectory = "beszel-agent";
      };
    };
  }

  (oauth2Proxy.mkSidecarService {
    serviceName = "monitor-oauth2-proxy";
    description = "OAuth2 Proxy for Beszel Monitor";
    clientId = "monitor-web";
    clientSecretFile = config.age.secrets.monitorOauth2ProxyClientSecret.path;
    cookieSecretFile = config.age.secrets.monitorOauth2ProxyCookieSecret.path;
    cookieName = "_oauth2_proxy_monitor";
    domain = vars.monitorDomain;
    port = vars.networking.ports.oauth2ProxyMonitor;
    upstream = "http://${loopback}:${toString hubPort}";
    allowedGroups = [ vars.monitoringAccessGroup ];
    serviceDependencies = [ "beszel-hub.service" "caddy.service" ];
    upstreamCheck = {
      displayName = "Beszel hub";
      url = "http://${loopback}:${toString hubPort}/";
      okStatusCodes = [ "200" ];
    };
  })
]
