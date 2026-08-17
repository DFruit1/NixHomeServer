{ appPackages, config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mkvmaker;
  distributed = cfg.distributedWorkers;
  workerIso = (import ../../flake/mkvmaker-worker-iso.nix {
    inherit lib vars;
    system = "x86_64-linux";
    paths = cfg.paths;
    mkvmakerPackage = appPackages.mkvmaker;
  }).config.system.build.isoImage;
  networkValidation = import ../../lib/network-validation.nix { inherit lib; };
  storageValidation = import ../../lib/storage-validation.nix { inherit lib; };
  adminIsoRoot = "${vars.usersRoot}/${vars.kanidmAdminUser}/_ISO";
  workerConfigRoot = "/var/lib/mkvmaker-worker-config";
  pow2 = exponent:
    builtins.foldl' (value: _: value * 2) 1 (lib.genList (index: index) exponent);
  prefixLength = vars.serverLanPrefixLength;
  blockSize = pow2 (32 - prefixLength);
  networkInteger =
    builtins.div (networkValidation.ipv4ToInt vars.serverLanIP) blockSize * blockSize;
  octet = divisor:
    let value = builtins.div networkInteger divisor;
    in value - builtins.div value 256 * 256;
  defaultClientCidr = lib.concatStringsSep "."
    (map toString [
      (octet (pow2 24))
      (octet (pow2 16))
      (octet (pow2 8))
      (octet 1)
    ]) + "/${toString prefixLength}";
  workerConfig = pkgs.writeText "mkvmaker-worker-config.json" (builtins.toJSON {
    schemaVersion = 2;
    paths = {
      stateRoot = cfg.paths.stateRoot;
      sharedRoot = vars.sharedRoot;
      inputDir = cfg.paths.dvdInbox;
      moviesDir = cfg.paths.moviesOutput;
      showsDir = cfg.paths.showsOutput;
      stagingDir = cfg.paths.stagingRoot;
    };
    inherit (cfg)
      settleSeconds
      minimumTitleSeconds
      dominantTitleRatio
      metadataTimeoutSeconds
      maxAttempts
      retrySeconds
      audioProfile
      videoPreset;
    inherit (distributed) leaseSeconds;
  });
  exportOptions = "rw,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534";
  readOnlyExportOptions = "ro,sync,no_subtree_check,all_squash,anonuid=65534,anongid=65534";
  publishedName = "nixhomeserver-mkvmaker-worker-x86_64-linux.iso";
  workerRelease = builtins.substring 0 20 (builtins.hashString "sha256" (toString workerIso));
in
{
  options.repo.mkvmaker.distributedWorkers = {
    enable = lib.mkEnableOption "trusted-LAN stateless MKVMaker workers" // {
      default = true;
    };
    leaseSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 120;
      description = "Seconds a distributed worker owns an ISO before renewing its queue lease.";
    };
    nfsClientCidr = lib.mkOption {
      type = lib.types.str;
      default = defaultClientCidr;
      description = "Canonical trusted LAN IPv4 CIDR allowed to mount the scoped MKVMaker NFS exports.";
    };
  };

  config = lib.mkIf distributed.enable {
    assertions = [
      {
        assertion = distributed.leaseSeconds >= 30;
        message = "repo.mkvmaker.distributedWorkers.leaseSeconds must be at least 30 seconds.";
      }
      {
        assertion = networkValidation.validIPv4Cidr distributed.nfsClientCidr;
        message = "repo.mkvmaker.distributedWorkers.nfsClientCidr must be a canonical IPv4 CIDR.";
      }
      {
        assertion = networkValidation.cidrContains vars.serverLanIP distributed.nfsClientCidr;
        message = "repo.mkvmaker.distributedWorkers.nfsClientCidr must contain the configured server LAN address.";
      }
      {
        assertion =
          storageValidation.validAbsolutePath cfg.paths.workerImageOutput
          && lib.hasPrefix "${adminIsoRoot}/" cfg.paths.workerImageOutput;
        message = "repo.mkvmaker.paths.workerImageOutput must remain below the configured Kanidm administrator's personal _ISO directory.";
      }
    ];

    repo.storage.dataPool.guardedServices = [
      "mkvmaker-worker-config"
      "mkvmaker-worker-image-publish"
    ];

    services.nfs.server = {
      enable = true;
      hostName = vars.serverLanIP;
      exports = lib.mkAfter ''
        ${cfg.paths.dvdInbox} ${distributed.nfsClientCidr}(${exportOptions})
        ${cfg.paths.moviesOutput} ${distributed.nfsClientCidr}(${exportOptions})
        ${cfg.paths.showsOutput} ${distributed.nfsClientCidr}(${exportOptions})
        ${cfg.paths.stagingRoot} ${distributed.nfsClientCidr}(${exportOptions})
        ${cfg.paths.stateRoot} ${distributed.nfsClientCidr}(${exportOptions})
        ${workerConfigRoot} ${distributed.nfsClientCidr}(${readOnlyExportOptions})
      '';
    };
    services.nfs.settings.nfsd = {
      vers3 = false;
      vers4 = true;
    };

    networking.firewall.interfaces.${vars.networking.interfaces.lan}.allowedTCPPorts = [ 2049 ];

    systemd.services.nfs-server = {
      requires = [ "mkvmaker-storage-layout-v1.service" "mkvmaker-worker-config.service" ];
      after = [ "mkvmaker-storage-layout-v1.service" "mkvmaker-worker-config.service" ];
    };

    systemd.services.mkvmaker-worker-config = {
      description = "Publish versioned conversion settings for stateless MKVMaker workers";
      wantedBy = [ "multi-user.target" ];
      requires = [ "mkvmaker-storage-layout-v1.service" ];
      after = [ "mkvmaker-storage-layout-v1.service" ];
      before = [ "nfs-server.service" ];
      restartTriggers = [ workerConfig ];
      path = [ pkgs.acl pkgs.coreutils ];
      script = ''
        set -euo pipefail

        install -d -m 2770 -o mkvmaker -g mkvmaker \
          ${lib.escapeShellArg cfg.paths.stateRoot} \
          ${lib.escapeShellArg cfg.paths.stateRoot}/progress
        install -d -m 0755 -o root -g root ${workerConfigRoot}
        temporary=${workerConfigRoot}/.worker-config.json.tmp
        install -m 0644 -o root -g root ${workerConfig} "$temporary"
        mv -f "$temporary" ${workerConfigRoot}/worker-config.json
        rm -f ${lib.escapeShellArg cfg.paths.stateRoot}/worker-config.json

        chgrp -R mkvmaker ${lib.escapeShellArg cfg.paths.stateRoot}
        find ${lib.escapeShellArg cfg.paths.stateRoot} -type d -exec chmod g+s '{}' +
        setfacl -R -m g:mkvmaker:rwX,u:nobody:rwX ${lib.escapeShellArg cfg.paths.stateRoot}
        find ${lib.escapeShellArg cfg.paths.stateRoot} -type d \
          -exec setfacl -m d:g:mkvmaker:rwx,d:u:nobody:rwx '{}' +
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
    };

    systemd.services.mkvmaker-worker-image-publish = {
      description = "Publish the stateless MKVMaker worker ISO to the server administrator";
      wantedBy = [ "multi-user.target" ];
      requires = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
        "mkvmaker-worker-config.service"
      ];
      after = [
        "data-pool-layout.service"
        "fileshare-user-root-sync.service"
        "mkvmaker-worker-config.service"
      ];
      restartTriggers = [ workerIso ];
      path = [ pkgs.coreutils pkgs.findutils pkgs.getent ];
      script = ''
        set -euo pipefail

        mapfile -d "" candidates < <(find ${workerIso}/iso -maxdepth 1 -type f -name '*.iso' -print0)
        if [[ "''${#candidates[@]}" -ne 1 ]]; then
          echo "Expected exactly one worker ISO in ${workerIso}/iso; found ''${#candidates[@]}" >&2
          exit 1
        fi

        passwd_entry="$(getent passwd ${lib.escapeShellArg vars.kanidmAdminUser})" || {
          echo "Configured Kanidm administrator ${lib.escapeShellArg vars.kanidmAdminUser} has no POSIX account" >&2
          exit 1
        }
        admin_uid="$(cut -d: -f3 <<<"$passwd_entry")"
        admin_gid="$(cut -d: -f4 <<<"$passwd_entry")"
        destination_dir=${lib.escapeShellArg cfg.paths.workerImageOutput}
        releases_dir="$destination_dir/.mkvmaker-worker-releases"
        release="$releases_dir/${workerRelease}"
        temporary_release="$releases_dir/.${workerRelease}.$$.tmp"
        current="$destination_dir/MKVMaker-Worker"
        current_temporary="$destination_dir/.MKVMaker-Worker.$$.tmp"

        cleanup() {
          status=$?
          trap - EXIT INT TERM
          rm -rf -- "$temporary_release"
          rm -f -- "$current_temporary"
          exit "$status"
        }
        trap cleanup EXIT INT TERM

        install -d -m 0750 -o "$admin_uid" -g "$admin_gid" "$destination_dir"
        install -d -m 0750 -o "$admin_uid" -g "$admin_gid" "$releases_dir"
        if [[ ! -d "$release" ]]; then
          install -d -m 0750 -o "$admin_uid" -g "$admin_gid" "$temporary_release"
          cp --reflink=auto -- "''${candidates[0]}" "$temporary_release/${publishedName}"
          (
            cd "$temporary_release"
            sha256sum ${lib.escapeShellArg publishedName} >${lib.escapeShellArg "${publishedName}.sha256"}
          )
          chown "$admin_uid:$admin_gid" \
            "$temporary_release/${publishedName}" \
            "$temporary_release/${publishedName}.sha256"
          chmod 0640 \
            "$temporary_release/${publishedName}" \
            "$temporary_release/${publishedName}.sha256"
          mv -T -- "$temporary_release" "$release"
        fi
        (cd "$release" && sha256sum --check ${lib.escapeShellArg "${publishedName}.sha256"})

        ln -s -- ".mkvmaker-worker-releases/${workerRelease}" "$current_temporary"
        chown -h "$admin_uid:$admin_gid" "$current_temporary"
        mv -Tf -- "$current_temporary" "$current"
        trap - EXIT INT TERM
      '';
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        Nice = 15;
        CPUWeight = 10;
        IOWeight = 10;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ adminIsoRoot ];
      };
    };
  };
}
