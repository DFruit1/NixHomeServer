{ config, lib, vars, ... }:

let
  cfg = vars.offlineMedia;
  enabled = cfg.enable or false;
  accessGroupRaw = cfg.accessGroup or "users";
  nameValidation = import ../../lib/name-validation.nix { inherit lib; };
  accessGroupValid = nameValidation.validKanidmGroup accessGroupRaw;
  accessGroup = if accessGroupValid then accessGroupRaw else "invalid-offline-media-access-group";
  customAccessGroup = accessGroup != "users";

  # A dedicated offline-media group is intentionally manual/additive.  It is
  # not allowed to alias another role because doing so would either broaden
  # offline-media access or change an exactly reconciled app/backup group into
  # a manual group when the Nix definitions merge.
  reservedAccessGroups = lib.unique [
    "admin-backups"
    "app-admin"
    "audiobookshelf-users"
    "domain_admins"
    "downloads-users"
    "idm_account_policy_admins"
    "idm_group_admins"
    "idm_oauth2_admins"
    "idm_people_admins"
    "idm_people_on_boarding"
    "idm_people_pii_read"
    "idm_unix_admins"
    "immich-users"
    "jellyfin-users"
    "kavita-users"
    "kiwix-users"
    "mail-archive-users"
    "media-automation-users"
    "paperless-users"
    "system_admins"
    "user-files"
    vars.backupAdminGroup
    vars.backupStorageGroup
    vars.fileAccess.localSftpAccessGroup
    vars.fileAccess.sharedAccessGroup
    vars.fileAccess.sftpAccessGroup
    vars.fileAccess.usbAccessGroup
    vars.fileAccess.webAccessGroup
    vars.monitoringAccessGroup
  ];
  accessGroupCollision =
    accessGroupValid
    && customAccessGroup
    && builtins.elem accessGroup reservedAccessGroups;
  oauthScopes = [ "openid" "profile" "email" "groups_name" ];
in
{
  config = lib.mkIf enabled (lib.mkMerge [
    {
      assertions = [
        {
          assertion = accessGroupValid;
          message = "offlineMedia.accessGroup must be a valid lowercase Kanidm group name (start with a letter; then letters, digits, dot, underscore, or hyphen; maximum 64 characters).";
        }
        {
          assertion = !accessGroupCollision;
          message = "offlineMedia.accessGroup '${accessGroup}' collides with a reserved, file-access, application, or exactly managed backup group; use 'users' or a new dedicated group name such as 'offline-media-users'.";
        }
      ];
    }

    (lib.mkIf (accessGroupValid && customAccessGroup && !accessGroupCollision) {
      services.kanidm.provision.groups.${accessGroup} = {
        members = [ ];
        overwriteMembers = false;
      };

      nixhomeserver.kanidmGroupDescriptions.${accessGroup} =
        "Grants offline-media device enrollment in addition to required baseline users membership.";

      # The shared gateway and Homepage sidecar use separate clients.  Both
      # tokens must carry the custom claim so Homepage can enforce the
      # additive users + offline-media role boundary in either auth mode.
      services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps.${accessGroup} = oauthScopes;
      services.kanidm.provision.systems.oauth2.homepage-web.scopeMaps =
        lib.mkIf (config.nixhomeserver.modules.homepage or false) {
          ${accessGroup} = oauthScopes;
        };
    })
  ]);
}
