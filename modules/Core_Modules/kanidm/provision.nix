{ config, lib, pkgs, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  hasModule = name: config.nixhomeserver.modules.${name} or false;
  moduleEnabled = name: hasModule name && (config.repo.${name}.enable or true);
  homepageEnabled = hasModule "homepage";
  seerrEnabled = moduleEnabled "seerr";
  mediaAutomationEnabled = lib.any moduleEnabled [ "sonarr" "radarr" "prowlarr" "qbittorrent" "seerr" ];
  portalHost = if homepageEnabled then "homepage.${vars.domain}" else vars.kanidmDomain;
  appPersonNames = lib.unique (
    vars.kanidmAppUsers
    ++ vars.kanidmAppAdminUsers
    ++ vars.kanidmBackupUsers
    ++ (vars.monitoringAccess.users or [ ])
    ++ (vars.filesSftpUsers or [ ])
    ++ lib.optionals seerrEnabled (vars.seerrRequestManagers or [ ])
    ++ (vars.fileAccess.usbUsers or [ ])
  );
  adminMailAddresses =
    if vars.kanidmAdminMailAddresses != [ ] then
      vars.kanidmAdminMailAddresses
    else
      [ vars.kanidmAdminEmail ];
  mkAppPerson = user: {
    displayName = user;
  } // lib.optionalAttrs (builtins.hasAttr user vars.kanidmAppUserEmails) {
    mailAddresses = [ vars.kanidmAppUserEmails.${user} ];
  };
  mkManualGroup =
    members:
    {
      inherit members;
      overwriteMembers = false;
    };
  backupAccessGroups = {
    ${vars.backupAccess.adminGroup} = mkManualGroup vars.kanidmBackupUsers;
  } // lib.optionalAttrs (vars.backupAccess.storageGroup != vars.backupAccess.adminGroup) {
    ${vars.backupAccess.storageGroup} = mkManualGroup vars.kanidmBackupUsers;
  };
  delegatedOperatorGroups = [
    "idm_account_policy_admins"
    "idm_group_admins"
    "idm_oauth2_admins"
    "idm_people_admins"
    "idm_people_on_boarding"
    "idm_people_pii_read"
    "idm_unix_admins"
  ];
  delegatedOperatorGroupDescriptions = lib.genAttrs delegatedOperatorGroups (group:
    "Kanidm delegated operator group used for ${group} workflows."
  );
  coreKanidmGroupDescriptions = {
    "domain_admins" = "Builtin domain-wide administrative group used by platform administration.";
    "users" = "Baseline group for normal users and standard identity resolution.";
    "app-admin" = "Grants application admin access for app surfaces that trust the app-admin group.";
    "${vars.monitoringAccess.group}" = "Grants access to the monitoring dashboard without application-admin privileges.";
    "${vars.fileAccess.webAccessGroup}" = "Grants browser file access and personal file-root provisioning.";
    "${vars.fileAccess.sftpAccessGroup}" = "Grants access to the dedicated SFTP endpoint.";
    "${vars.fileAccess.sharedAccessGroup}" = "Grants access to the shared files view.";
    "${vars.fileAccess.usbAccessGroup}" = "Grants access to the mounted USB files view.";
    "${vars.backupAccess.adminGroup}" = "Grants backup administration access.";
  } // delegatedOperatorGroupDescriptions // lib.optionalAttrs (vars.backupAccess.storageGroup != vars.backupAccess.adminGroup) {
    "${vars.backupAccess.storageGroup}" = "Grants read access to encrypted backup repository files.";
  };
  appKanidmGroupDescriptions =
    lib.optionalAttrs (hasModule "audiobookshelf")
      {
        "audiobookshelf-users" = "Grants Audiobookshelf sign-in.";
      }
    // lib.optionalAttrs (hasModule "youtube-downloader") {
      "downloads-users" = "Grants YouTube Downloader access.";
    }
    // lib.optionalAttrs (hasModule "immich") {
      "immich-users" = "Grants Immich photo library access.";
    }
    // lib.optionalAttrs (hasModule "jellyfin") {
      "jellyfin-users" = "Grants Jellyfin managed account access.";
    }
    // lib.optionalAttrs (hasModule "kavita") {
      "kavita-users" = "Grants Kavita books and comics access.";
    }
    // lib.optionalAttrs (moduleEnabled "kiwix") {
      "kiwix-users" = "Grants Kiwix offline wiki access.";
    }
    // lib.optionalAttrs (hasModule "mail-archive-ui") {
      "mail-archive-users" = "Grants private mail archive access.";
    }
    // lib.optionalAttrs mediaAutomationEnabled {
      "media-automation-users" = "Grants Sonarr, Radarr, Prowlarr, qBittorrent, and request-manager access.";
    }
    // lib.optionalAttrs (hasModule "paperless") {
      "paperless-users" = "Grants Paperless document archive access.";
    }
    // lib.optionalAttrs seerrEnabled {
      "${vars.seerrRequestManagerGroup}" = "Grants Seerr request approval and rejection permissions.";
    };
  kanidmGroupDescriptions = coreKanidmGroupDescriptions // appKanidmGroupDescriptions;
  authGatewayScopeGroups = lib.unique (
    [
      "users"
      "app-admin"
      vars.monitoringAccess.group
      vars.fileAccess.webAccessGroup
      vars.fileAccess.usbAccessGroup
      vars.backupAccess.adminGroup
      vars.backupAccess.storageGroup
    ]
    ++ lib.optionals (hasModule "youtube-downloader") [ "downloads-users" ]
    ++ lib.optionals (moduleEnabled "kiwix") [ "kiwix-users" ]
    ++ lib.optionals (hasModule "mail-archive-ui") [ "mail-archive-users" ]
    ++ lib.optionals mediaAutomationEnabled [ "media-automation-users" ]
  );
  personIdentityRecords =
    (lib.genAttrs appPersonNames mkAppPerson)
    // {
      ${vars.kanidmAdminUser} = {
        displayName = vars.kanidmAdminUser;
        mailAddresses = adminMailAddresses;
      };
    };
  mkMailArgs = mailAddresses:
    lib.concatMapStringsSep " " (mail: "--mail ${lib.escapeShellArg mail}") mailAddresses;
  mkPersonIdentityReconcile = name:
    let
      person = personIdentityRecords.${name};
      mailArgs = mkMailArgs (person.mailAddresses or [ ]);
    in
    ''
      if kanidm person get \
          -H ${kanidmCliUrl} \
          -D idm_admin \
          ${lib.escapeShellArg name} >/dev/null; then
        kanidm person update \
          -H ${kanidmCliUrl} \
          -D idm_admin \
          ${lib.escapeShellArg name} \
          --displayname ${lib.escapeShellArg person.displayName} \
          ${mailArgs}
      fi
    '';
  kanidmIdentityReconcilePath = with pkgs; [
    kanidm_1_10
  ];
in
{
  options.nixhomeserver.kanidmGroupDescriptions = lib.mkOption {
    type = lib.types.attrsOf lib.types.str;
    default = { };
    description = "Machine-readable map of Kanidm group names to descriptions.";
  };

  config = {
    nixhomeserver.kanidmGroupDescriptions = kanidmGroupDescriptions;

    services.kanidm.provision = {
      enable = true;
      autoRemove = false;
      idmAdminPasswordFile = config.age.secrets.kanidmAdminPass.path;
      adminPasswordFile = config.age.secrets.kanidmSysAdminPass.path;
      instanceUrl = kanidmCliUrl;

      persons = personIdentityRecords;

      groups = {
        # Keep the builtin group in the provision inventory so post-start
        # reconciliation does not try to delete it as an orphaned entity.
        "domain_admins" = mkManualGroup [ ];
      } // lib.genAttrs delegatedOperatorGroups (_: mkManualGroup [ vars.kanidmAdminUser ]) // {
        "app-admin" = mkManualGroup vars.kanidmAppAdminUsers;
        ${vars.monitoringAccess.group} = mkManualGroup vars.monitoringAccess.users;
        ${vars.fileAccess.webAccessGroup} = mkManualGroup vars.kanidmAppUsers;
        ${vars.fileAccess.sftpAccessGroup} = mkManualGroup (vars.filesSftpUsers or [ ]);
        ${vars.fileAccess.sharedAccessGroup} = mkManualGroup [ ];
        ${vars.fileAccess.usbAccessGroup} = mkManualGroup (vars.fileAccess.usbUsers or [ ]);
        users = mkManualGroup vars.kanidmAppUsers;
      } // backupAccessGroups // lib.optionalAttrs seerrEnabled {
        ${vars.seerrRequestManagerGroup} = mkManualGroup vars.seerrRequestManagers;
      };

      systems.oauth2.auth-gateway-web = {
        displayName = "NixHomeServer";
        imageFile = ./assets/portal.svg;
        originUrl = "https://${config.repo.authGateway.domain}/oauth2/callback";
        originLanding = "https://${portalHost}";
        basicSecretFile = config.age.secrets.oauth2ProxyClientSecret.path;
        preferShortUsername = true;
        scopeMaps = lib.genAttrs authGatewayScopeGroups (_: [ "openid" "profile" "email" "groups_name" ]);
      };
    };

    systemd.services.kanidm-identity-reconcile = {
      description = "Reconcile configured Kanidm usernames and mail addresses";
      wantedBy = [ "multi-user.target" ];
      after = [ "kanidm.service" ];
      wants = [ "kanidm.service" ];
      path = kanidmIdentityReconcilePath;
      script = ''
        set -euo pipefail

        export HOME="$(mktemp -d)"
        trap 'rm -rf "$HOME"' EXIT
        KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
        export KANIDM_PASSWORD

        kanidm login \
          -H ${kanidmCliUrl} \
          -D idm_admin >/dev/null

        ${lib.concatMapStringsSep "\n" mkPersonIdentityReconcile (builtins.attrNames personIdentityRecords)}
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
