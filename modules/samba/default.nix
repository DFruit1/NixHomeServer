{ pkgs, vars, config, ... }:

let
  kanidmPort = 8443;
  prepareUserWorkspace = pkgs.writeShellScript "prepare-samba-user-workspace" ''
    set -euo pipefail

    username="$1"
    root="${vars.usersWorkspaceRoot}/$username"
    files="$root/files"

    install -d -m 2770 -g users "$root"
    install -d -m 2770 -g users "$files"
  '';

  syncFileshareWorkspaces = pkgs.writeShellScript "sync-fileshare-workspaces" ''
    set -euo pipefail

    export HOME="$(mktemp -d)"
    trap 'rm -rf "$HOME"' EXIT
    export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"

    members_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs >/dev/null

      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        fileshare_users \
        -H https://localhost:${toString kanidmPort} \
        -D admin \
        --accept-invalid-certs \
        -o json
    )"

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      ${prepareUserWorkspace} "$username"
    done < <(
      printf '%s' "$members_json" \
        | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]'
    )
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
        "hosts allow" = "${vars.serverLanIP}/${toString vars.serverLanPrefixLength} 127.0.0.1";
        "interfaces" = "lo ${vars.netIface}";
        "bind interfaces only" = "yes";
        "disable spoolss" = "yes";
        "load printers" = "no";
        "printing" = "bsd";
        "printcap name" = "/dev/null";
        "smb encrypt" = "required";
        "invalid users" = [ "root" ];
      };

      data = {
        path = vars.dataRoot;
        "valid users" = vars.kanidmAdminUser;
        "admin users" = vars.kanidmAdminUser;
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
      };
    };
  };

  networking.firewall.interfaces.${vars.netIface}.allowedTCPPorts = [ 139 445 ];

  systemd.services.fileshare-workspace-sync = {
    description = "Create per-user fileshare workspaces from Kanidm group membership";
    wantedBy = [ "multi-user.target" ];
    wants = [ "kanidm.service" "local-fs.target" ];
    after = [ "kanidm.service" "local-fs.target" ];
    before = [ "copyparty.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${syncFileshareWorkspaces}
    '';
  };
}
