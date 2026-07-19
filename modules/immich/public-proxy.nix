{ pkgs, vars, ... }:

let
  proxyUser = "immich-public-proxy";
  proxyGroup = "immich-public-proxy";
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
        IPP_PORT = toString proxyListenPort;
        IMMICH_URL = "https://${photosHost}";
        PUBLIC_BASE_URL = "https://${shareHost}";
      };
      serviceConfig = {
        Type = "simple";
        User = proxyUser;
        Group = proxyGroup;
        WorkingDirectory = "/var/lib/immich-public-proxy";
        ExecStartPre = "+${pkgs.writeShellScript "immich-public-proxy-stale-podman-cleanup" ''
          ${pkgs.coreutils}/bin/chown -R ${proxyUser}:${proxyGroup} /var/lib/immich-public-proxy
          proxy_uid="$(${pkgs.coreutils}/bin/id -u ${proxyUser})"
          ${pkgs.util-linux}/bin/runuser -u ${proxyUser} -- \
            env XDG_RUNTIME_DIR="/run/user/$proxy_uid" \
            ${pkgs.systemd}/bin/systemctl --user stop immich-public-proxy.service || true
          ${pkgs.procps}/bin/pkill -u ${proxyUser} -f 'podman|conmon|passt|node dist/index.js' || true
        ''}";
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
