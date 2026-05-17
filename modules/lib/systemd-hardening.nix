{ lib }:

rec {
  daemon = {
    NoNewPrivileges = true;
    PrivateTmp = true;
    ProtectSystem = "strict";
    ProtectHome = true;
    ProtectKernelTunables = true;
    ProtectKernelModules = true;
    ProtectControlGroups = true;
    RestrictSUIDSGID = true;
    LockPersonality = true;
  };

  networkProxy = daemon // {
    RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
  };

  mediaWriter = readWritePaths:
    daemon // {
      ReadWritePaths = readWritePaths;
    };

  oneshotRoot = {
    Type = "oneshot";
    PrivateTmp = true;
    ProtectHome = true;
  };

  merge = base: extra: lib.recursiveUpdate base extra;
}
