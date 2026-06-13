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
  config = {
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
