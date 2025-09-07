{ lib, pkgs, config, ... }:

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
      ExecStart = "${pkgs.python3}/bin/python ${copyparty} --address 127.0.0.1 --port ${toString vars.copypartyPort} --root ${vars.dataRoot}/copyparty";
      User = "copyparty";
      Group = "copyparty";
      Restart = "on-failure";
    };
    environment = {
      CPP_AUTH_STRATEGY = "oidc";
      CPP_OIDC_ISSUER = vars.kanidmIssuer;
      CPP_OIDC_CLIENT_ID = "copyparty-web";
      CPP_OIDC_CLIENT_SECRET_FILE = config.age.secrets.copypartyClientSecret.path;
      CPP_OIDC_SCOPE = "openid profile email";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/copyparty 0750 copyparty copyparty -"
  ];

  networking.firewall.allowedTCPPorts = [ vars.copypartyPort ];
}
