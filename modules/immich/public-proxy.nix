{ pkgs, unstablePkgs, vars, ... }:

let
  proxyUser = "immich-public-proxy";
  proxyGroup = "immich-public-proxy";
  proxyListenPort = vars.networking.ports.immichPublicProxy;
  photosHost = "photos.${vars.domain}";
  shareHost = "sharephotos.${vars.domain}";

  # Pin the proxy version locally so the multi-select / "download all" zip UI
  # (fixed against PrivateTmp OOM and Cloudflare caching in 3.3.x) ships
  # independently of the nixpkgs-unstable snapshot.
  proxyPackage = unstablePkgs.callPackage ./package.nix { };

  # Derive the runtime config from the package's own config.json so upstream
  # defaults (response headers, quality caps, metadata) are preserved. Only
  # allowDownload is changed: 1 = follow each share's Immich download setting,
  # which surfaces the multi-select toolbar and "download all" button for
  # shares whose owner enabled downloads in Immich.
  proxyConfig = pkgs.runCommand "immich-public-proxy-config.json" {
    nativeBuildInputs = [ pkgs.jq ];
  } ''
    jq '.ipp.allowDownload = 1' \
      ${proxyPackage}/lib/node_modules/immich-public-proxy/config.json > $out
  '';
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
        IPP_CONFIG = "${proxyConfig}";
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
        ExecStart = "${proxyPackage}/bin/immich-public-proxy";
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
