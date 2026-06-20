{ config, lib, pkgs, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  appPersonNames = lib.unique (
    vars.kanidmAppUsers
    ++ vars.kanidmAppAdminUsers
    ++ vars.kanidmBackupUsers
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
  kanidmGroupDescriptions = {
    "domain_admins" = "Builtin domain-wide administrative group used by platform administration.";
    "users" = "Baseline group for normal users and standard identity resolution.";
    "app-admin" = "Grants application admin access for app surfaces that trust the app-admin group.";
    "audiobookshelf-users" = "Grants Audiobookshelf sign-in.";
    "downloads-users" = "Grants YouTube Downloader access.";
    "immich-users" = "Grants Immich photo library access.";
    "jellyfin-users" = "Grants Jellyfin managed account access.";
    "kavita-users" = "Grants Kavita books and comics access.";
    "kiwix-users" = "Grants Kiwix offline wiki access.";
    "mail-archive-users" = "Grants private mail archive access.";
    "media-automation-users" = "Grants Sonarr, Radarr, Prowlarr, qBittorrent, and request-manager access.";
    "paperless-users" = "Grants Paperless document archive access.";
    "${vars.fileAccess.webAccessGroup}" = "Grants browser file access and personal file-root provisioning.";
    "${vars.fileAccess.sftpAccessGroup}" = "Grants access to the dedicated SFTP endpoint.";
    "${vars.fileAccess.sharedAccessGroup}" = "Grants access to the shared files view.";
    "${vars.fileAccess.usbAccessGroup}" = "Grants access to the mounted USB files view.";
    "${vars.backupAccess.adminGroup}" = "Grants backup administration access.";
  } // delegatedOperatorGroupDescriptions // lib.optionalAttrs (vars.backupAccess.storageGroup != vars.backupAccess.adminGroup) {
    "${vars.backupAccess.storageGroup}" = "Grants read access to encrypted backup repository files.";
  };
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
    default = {};
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
        ${vars.fileAccess.webAccessGroup} = mkManualGroup vars.kanidmAppUsers;
        ${vars.fileAccess.sftpAccessGroup} = mkManualGroup (vars.filesSftpUsers or [ ]);
        ${vars.fileAccess.sharedAccessGroup} = mkManualGroup [ ];
        ${vars.fileAccess.usbAccessGroup} = mkManualGroup (vars.fileAccess.usbUsers or [ ]);
        users = mkManualGroup vars.kanidmAppUsers;
      } // backupAccessGroups;
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
