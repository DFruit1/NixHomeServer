{ config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  hubPort = vars.networking.ports.beszelHub;
  agentPort = vars.networking.ports.beszelAgent;
  hubDataDir = "/var/lib/beszel-hub";
  agentRuntimeDir = "/run/beszel-agent";
  hubPublicKeyFile = "${agentRuntimeDir}/hub-key.pub";

  smartDevicePaths =
    map (diskId: "/dev/disk/by-id/${diskId}")
      (lib.unique ([ vars.mainDisk ] ++ vars.zfsDataPoolDiskIds));

  extraFilesystems = [
    "${vars.dataRoot}__DataPool"
    "${vars.usersRoot}__Users"
    "${vars.sharedRoot}__Shared"
    "${vars.backupRoot}__Backups"
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
    "offline-music*"
    "youtube-downloader*"
    "paperless*"
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
      install -m 0640 ${beszelConfig} ${hubDataDir}/config.yml
    '';

    systemd.services.beszel-agent = {
      wants = [ "beszel-hub.service" ];
      after = [ "beszel-hub.service" ];
      path = with pkgs; [
        coreutils
        openssh
      ];
      preStart = ''
        for _ in $(seq 1 60); do
          if [ -s ${hubDataDir}/id_ed25519 ]; then
            ssh-keygen -y -f ${hubDataDir}/id_ed25519 > ${hubPublicKeyFile}
            chmod 0444 ${hubPublicKeyFile}
            exit 0
          fi
          sleep 1
        done

        echo "Timed out waiting for Beszel hub key at ${hubDataDir}/id_ed25519" >&2
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
    allowedGroups = [ "app-admin" ];
    serviceDependencies = [ "beszel-hub.service" "caddy.service" ];
    upstreamCheck = {
      displayName = "Beszel hub";
      url = "http://${loopback}:${toString hubPort}/";
      okStatusCodes = [ "200" ];
    };
  })
]
