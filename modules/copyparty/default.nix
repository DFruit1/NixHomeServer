{ lib, config, vars, copyparty, ... }:

let
  copypartyIssuer = "https://${vars.kanidmDomain}/oauth2/openid/copyparty-web";
in
{
  imports = [ copyparty.nixosModules.default ];

  nixpkgs.overlays = [ copyparty.overlays.default ];

  services.copyparty = {
    enable = true;
    openFilesLimit = 8192;
    settings = {
      i = "127.0.0.1";
      p = vars.copypartyPort;
      no-reload = true;
    };
    volumes = {
      "/" = {
        path = "${vars.dataRoot}/copyparty";
        access.wG = "*";
      };
    };
  };

  systemd.services.copyparty.environment = {
    CPP_AUTH_STRATEGY = "oidc";
    CPP_OIDC_ISSUER = copypartyIssuer;
    CPP_OIDC_CLIENT_ID = "copyparty-web";
    CPP_OIDC_CLIENT_SECRET_FILE = config.age.secrets.copypartyClientSecret.path;
    CPP_OIDC_SCOPE = "openid profile email";
  };

  systemd.services.copyparty.serviceConfig.AppArmorProfile = "generated-copyparty";
}
