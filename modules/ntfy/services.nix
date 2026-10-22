{ config, lib, vars, ... }:

let
  cfg = config.repo.ntfy;
in
{
  config = lib.mkIf cfg.enable {
    # ntfy keeps no database here: messages live in a bounded in-memory cache
    # backed by a cache file under the state directory, and attachments expire.
    # Nothing in this module reads or writes the ZFS data pool, so it is
    # deliberately absent from repo.storage.dataPool.guardedServices -- adding
    # it there would make notifications depend on the media pool being mounted.
    systemd.services.ntfy = {
      description = "Private ntfy push notification server (LAN and NetBird only)";
      wantedBy = [ "multi-user.target" ];
      # The ntfy user is declared by identity.nix, so the unit must come up
      # after sysusers has created it or the first start races an account that
      # does not exist yet.
      after = [
        "systemd-sysusers.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "simple";
        User = "ntfy";
        Group = "ntfy";
        # Only `serve` accepts -c; every ntfy subcommand reads NTFY_CONFIG_FILE.
        ExecStart = "${cfg.package}/bin/ntfy serve -c ${cfg.configFile}";
        Environment = [ "NTFY_CONFIG_FILE=${cfg.configFile}" ];
        Restart = "on-failure";
        RestartSec = "10s";
        StateDirectory = "ntfy";
        StateDirectoryMode = "0755";
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
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
        # The message cache is small and bounded by cache-duration; ntfy holds
        # no large buffers and needs no swap.
        MemoryHigh = "256M";
        MemoryMax = "512M";
        MemorySwapMax = "0";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
      };
      unitConfig = {
        StartLimitIntervalSec = "15min";
        StartLimitBurst = 5;
      };
    };

    assertions = [
      {
        # nixpkgs has no ntfy server: pkgs.ntfy is the unrelated dschep Python
        # CLI, so pointing ExecStart at pkgs.ntfy would start a client that
        # exits immediately. Read the derivational name rather than the store
        # path, which carries a version suffix this check must not depend on,
        # and so the assertion costs no build.
        assertion = (cfg.package.pname or null) == "ntfy-server";
        message = "repo.ntfy.package must provide the ntfy server binary; pkgs.ntfy is the dschep CLI, not a server.";
      }
      {
        # The generated config is the only thing binding the listen address, so
        # a config that lost its loopback pin would silently widen the host to
        # every interface. Read the generated file rather than trusting intent.
        assertion = lib.hasInfix "listen-http: \"${vars.networking.loopbackIPv4}:${toString cfg.port}\"" (builtins.readFile cfg.configFile);
        message = ''
          repo.ntfy.configFile must bind loopback only.
          ntfy topics are unauthenticated, so a non-loopback listen address exposes them to the whole LAN.
        '';
      }
    ];
  };
}