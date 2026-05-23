{ config, lib, pkgs, vars, ... }:

let
  proxyUser = "immich-public-proxy";
  proxyUid = 3001;
  proxyImage = "docker.io/alangrainger/immich-public-proxy@sha256:48c4ea4884b04c77a4a4ec93e190dea6cb7dc1b38acb005a35dd56f68212d85a";
  loopback = vars.networking.loopbackIPv4;
  proxyListenPort = vars.networking.ports.immichPublicProxy;
  proxyContainerPort = vars.networking.ports.immichPublicProxyContainer;
  proxyDnsServer =
    if vars.networking.dns.mode == "split-horizon" then vars.networking.lan.ip else vars.networking.netbird.ip;
  proxyImmichHostIP = vars.networking.netbird.ip;
in
{
  config = lib.mkIf config.nixhomeserver.apps.immich.enable {
    virtualisation.podman.enable = true;

    environment.etc."containers/systemd/users/${toString proxyUid}/immich-public-proxy.container".text = ''
      [Container]
      Image=${proxyImage}
      ContainerName=immich-public-proxy
      AddHost=${vars.photosDomain}:${proxyImmichHostIP}
      Environment=IMMICH_URL=https://${vars.photosDomain}
      Environment=PUBLIC_BASE_URL=https://${vars.sharePhotosDomain}
      PublishPort=${loopback}:${toString proxyListenPort}:${toString proxyContainerPort}
      DNS=${proxyDnsServer}
      Pull=missing
      NoNewPrivileges=true
      DropCapability=all
      ReadOnly=true
      Tmpfs=/tmp
      HealthCmd=curl -fsS http://${loopback}:${toString proxyContainerPort}/share/healthcheck || exit 1
      HealthInterval=30s
      HealthTimeout=5s
      HealthRetries=3
      HealthStartPeriod=15s

      [Service]
      TimeoutStartSec=900

      [Install]
      WantedBy=default.target
    '';

    systemd.services.immich-public-proxy-quadlet-refresh = {
      description = "Refresh Immich public proxy rootless quadlet";
      after = [ "user@${toString proxyUid}.service" ];
      requires = [ "user@${toString proxyUid}.service" ];
      wantedBy = [ "multi-user.target" ];
      restartTriggers = [
        config.environment.etc."containers/systemd/users/${toString proxyUid}/immich-public-proxy.container".source
      ];
      serviceConfig.Type = "oneshot";
      script = ''
        export XDG_RUNTIME_DIR=/run/user/${toString proxyUid}
        export DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/${toString proxyUid}/bus
        ${pkgs.util-linux}/bin/runuser -u ${proxyUser} -- ${pkgs.systemd}/bin/systemctl --user daemon-reload
        ${pkgs.util-linux}/bin/runuser -u ${proxyUser} -- ${pkgs.systemd}/bin/systemctl --user restart immich-public-proxy.service
      '';
    };
  };
}
