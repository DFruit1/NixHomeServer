{ lib, config, pkgs, vars, ... }:

let
  mkManualGroup =
    members:
    {
      inherit members;
      overwriteMembers = false;
    };

  kanidmUserTuiData = pkgs.runCommandLocal "kanidm-user-tui-data" { } ''
    mkdir -p "$out/scripts"
    cp ${../../scripts/kanidm-create-user.sh} "$out/scripts/kanidm-create-user.sh"
    chmod 0555 "$out/scripts/kanidm-create-user.sh"
    cp ${../../vars.nix} "$out/vars.nix"
    chmod 0444 "$out/vars.nix"
  '';

  kanidmUserTui = pkgs.writeShellApplication {
    name = "kanidm-user-tui";
    runtimeInputs = [ pkgs.kanidm_1_9 pkgs.newt pkgs.nix ];
    text = ''
      export KANIDM_TUI_REPO_ROOT=${lib.escapeShellArg (toString kanidmUserTuiData)}
      exec ${lib.escapeShellArg "${toString kanidmUserTuiData}/scripts/kanidm-create-user.sh"} "$@"
    '';
  };
in

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

      persons.${vars.kanidmAdminUser} = {
        displayName = vars.kanidmAdminUser;
        mailAddresses = [ vars.kanidmAdminEmail ];
      };

      groups.fileshare_users = mkManualGroup [ vars.kanidmAdminUser ];
      groups."immich-users" = mkManualGroup [ ];
      groups."immich-admin" = mkManualGroup [ vars.kanidmAdminUser ];
      groups."paperless-users" = mkManualGroup [ ];
      groups."paperless-admin" = mkManualGroup [ vars.kanidmAdminUser ];
      groups."audiobookshelf-users" = mkManualGroup [ ];
      groups."audiobookshelf-admin" = mkManualGroup [ vars.kanidmAdminUser ];
      groups."kavita-admin" = mkManualGroup [ vars.kanidmAdminUser ];
      groups."kavita-login" = mkManualGroup [ ];
      groups.users = mkManualGroup [ vars.kanidmAdminUser ];

      systems.oauth2.immich-web = {
        displayName = "Immich";
        originUrl = "https://${vars.photosDomain}/auth/login";
        originLanding = "https://${vars.photosDomain}";
        basicSecretFile = config.age.secrets.immichClientSecret.path;
        preferShortUsername = true;
        scopeMaps."immich-users" = [ "openid" "profile" "email" ];
        scopeMaps."immich-admin" = [ "openid" "profile" "email" ];
      };

      systems.oauth2.paperless-web = {
        displayName = "Paperless-ngx";
        originUrl = "https://paperless.${vars.domain}/accounts/oidc/kanidm/login/callback/";
        originLanding = "https://paperless.${vars.domain}";
        basicSecretFile = config.age.secrets.paperlessClientSecret.path;
        allowInsecureClientDisablePkce = true;
        preferShortUsername = true;
        scopeMaps."paperless-users" = [ "openid" "profile" "email" ];
        scopeMaps."paperless-admin" = [ "openid" "profile" "email" ];
      };

      systems.oauth2.abs-web = {
        displayName = "Audiobookshelf";
        originUrl = [
          "https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/callback"
          "https://${vars.audiobooksDomain}/audiobookshelf/auth/openid/mobile-redirect"
        ];
        originLanding = "https://${vars.audiobooksDomain}/audiobookshelf/";
        basicSecretFile = config.age.secrets.absClientSecret.path;
        preferShortUsername = true;
        scopeMaps."audiobookshelf-users" = [ "openid" "profile" "email" ];
        scopeMaps."audiobookshelf-admin" = [ "openid" "profile" "email" ];
      };

      systems.oauth2.kavita-web = {
        displayName = "Kavita";
        originUrl = [
          "https://${vars.kavitaDomain}/signin-oidc"
          "https://${vars.kavitaDomain}/signout-callback-oidc"
        ];
        originLanding = "https://${vars.kavitaDomain}/";
        basicSecretFile = config.age.secrets.kavitaClientSecret.path;
        preferShortUsername = true;
        scopeMaps."kavita-login" = [ "openid" "profile" "email" "groups" ];
        scopeMaps."kavita-admin" = [ "openid" "profile" "email" "groups" ];
      };

      systems.oauth2.oauth2-proxy = {
        displayName = "OAuth2 Proxy";
        originUrl = "https://${vars.filesDomain}/oauth2/callback";
        originLanding = "https://${vars.filesDomain}";
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

  environment.systemPackages = [
    pkgs.kanidm_1_9
    kanidmUserTui
  ];

  systemd.tmpfiles.rules = [
    "d /var/lib/kanidm 0700 kanidm kanidm -"
  ];
}
