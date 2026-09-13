{ config, lib, unstablePkgs, vars, ... }:

let
  cfg = config.repo.opencloud;
  stateDir = cfg.paths.stateDir;
  adminEnvFile = "${stateDir}/config/opencloud-admin.env";
  cloudHost = "cloud.${vars.domain}";
  officeHost = "office.${vars.domain}";
in
{
  services.opencloud = {
    enable = true;
    # Track nixpkgs-unstable for the newer OpenCloud feature set; the stable
    # channel pins 7.2.3 while unstable ships 7.5.0. The web and idp-web asset
    # derivations must come from the same channel as the server binary.
    package = unstablePkgs.opencloud;
    webPackage = unstablePkgs.opencloud.web;
    idpWebPackage = unstablePkgs.opencloud.idp-web;
    address = vars.networking.loopbackIPv4;
    port = vars.networking.ports.opencloud;
    url = "https://${cloudHost}";
    stateDir = stateDir;
    environmentFile = adminEnvFile;
    environment = {
      OC_CONFIG_DIR = "${stateDir}/config";
      # Caddy is the only TLS terminator, so the proxy must speak plain HTTP on
      # the loopback port. PROXY_TLS defaults to true and is independent of
      # OC_INSECURE, which only relaxes certificate validation.
      PROXY_TLS = "false";
      OC_INSECURE = "true";
      OC_LOG_LEVEL = "info";
      # Kanidm is the identity provider; the built-in IDP is not used, while
      # the internal IDM/LDAP directory still autoprovisions OIDC users.
      OC_EXCLUDE_RUN_SERVICES = "idp";
      # The collaboration (WOPI) service is not started by `opencloud server`
      # by default; run it in-process so the web UI can open office documents.
      OC_ADD_RUN_SERVICES = "collaboration";
      OC_OIDC_ISSUER = vars.kanidmIssuer "opencloud-web";
      PROXY_OIDC_ACCESS_TOKEN_VERIFY_METHOD = "jwt";
      PROXY_OIDC_REWRITE_WELLKNOWN = "true";
      PROXY_USER_OIDC_CLAIM = "preferred_username";
      PROXY_USER_CS3_CLAIM = "username";
      PROXY_AUTOPROVISION_ACCOUNTS = "true";
      PROXY_ROLE_ASSIGNMENT_DRIVER = "oidc";
      PROXY_ROLE_ASSIGNMENT_OIDC_CLAIM = "opencloud_roles";
      GRAPH_ASSIGN_DEFAULT_USER_ROLE = "false";
      WEB_OIDC_CLIENT_ID = "opencloud-web";
      WEB_OIDC_SCOPE = "openid profile email opencloud_roles";
      # Every OpenCloud client shares the one public client so tokens carry a
      # single Kanidm issuer.
      WEBFINGER_WEB_OIDC_CLIENT_ID = "opencloud-web";
      WEBFINGER_WEB_OIDC_CLIENT_SCOPES = "openid profile email opencloud_roles";
      WEBFINGER_DESKTOP_OIDC_CLIENT_ID = "opencloud-web";
      WEBFINGER_DESKTOP_OIDC_CLIENT_SCOPES = "openid profile email offline_access opencloud_roles";
      WEBFINGER_ANDROID_OIDC_CLIENT_ID = "opencloud-web";
      WEBFINGER_ANDROID_OIDC_CLIENT_SCOPES = "openid profile email offline_access opencloud_roles";
      WEBFINGER_IOS_OIDC_CLIENT_ID = "opencloud-web";
      WEBFINGER_IOS_OIDC_CLIENT_SCOPES = "openid profile email offline_access opencloud_roles";
      # Non-collaborative PosixFS keeps a human-readable tree that only
      # OpenCloud writes; Filestash keeps serving the separate `_Files` tree.
      STORAGE_USERS_DRIVER = "posix";
      STORAGE_USERS_ID_CACHE_STORE = "nats-js-kv";
      STORAGE_USERS_POSIX_ROOT = "${stateDir}/storage";
      # The WOPI endpoint is served by the OpenCloud proxy on the cloud host;
      # Collabora reaches back to it and is itself served on the office host.
      COLLABORATION_WOPI_SRC = "https://${cloudHost}";
      COLLABORATION_APP_NAME = "Collabora";
      COLLABORATION_APP_PRODUCT = "Collabora";
      COLLABORATION_APP_ADDR = "https://${officeHost}";
      COLLABORATION_APP_INSECURE = "false";
      COLLABORATION_APP_PROOF_DISABLE = "true";
    };
  };

  # The upstream module writes the generated config under /etc/opencloud and
  # only lets its init unit write there. Keep the generated config on the data
  # pool instead so impermanence never discards OpenCloud's internal secrets.
  systemd.services.opencloud-init-config.serviceConfig.ReadWritePaths = lib.mkForce [ stateDir ];

  systemd.services.opencloud-init-config.requires = [ "opencloud-secret-materialize.service" ];
  systemd.services.opencloud-init-config.after = [ "opencloud-secret-materialize.service" ];
  systemd.services.opencloud.requires = [ "opencloud-secret-materialize.service" ];
  systemd.services.opencloud.after = [ "opencloud-secret-materialize.service" ];
}
