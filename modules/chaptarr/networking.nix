{ config, lib, vars, ... }:

let
  cfg = config.repo.chaptarr;
  host = "chaptarr.${vars.domain}";
in
{
  config = lib.mkIf cfg.enable {
    repo.authGateway.protectedApps.chaptarr = {
      inherit host;
      upstream = "http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.chaptarr}";
      allowedGroups = [ "media-automation-users" ];
    };

    services.unbound.privateHosts.${host}.target = "private";
  };
}
