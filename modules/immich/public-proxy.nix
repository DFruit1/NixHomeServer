{ pkgs, vars, ... }:

let
  proxyUser = "immich-public-proxy";
  proxyGroup = "immich-public-proxy";
  loopback = vars.networking.loopbackIPv4;
  proxyListenPort = vars.networking.ports.immichPublicProxy;
  photosHost = "photos.${vars.domain}";
  shareHost = "sharephotos.${vars.domain}";
in
{
  config = {
    systemd.services.immich-public-proxy = {
      description = "Immich public share proxy";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "immich-server.service"
        "network-online.target"
      ];
      after = [
        "immich-server.service"
        "network-online.target"
      ];
      environment = {
        HOST = loopback;
        PORT = toString proxyListenPort;
        IMMICH_URL = "https://${photosHost}";
        PUBLIC_BASE_URL = "https://${shareHost}";
      };
      serviceConfig = {
        Type = "simple";
        User = proxyUser;
        Group = proxyGroup;
        WorkingDirectory = "/var/lib/immich-public-proxy";
        ExecStart = "${pkgs.immich-public-proxy}/bin/immich-public-proxy";
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ "/var/lib/immich-public-proxy" ];
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
      };
    };
  };
}
