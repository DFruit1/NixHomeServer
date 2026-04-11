{ lib, config, pkgs, vars, ... }:

{
  assertions = [
    {
      assertion = config.age.secrets ? kanidmAdminPass;
      message = "Missing kanidmAdminPass secret; run scripts/gen-all-secrets.sh";
    }
    {
      assertion = config.age.secrets ? kanidmSysAdminPass;
      message = "Missing kanidmSysAdminPass secret; run scripts/gen-all-secrets.sh";
    }
  ];

  services.kanidm = {
    enableServer = true;
    package = pkgs.kanidmWithSecretProvisioning_1_9;

    serverSettings = {
      origin = "https://${vars.kanidmDomain}";
      domain = vars.domain;
      bindaddress = "127.0.0.1:${toString vars.kanidmPort}";

      # reuse certificates obtained by Caddy
      tls_chain =
        "/var/lib/acme/${vars.kanidmDomain}/fullchain.pem";
      tls_key =
        "/var/lib/acme/${vars.kanidmDomain}/key.pem";
    };

    provision = {
      enable = true;
      idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
      adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;
      # Provision directly against the local Kanidm listener so activation does
      # not depend on Caddy/public DNS/certificate reachability.
      instanceUrl = "https://localhost:${toString vars.kanidmPort}";
      acceptInvalidCerts = true;

      groups.fileshare_users = {
        overwriteMembers = false;
      };

      groups.users = {
        overwriteMembers = false;
      };

      systems.oauth2.immich-web = {
        displayName = "Immich";
        originUrl = "https://photoshare.${vars.domain}/auth/login";
        originLanding = "https://photoshare.${vars.domain}";
        basicSecretFile = config.age.secrets.immichClientSecret.path;
        preferShortUsername = true;
        scopeMaps.users = [ "openid" "profile" "email" ];
      };

      systems.oauth2.paperless-web = {
        displayName = "Paperless-ngx";
        originUrl = "https://paperless.${vars.domain}/accounts/oidc/kanidm/login/callback/";
        originLanding = "https://paperless.${vars.domain}";
        basicSecretFile = config.age.secrets.paperlessClientSecret.path;
        preferShortUsername = true;
        scopeMaps.users = [ "openid" "profile" "email" ];
      };

      systems.oauth2.abs-web = {
        displayName = "Audiobookshelf";
        originUrl = [
          "https://audiobookshelf.${vars.domain}/audiobookshelf/auth/openid/callback"
          "https://audiobookshelf.${vars.domain}/audiobookshelf/auth/openid/mobile-redirect"
        ];
        originLanding = "https://audiobookshelf.${vars.domain}/audiobookshelf/";
        basicSecretFile = config.age.secrets.absClientSecret.path;
        preferShortUsername = true;
        scopeMaps.users = [ "openid" "profile" "email" ];
      };

      systems.oauth2.oauth2-proxy = {
        displayName = "OAuth2 Proxy";
        originUrl = "https://fileshare.${vars.domain}/oauth2/callback";
        originLanding = "https://fileshare.${vars.domain}";
        basicSecretFile = config.age.secrets.oauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps.fileshare_users = [ "openid" "profile" "email" "groups" ];
      };
    };
  };

  systemd.services.kanidm = {
    after = [ "caddy.service" "acme-${vars.kanidmDomain}.service" ];
    wants = [ "caddy.service" "acme-${vars.kanidmDomain}.service" ];
  };

  users.users.kanidm.extraGroups = [ "caddy" ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
  ];
}
