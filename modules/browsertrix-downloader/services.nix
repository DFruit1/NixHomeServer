{ appPackages, config, lib, oauth2Proxy, pkgs, vars, ... }:

let
  cfg = config.repo.browsertrixDownloader;
  paths = cfg.paths;
  package = appPackages.browsertrix-downloader;
  listenAddress = vars.networking.loopbackIPv4;
  listenPort = vars.networking.ports.browsertrixDownloader;
  host = "archives.${vars.domain}";
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  oauthCookieSecretSource = config.age.secrets.browsertrixDownloaderOauth2ProxyCookieSecret.path;
  oauthRuntimeDirectoryName = "browsertrix-downloader-oauth2-proxy";
  oauthRuntimeDirectory = "/run/${oauthRuntimeDirectoryName}";
  oauthCookieSecretFile = "${oauthRuntimeDirectory}/cookie-secret";
  commonEnvironment = {
    BROWSERTRIX_DOWNLOADER_HOST = listenAddress;
    BROWSERTRIX_DOWNLOADER_PORT = toString listenPort;
    BROWSERTRIX_DOWNLOADER_STATE_DIR = paths.stateDir;
    BROWSERTRIX_DOWNLOADER_DATABASE = "${paths.stateDir}/browsertrix-downloader.sqlite";
    BROWSERTRIX_DOWNLOADER_CRAWLS_DIR = paths.crawlsRoot;
    BROWSERTRIX_DOWNLOADER_ARCHIVE_ROOT = paths.archiveRoot;
    BROWSERTRIX_DOWNLOADER_FRONTEND_DIR = "${package}/share/browsertrix-downloader/client";
    BROWSERTRIX_DOWNLOADER_REPLAY_DIR = "${package}/share/browsertrix-downloader/replay";
    BROWSERTRIX_DOWNLOADER_EVENT_RETENTION_DAYS = toString cfg.eventRetentionDays;
    RUST_BACKTRACE = "1";
  };
  workerLauncher = pkgs.writeShellScript "browsertrix-downloader-worker-launch" ''
    set -euo pipefail

    archive_uid="$(${pkgs.coreutils}/bin/id -u)"
    archive_gid="$(${pkgs.getent}/bin/getent group ${lib.escapeShellArg sharedAccessGroup} | ${pkgs.coreutils}/bin/cut -d: -f3)"
    if [[ -z "$archive_gid" ]]; then
      echo "Could not resolve archive group ${lib.escapeShellArg sharedAccessGroup}" >&2
      exit 1
    fi
    export BROWSERTRIX_DOWNLOADER_ARCHIVE_UID="$archive_uid"
    export BROWSERTRIX_DOWNLOADER_ARCHIVE_GID="$archive_gid"
    exec ${lib.getExe' package "browsertrix-downloader-worker"}
  '';
  egressPolicy = pkgs.writeShellScript "browsertrix-downloader-egress-policy" ''
    set -euo pipefail

    worker_uid="$(${pkgs.coreutils}/bin/id -u browsertrix-downloader-worker)"
    ${pkgs.nftables}/bin/nft delete table inet browsertrix_downloader_egress 2>/dev/null || true
    ${pkgs.nftables}/bin/nft -f - <<EOF
    table inet browsertrix_downloader_egress {
      chain output {
        type filter hook output priority filter; policy accept;
        meta skuid $worker_uid ip daddr { ${vars.networking.loopbackIPv4Cidr}, ${vars.networking.lan.gateway}/32 } meta l4proto { tcp, udp } th dport 53 accept
        meta skuid $worker_uid fib daddr type local reject
        meta skuid $worker_uid ip daddr { 0.0.0.0/8, 10.0.0.0/8, 100.64.0.0/10, 127.0.0.0/8, 169.254.0.0/16, 172.16.0.0/12, 192.0.0.0/24, 192.0.2.0/24, 192.168.0.0/16, 198.18.0.0/15, 198.51.100.0/24, 203.0.113.0/24, 224.0.0.0/4, 240.0.0.0/4 } reject with icmp type admin-prohibited
        meta skuid $worker_uid ip6 daddr { ::/128, ::1/128, ::ffff:0:0/96, 64:ff9b::/96, 100::/64, 2001:db8::/32, fc00::/7, fe80::/10, ff00::/8 } reject with icmpv6 type admin-prohibited
      }
    }
    EOF
  '';
  removeEgressPolicy = pkgs.writeShellScript "browsertrix-downloader-remove-egress-policy" ''
    ${pkgs.nftables}/bin/nft delete table inet browsertrix_downloader_egress 2>/dev/null || true
  '';
  prepareOauthCookieSecret = pkgs.writeShellScript "browsertrix-downloader-oauth2-cookie-secret" ''
    set -euo pipefail

    temporary="$(${pkgs.coreutils}/bin/mktemp ${lib.escapeShellArg "${oauthRuntimeDirectory}/.cookie-secret.XXXXXX"})"
    trap '${pkgs.coreutils}/bin/rm -f "$temporary"' EXIT
    ${pkgs.openssl}/bin/openssl dgst -sha256 -binary \
      ${lib.escapeShellArg oauthCookieSecretSource} > "$temporary"
    test "$(${pkgs.coreutils}/bin/wc -c < "$temporary")" -eq 32
    ${pkgs.coreutils}/bin/chmod 0400 "$temporary"
    ${pkgs.coreutils}/bin/mv -f "$temporary" ${lib.escapeShellArg oauthCookieSecretFile}
    trap - EXIT
  '';
in
{
  options.repo.browsertrixDownloader = {
    eventRetentionDays = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Retention period for terminal crawl event history.";
    };

    crawlerImage = lib.mkOption {
      type = lib.types.strMatching ".+@sha256:[0-9a-f]{64}";
      default = "docker.io/webrecorder/browsertrix-crawler:1.14.3@sha256:7f9d5e20e0f6efea2e9e257aa37e536495ac9f33422ab886e446dabf1065af2c";
      description = "Browsertrix Crawler OCI image pinned to an immutable manifest digest.";
    };
  };

  config = lib.mkMerge [
    {
      virtualisation.podman.enable = true;

      systemd.services.browsertrix-downloader-egress-policy = {
        description = "Block Browsertrix crawler access to private network ranges";
        wantedBy = [ "multi-user.target" ];
        before = [ "browsertrix-downloader-worker.service" ];
        after = [ "systemd-sysusers.service" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = egressPolicy;
          ExecStop = removeEgressPolicy;
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          RestrictAddressFamilies = [ "AF_NETLINK" ];
        };
      };

      systemd.services.browsertrix-downloader = {
        description = "Authenticated Browsertrix archive API";
        wantedBy = [ "multi-user.target" ];
        requires = [ "browsertrix-downloader-storage-layout-v1.service" ];
        wants = [ "network-online.target" ];
        after = [
          "network-online.target"
          "browsertrix-downloader-storage-layout-v1.service"
        ];
        unitConfig = {
          StartLimitIntervalSec = "5min";
          StartLimitBurst = 5;
          RequiresMountsFor = [ vars.dataRoot ];
        };
        environment = commonEnvironment;
        serviceConfig = {
          Type = "simple";
          User = "browsertrix-downloader";
          Group = "browsertrix-downloader";
          SupplementaryGroups = [ sharedAccessGroup ];
          ExecStart = lib.getExe' package "browsertrix-downloader";
          Restart = "on-failure";
          RestartSec = "5s";
          TimeoutStartSec = "60s";
          TimeoutStopSec = "20s";
          MemoryHigh = "512M";
          MemoryMax = "1G";
          OOMPolicy = "stop";
          UMask = "0007";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectClock = true;
          ProtectControlGroups = true;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          LockPersonality = true;
          RestrictSUIDSGID = true;
          RestrictNamespaces = true;
          RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
          SystemCallArchitectures = "native";
          ReadWritePaths = [ paths.stateRoot ];
          ReadOnlyPaths = [ paths.archiveRoot ];
        };
      };

      systemd.services.browsertrix-downloader-worker = {
        description = "Rootless Browsertrix crawl worker";
        wantedBy = [ "multi-user.target" ];
        requires = [
          "browsertrix-downloader-storage-layout-v1.service"
          "browsertrix-downloader-egress-policy.service"
        ];
        wants = [ "network-online.target" "unbound.service" ];
        after = [
          "network-online.target"
          "unbound.service"
          "browsertrix-downloader-storage-layout-v1.service"
          "browsertrix-downloader-egress-policy.service"
        ];
        unitConfig = {
          StartLimitIntervalSec = "10min";
          StartLimitBurst = 4;
          RequiresMountsFor = [ vars.dataRoot ];
        };
        path = [ "/run/wrappers" pkgs.podman pkgs.shadow pkgs.slirp4netns ];
        environment = commonEnvironment // {
          BROWSERTRIX_DOWNLOADER_PODMAN_BIN = lib.getExe pkgs.podman;
          BROWSERTRIX_DOWNLOADER_CRAWLER_IMAGE = cfg.crawlerImage;
          BROWSERTRIX_DOWNLOADER_WORKER_POLL_SECONDS = "3";
          HOME = paths.workerHome;
          XDG_CONFIG_HOME = "${paths.workerHome}/.config";
          XDG_DATA_HOME = "${paths.workerHome}/.local/share";
          XDG_RUNTIME_DIR = "/run/browsertrix-downloader-worker";
        };
        serviceConfig = {
          Type = "simple";
          User = "browsertrix-downloader-worker";
          Group = "browsertrix-downloader";
          SupplementaryGroups = [ sharedAccessGroup ];
          ExecStart = workerLauncher;
          Restart = "on-failure";
          RestartSec = "15s";
          TimeoutStartSec = "30min";
          TimeoutStopSec = "45s";
          RuntimeDirectory = "browsertrix-downloader-worker";
          RuntimeDirectoryMode = "0700";
          Delegate = true;
          MemoryHigh = "4G";
          MemoryMax = "6G";
          OOMPolicy = "stop";
          UMask = "0007";
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ProtectClock = true;
          ProtectControlGroups = false;
          ProtectHostname = true;
          ProtectKernelLogs = true;
          ProtectKernelModules = true;
          ProtectKernelTunables = true;
          LockPersonality = true;
          PrivateDevices = false;
          SystemCallArchitectures = "native";
          ReadWritePaths = [
            paths.stateRoot
            paths.cacheRoot
            paths.archiveRoot
          ];
        };
      };

      systemd.services.browsertrix-downloader-oauth2-cookie-secret = {
        description = "Prepare Browsertrix OAuth2 Proxy cookie secret";
        before = [ "browsertrix-downloader-oauth2-proxy.service" ];
        serviceConfig = {
          Type = "oneshot";
          User = "oauth2-proxy";
          Group = "oauth2-proxy";
          RuntimeDirectory = oauthRuntimeDirectoryName;
          RuntimeDirectoryMode = "0700";
          RuntimeDirectoryPreserve = "yes";
          ExecStart = prepareOauthCookieSecret;
          RemainAfterExit = true;
          UMask = "0077";
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadOnlyPaths = [ oauthCookieSecretSource ];
          ReadWritePaths = [ oauthRuntimeDirectory ];
        };
      };

      systemd.services.browsertrix-downloader-oauth2-proxy.requires = [
        "browsertrix-downloader-oauth2-cookie-secret.service"
      ];
    }

    (oauth2Proxy.mkSidecarService {
      serviceName = "browsertrix-downloader-oauth2-proxy";
      description = "Dedicated OAuth2 Proxy for Browsertrix Downloader";
      clientId = "browsertrix-downloader-web";
      clientSecretFile = config.age.secrets.browsertrixDownloaderOauth2ProxyClientSecret.path;
      cookieSecretFile = oauthCookieSecretFile;
      cookieName = "_oauth2_proxy_browsertrix_downloader";
      domain = host;
      port = vars.networking.ports.oauth2ProxyBrowsertrix;
      upstream = "http://${listenAddress}:${toString listenPort}";
      allowedGroups = [ "web-archive-users" ];
      codeChallengeMethod = "S256";
      serviceDependencies = [
        "caddy.service"
        "browsertrix-downloader.service"
        "browsertrix-downloader-oauth2-cookie-secret.service"
      ];
      upstreamCheck = {
        displayName = "Browsertrix Downloader";
        url = "http://${listenAddress}:${toString listenPort}/healthz";
      };
    })
  ];
}
