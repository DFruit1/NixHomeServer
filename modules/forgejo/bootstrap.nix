{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.forgejo;
  repoRoot = ../..;
  stateDir = "/var/lib/forgejo";
  ageHeader = "-----BEGIN AGE ENCRYPTED FILE-----";
  githubTokenEnabled = builtins.pathExists (repoRoot + "/secrets/forgejoGithubToken.age");
  mkSecretAssertions = secretNames:
    map
      (name:
        let
          secretPath = repoRoot + "/secrets/${name}.age";
          content = if builtins.pathExists secretPath then builtins.readFile secretPath else "";
        in
        {
          assertion =
            builtins.hasAttr name config.age.secrets
            && builtins.pathExists secretPath
            && content != ""
            && builtins.substring 0 (builtins.stringLength ageHeader) content == ageHeader;
          message = "Missing or invalid agenix secret '${name}'. Expected secrets/${name}.age to exist, be non-empty, and start with '${ageHeader}'. Stage cleartext at secrets/unencrypted/${name} if needed, then use nix run .#generate-secrets -- --identity /path/to/current/age.key.";
        })
      secretNames;
in
{
  config = lib.mkIf cfg.enable {
    assertions = mkSecretAssertions [ "forgejoClientSecret" ] ++ [
      {
        assertion = !githubTokenEnabled || builtins.hasAttr "forgejoGithubToken" config.age.secrets;
        message = "Forgejo found secrets/forgejoGithubToken.age but the agenix secret was not defined; check modules/Core_Modules/age/default.nix.";
      }
    ];

    # Forgejo keeps its external-auth sources in the database, so the Kanidm
    # OIDC source, secret, and admin group mapping are converged through the
    # admin CLI on boot and whenever the client secret changes.
    systemd.services.forgejo-oidc-bootstrap = {
      description = "Converge the Forgejo Kanidm OIDC authentication source";
      wantedBy = [ "multi-user.target" ];
      requires = [ "forgejo.service" ];
      after = [ "forgejo.service" ];
      before = [ "homepage-canary.service" ];
      restartTriggers = [ config.age.secrets.forgejoClientSecret.file ];
      path = with pkgs; [
        config.services.forgejo.package
        coreutils
        gawk
        gnugrep
      ];
      environment = {
        USER = "forgejo";
        HOME = stateDir;
        FORGEJO_WORK_DIR = stateDir;
        FORGEJO_CUSTOM = "${stateDir}/custom";
        FORGEJO_OIDC_NAME = "kanidm";
        FORGEJO_OIDC_CLIENT_ID = "forgejo-web";
        FORGEJO_OIDC_DISCOVERY_URL = vars.kanidmDiscoveryUrl "forgejo-web";
        FORGEJO_OIDC_SCOPES = "openid profile email";
        FORGEJO_OIDC_GROUP_CLAIM = "forgejo_role";
        FORGEJO_OIDC_ADMIN_GROUP = "admin";
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        User = "forgejo";
        Group = "forgejo";
        UMask = "0077";
        LoadCredential = [ "client-secret:${config.age.secrets.forgejoClientSecret.path}" ];
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        NoNewPrivileges = true;
        RestrictSUIDSGID = true;
        ReadWritePaths = [ stateDir ];
      };
      script = "bash ${./reconcile-oidc.sh}";
    };
  };
}
