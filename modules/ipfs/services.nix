{ appPackages, config, lib, pkgs, vars, ... }:

let
  stateDir = config.repo.ipfs.paths.stateDir;
  distributionDir = config.repo.ipfs.paths.distributionDir;
  channelsDir = "${distributionDir}/channels";
  host = "ipfs.${vars.domain}";
  loopback = vars.networking.loopbackIPv4;
  gatewayPort = vars.networking.ports.ipfsGateway;
  aliasPort = vars.networking.ports.ipfsAlias;
  swarmPort = vars.networking.ports.ipfsSwarm;
  publish = pkgs.writeShellApplication {
    name = "ipfs-publish";
    runtimeInputs = [ pkgs.coreutils pkgs.systemd pkgs.util-linux config.services.kubo.package ];
    # This shell command only orchestrates Kubo's CLI and an atomic CID pointer;
    # the HTTP alias service is implemented in Rust.
    text = ''
      set -euo pipefail
      if [[ "$#" != 2 || ! "$1" =~ ^[a-z0-9]([a-z0-9-]{0,62}[a-z0-9])?$ ]]; then
        echo "Usage: sudo ipfs-publish <channel> <file-or-directory>" >&2
        exit 2
      fi
      if [[ "$(id -u)" != 0 ]]; then
        echo "ipfs-publish requires root access" >&2
        exit 1
      fi
      channel="$1"
      source_path="$2"
      if [[ ! -f "$source_path" && ! -d "$source_path" ]]; then
        echo "Source must be a readable file or directory" >&2
        exit 2
      fi
      systemctl is-active --quiet ipfs.service || {
        echo "Kubo is not running" >&2
        exit 1
      }

      # F-Droid can trigger publication while tmpfiles and impermanence are
      # still converging during activation. Ensure the stable-pointer
      # directory exists at the point of use as well.
      install -d -m 0755 ${lib.escapeShellArg channelsDir}

      export IPFS_PATH=${lib.escapeShellArg config.environment.variables.IPFS_PATH}
      exec 9>/run/lock/ipfs-publish.lock
      flock 9
      cid="$(ipfs add --recursive --quieter --cid-version=1 --pin=true -- "$source_path")"
      if [[ ! "$cid" =~ ^b[a-z2-7]{49,119}$ ]]; then
        echo "Kubo returned an invalid root CID" >&2
        exit 1
      fi
      pointer="$(mktemp ${lib.escapeShellArg "${channelsDir}/.pointer.XXXXXX"})"
      trap 'rm -f "$pointer"' EXIT
      printf '%s\n' "$cid" >"$pointer"
      chmod 0644 "$pointer"
      mv -f "$pointer" ${lib.escapeShellArg channelsDir}/"$channel".cid
      trap - EXIT

      printf 'Pinned CID: %s\nImmutable URL: https://${host}/ipfs/%s\nStable URL: https://${host}/published/%s\n' \
        "$cid" "$cid" "$channel"
    '';
  };
in
{
  config = lib.mkIf config.repo.ipfs.enable {
    repo.storage.dataPool.directories = [
      {
        path = stateDir;
        mode = "0750";
        user = "ipfs";
        group = "ipfs";
      }
    ];
    repo.storage.dataPool.guardedServices = [ "ipfs" "ipfs-alias" ];

    services.kubo = {
      enable = true;
      dataDir = stateDir;
      defaultMode = "norouting";
      enableGC = true;
      settings = {
        Bootstrap = [ ];
        Discovery.MDNS.Enabled = false;
        Addresses = {
          API = [ ];
          Gateway = "/ip4/${loopback}/tcp/${toString gatewayPort}";
          Swarm = [ "/ip4/0.0.0.0/tcp/${toString swarmPort}" ];
          Announce = [ "/ip4/${vars.networking.netbird.ip}/tcp/${toString swarmPort}" ];
        };
        Gateway = {
          NoFetch = true;
          Writable = false;
          DNSLink = false;
          PublicGateways.${host} = {
            Paths = [ "/ipfs" ];
            UseSubdomains = false;
            DeserializedResponses = true;
          };
        };
      };
    };

    systemd.tmpfiles.rules = [
      "d ${distributionDir} 0755 root root -"
      "d ${channelsDir} 0755 root root -"
    ];

    environment.systemPackages = [ publish ];

    systemd.services.ipfs-alias = {
      description = "Resolve admin distribution names to pinned IPFS content";
      wantedBy = [ "multi-user.target" ];
      requires = [ "ipfs.service" ];
      after = [ "ipfs.service" ];
      environment = {
        IPFS_ALIAS_LISTEN = "${loopback}:${toString aliasPort}";
        IPFS_ALIAS_CHANNELS_DIR = channelsDir;
      };
      serviceConfig = {
        ExecStart = "${appPackages.ipfs-alias}/bin/ipfs-alias";
        DynamicUser = true;
        Restart = "on-failure";
        RestartSec = "5s";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectProc = "invisible";
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictRealtime = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_UNIX" ];
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
      };
    };

  };
}
