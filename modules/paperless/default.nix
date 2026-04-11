{ lib, config, pkgs, vars, ... }:

let
  # Keep the Node 22 frontend workaround, but patch out the exact pnpm
  # packageManager pin that causes corepack/pnpm to fetch from the network
  # during builds.
  patchedPaperlessFetchFromGitHub =
    args:
    pkgs.runCommand "${args.repo}-${lib.replaceStrings ["/"] ["-"] args.tag}-patched"
      {
        nativeBuildInputs = [ pkgs.jq ];
        src = pkgs.fetchFromGitHub args;
      }
      ''
        cp -a "$src" "$out"
        chmod -R +w "$out"
        jq 'del(.packageManager)' "$out/src-ui/package.json" > "$out/src-ui/package.json.tmp"
        mv "$out/src-ui/package.json.tmp" "$out/src-ui/package.json"
      '';

  paperlessPackage = pkgs.callPackage "${pkgs.path}/pkgs/by-name/pa/paperless-ngx/package.nix" {
    fetchFromGitHub = patchedPaperlessFetchFromGitHub;
    nodejs_20 = pkgs.nodejs_22;
  };
in

{
  users.users.paperless = {
    isSystemUser = true;
    group = "paperless";
    home = "${vars.dataRoot}/paperless";
  };

  users.groups.paperless = { };

  ######################################################################
  ## Paperless-ngx (services.paperless)
  ######################################################################
  services.paperless = {
    enable = true;
    dataDir = "${vars.dataRoot}/paperless";
    address = "127.0.0.1";
    port = vars.paperlessPort;
    package = paperlessPackage;

    settings = {
      ##################################################################
      # 1.  Social / OIDC login
      ##################################################################
      PAPERLESS_SOCIAL_LOGIN_ENABLED = "true";
      PAPERLESS_SOCIAL_AUTO_SIGNUP = "true";
      PAPERLESS_SOCIAL_DEFAULT_GROUPS = "Users";

      PAPERLESS_OIDC_CLIENT_ID = "paperless-web";
      PAPERLESS_OIDC_CLIENT_SECRET_FILE = config.age.secrets.paperlessClientSecret.path;
      PAPERLESS_OIDC_PROVIDER_URL = vars.kanidmIssuer "paperless-web";

      ##################################################################
      # 2.  Misc instance tweaks
      ##################################################################
      PAPERLESS_ALLOWED_HOSTS = "paperless.${vars.domain}";
      # PAPERLESS_TIME_ZONE              = "Australia/Sydney";   # ← example
      # PAPERLESS_LOGLEVEL               = "INFO";
    };
  };

  systemd.tmpfiles.rules = [
    "d ${vars.dataRoot}/paperless 0750 paperless paperless -"
  ];

  systemd.services."paperless-web".serviceConfig.AppArmorProfile = "generated-paperless-web";
}
