{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.chaptarr;
  paths = cfg.paths;
  containerEnvironmentFile = "/run/chaptarr/container.env";
in
{
  options.repo.chaptarr = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Whether to enable Chaptarr.";
    };

    image = lib.mkOption {
      type = lib.types.str;
      # Runtime contract: https://github.com/Chaptarr/chaptarr#getting-started
      default = "docker.io/chaptarr/chaptarr@sha256:8e29f4941acaf74c80bba4322237dfd2549816b3dd1b581f176b1be5d1ccb46b";
      description = "Pinned multi-architecture Chaptarr OCI image.";
    };

    metadataServerUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://api2.chaptarr.com";
      description = "Chaptarr metadata aggregation service reconciled and health-checked at boot.";
    };
  };

  config = lib.mkIf cfg.enable {
    repo.storage.dataPool.guardedServices = [ "chaptarr" ];

    # The preStart rewrite sets AuthenticationRequired=DisabledForLocalAddresses,
    # which bypasses Chaptarr's UI auth for any loopback peer. That is only
    # acceptable while the listener itself is loopback-bound, so neither the
    # firewall nor a published port mapping may widen the surface: the gateway's
    # loopback upstream has to stay the only route in.
    assertions =
      let
        chaptarrPort = vars.networking.ports.chaptarr;
        firewallPortLists = [
          config.networking.firewall.allowedTCPPorts
          (config.networking.firewall.interfaces.${vars.networking.interfaces.lan}.allowedTCPPorts or [ ])
          (config.networking.firewall.interfaces.${vars.networking.interfaces.netbird}.allowedTCPPorts or [ ])
        ];
      in
      [
        {
          assertion = !(builtins.elem chaptarrPort (lib.concatLists firewallPortLists));
          message = "Chaptarr must not be opened in the host firewall; the loopback-bound auth gateway upstream is its only route.";
        }
      ];

    systemd.tmpfiles.rules = [
      "d ${paths.stateDir} 0750 chaptarr chaptarr - -"
    ];

    virtualisation.oci-containers.containers.chaptarr = {
      # NixOS OCI containers are managed as systemd units and default to the
      # Podman backend: https://wiki.nixos.org/wiki/Docker#Docker_Containers_as_systemd_Services
      image = cfg.image;
      serviceName = "chaptarr";
      pull = "missing";
      environment = {
        TZ = vars.timeZone;
        UMASK = "002";
        # Chaptarr's Kestrel listener honours Chaptarr__Server__BindAddress
        # (src/NzbDrone.Host/Bootstrap.cs, Chaptarr:Server section). Pinning it
        # to loopback makes the host-network listener unreachable from the LAN
        # and NetBird, so the auth gateway's Caddy upstream stays the only route
        # in and the NixOS firewall is no longer the sole boundary. A published
        # `ports` mapping cannot be used here: bridge networking would hide the
        # loopback qBittorrent WebUI that Chaptarr's download client and the
        # remote-path mapping test depend on (qBittorrent binds 127.0.0.1 with
        # AuthSubnetWhitelist=127.0.0.1/32).
        Chaptarr__Server__BindAddress = vars.networking.loopbackIPv4;
        # The image's entrypoint drops privileges to PUID/PGID; do not set
        # `user`, which upstream documents as bypassing that setup.
      };
      environmentFiles = [ containerEnvironmentFile ];
      volumes = [
        "${paths.stateDir}:/config"
        "${paths.audiobookRoot}:/audiobooks"
        "${paths.ebookRoot}:/ebooks"
        "${paths.downloadRoot}:/downloads"
      ];
      networks = [ "host" ];
    };

    systemd.services.chaptarr = {
      wants = [ "chaptarr-storage-layout-v1.service" ];
      after = [ "chaptarr-storage-layout-v1.service" ];
      preStart = lib.mkBefore ''
        chaptarr_uid="$(${pkgs.getent}/bin/getent passwd chaptarr | ${pkgs.coreutils}/bin/cut -d: -f3)"
        chaptarr_gid="$(${pkgs.getent}/bin/getent group chaptarr | ${pkgs.coreutils}/bin/cut -d: -f3)"
        test -n "$chaptarr_uid"
        test -n "$chaptarr_gid"
        ${pkgs.coreutils}/bin/install -m 0600 /dev/null ${containerEnvironmentFile}
        ${pkgs.coreutils}/bin/printf 'PUID=%s\nPGID=%s\n' "$chaptarr_uid" "$chaptarr_gid" > ${containerEnvironmentFile}

        config_xml=${lib.escapeShellArg "${paths.stateDir}/config.xml"}
        if [[ -f "$config_xml" ]]; then
          # Chaptarr honours DisabledForLocalAddresses (TrustedNetworkPolicy:
          # UI auth is bypassed when the peer address is loopback), which is what
          # lets the auth gateway front it without a second interactive login.
          # That relaxation is only safe while the listener is loopback-bound,
          # because then every request the gateway proxies originates from
          # 127.0.0.1 and nothing on the LAN can reach the bypass at all. Keep
          # this rewrite and the bind address in the same declaration so the two
          # cannot drift apart; removing the relaxation would break SSO.
          ${pkgs.xmlstarlet}/bin/xmlstarlet ed -L \
            -u '/Config/AuthenticationMethod' -v 'Forms' \
            -u '/Config/AuthenticationRequired' -v 'DisabledForLocalAddresses' \
            "$config_xml"
        fi
      '';
      serviceConfig = {
        Restart = "on-failure";
        RuntimeDirectory = "chaptarr";
        RuntimeDirectoryMode = "0750";
      };
    };
  };
}
