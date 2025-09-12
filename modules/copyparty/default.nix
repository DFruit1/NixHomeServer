{ lib, pkgs, ... }:

let
  vars = import ../../vars.nix { inherit lib; };
  copyparty = pkgs.fetchurl {
    url = "https://github.com/9001/copyparty/releases/download/v1.19.7/copyparty-sfx.py";
    sha256 = "1c9hind48vafim57a3g7kj0nmc6h1s3zcjjwd9aj04akamvirv0s";
  };
in
{
  users.users.copyparty = {
    isSystemUser = true;
    description = "Copyparty file server";
    group = "copyparty";
    home = "${vars.dataRoot}/copyparty";
  };

  users.groups.copyparty = { };

  systemd.services.copyparty = {
    description = "Copyparty file sharing service";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    serviceConfig = {
      ExecStart = "${pkgs.python3}/bin/python ${copyparty} -a 127.0.0.1:${toString vars.copypartyPort} --idp-h-usr X-Forwarded-User --idp-h-grp X-Forwarded-Groups --xff-src=lan ${vars.dataRoot}/copyparty";
      User = "copyparty";
      Group = "copyparty";
      Restart = "on-failure";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/copyparty 0750 copyparty copyparty -"
  ];

  networking.firewall.allowedTCPPorts = [ vars.copypartyPort ];
}
