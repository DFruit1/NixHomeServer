{ pkgs, vars, ... }:

let
  prepareUserWorkspace = pkgs.writeShellScript "prepare-samba-user-workspace" ''
    set -euo pipefail

    username="$1"
    root="${vars.usersWorkspaceRoot}/$username"
    files="$root/files"

    install -d -m 0770 -g users "$root"
    install -d -m 0770 -g users "$files"
  '';
in
{
  services.samba = {
    enable = true;
    openFirewall = false;
    nmbd.enable = false;
    winbindd.enable = false;
    settings = {
      global = {
        "server role" = "standalone server";
        "security" = "user";
        "map to guest" = "never";
        "obey pam restrictions" = "yes";
        "pam password change" = "yes";
        "unix password sync" = "yes";
        "hosts allow" = "${vars.netbirdCidr} 127.0.0.1";
        "interfaces" = "lo ${vars.netbirdIface}";
        "bind interfaces only" = "yes";
        "disable spoolss" = "yes";
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
        "smb encrypt" = "required";
        "invalid users" = [ "root" ];
      };

      homes = {
        path = "${vars.usersWorkspaceRoot}/%U/files";
        "valid users" = "%U";
        "browseable" = "no";
        "read only" = "no";
        "guest ok" = "no";
        "force group" = "users";
        "create mask" = "0660";
        "directory mask" = "0770";
        "root preexec" = "${prepareUserWorkspace} %U";
      };

      exchange = {
        path = vars.sharedExchangeRoot;
        "valid users" = "@fileshare_users";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "force group" = "users";
        "create mask" = "0664";
        "directory mask" = "0775";
      };

      public = {
        path = vars.sharedPublicRoot;
        "valid users" = "@fileshare_users";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "force group" = "users";
        "create mask" = "0664";
        "directory mask" = "0775";
      };

      "photos-upload" = {
        path = vars.photosUploadRoot;
        "valid users" = "@fileshare_users";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "force group" = "immich";
        "create mask" = "0660";
        "directory mask" = "2770";
      };

      "documents-upload" = {
        path = vars.documentsUploadRoot;
        "valid users" = "@fileshare_users";
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
        "force group" = "paperless";
        "create mask" = "0660";
        "directory mask" = "2770";
      };
    };
  };

  networking.firewall.interfaces.${vars.netbirdIface}.allowedTCPPorts = [ 139 445 ];
}
