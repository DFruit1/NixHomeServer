{ config, lib, pkgs, vars, ... }:

{
  ######################################################################
  ## 1 — Core instance
  ######################################################################
  services.nextcloud = {
    enable           = true;
    hostName         = "nextcloud.${vars.domain}";
    https            = true;                       # affects generated URLs
    home             = "${vars.dataRoot}/nextcloud";
    database.createLocally = true;                # MariaDB on localhost

    # --- initial admin account ---------------------------------------
    config = {
      adminuser     = "ncadmin";
      adminpassFile = config.age.secrets.nextcloudAdminPass.path;
      dbtype        = "mysql";                    # default, but be explicit
    };

    # --- runtime config.php tweaks -----------------------------------
    settings = {
      "overwrite.cli.url" = "https://nextcloud.${vars.domain}";
      overwriteprotocol   = "https";
      trusted_domains     = [ "nextcloud.${vars.domain}" ];
    };

    # --- extra apps --------------------------------------------------
    extraAppsEnable = true;
    extraApps.oidc_login = pkgs.fetchNextcloudApp {
      url      = "https://github.com/pulsejet/nextcloud-oidc-login/archive/refs/tags/v3.2.2.tar.gz";
      sha256   = "sha256-Q9iSqtcIffwT+KF6aaSI2oaMix+vT+/m5W43/XxXEV0=";
      license  = "gpl3";
    };
  };

  ######################################################################
  ## 2 — Automated OIDC-provider registration (systemd oneshot)
  ##
  ##   Replaces the old, unsupported `postInstall` hook.
  ######################################################################
  systemd.services."nextcloud-kanidm-provider" = {
    description = "Register Kanidm OIDC provider in Nextcloud";
    after       = [ "nextcloud-setup.service" ];
    requires    = [ "nextcloud-setup.service" ];
    wantedBy    = [ "multi-user.target" ];

    serviceConfig = {
      Type  = "oneshot";
      User  = "nextcloud";
      Group = "nextcloud";
    };

    environment = {
      # path to your secret generated in Kanidm, decrypted by agenix
      OIDC_SECRET_FILE = config.age.secrets.nextcloudOIDCClientSecret.path;
    };

    script = ''
      set -eu
      SECRET=$(<"$OIDC_SECRET_FILE")

      ${config.services.nextcloud.occ} --no-interaction \
        user_oidc:provider Kanidm                    \
          --client-id      nextcloud-web             \
          --client-secret  "$SECRET"                 \
          --issuer-uri     "${vars.kanidmIssuer}"    \
          --scope          "openid profile email"    \
          --name-claims    "preferred_username"      \
          --auto-provision 1
    '';
  };
}
