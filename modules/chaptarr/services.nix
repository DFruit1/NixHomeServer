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
