{ lib, pkgs, vars, config, ... }:

let
  kanidmPort = 8443;
  userContentSubdirs = lib.escapeShellArgs vars.userContentSubdirs;
  userBooksSubdirs = lib.escapeShellArgs vars.userBooksSubdirs;
  kavitaWritablePaths = lib.concatMapStringsSep " \\\n      " (name: ''"$root/books/${name}"'') vars.userBooksSubdirs;
  prepareUserWorkspace = pkgs.writeShellScript "prepare-samba-user-workspace" ''
    set -euo pipefail

    username="$1"
    root="${vars.usersWorkspaceRoot}/$username"
    legacy_mail_root="${vars.dataRoot}/mail-archive/users/$username"
    emails="$root/emails"

    install -d -m 2770 -g users "$root"
    for name in ${userContentSubdirs}; do
      [[ "$name" == "emails" ]] && continue
      install -d -m 2770 -g users "$root/$name"
    done
    for name in ${userBooksSubdirs}; do
      install -d -m 2770 -g users "$root/books/$name"
    done

    if [[ -L "$emails" ]]; then
      legacy_symlink_target="$(readlink -f "$emails" || true)"
      rm -f "$emails"
      install -d -m 0770 -o mail-archive-ui -g mail-archive-ui "$emails"
      if [[ -n "$legacy_symlink_target" && -d "$legacy_symlink_target" ]]; then
        ${pkgs.rsync}/bin/rsync -a --ignore-existing "$legacy_symlink_target"/ "$emails"/
      fi
    elif [[ -e "$emails" ]]; then
      [[ -d "$emails" ]] || {
        echo "Refusing to replace existing non-directory path: $emails" >&2
        exit 1
      }
      install -d -m 0770 -o mail-archive-ui -g mail-archive-ui "$emails"
    else
      install -d -m 0770 -o mail-archive-ui -g mail-archive-ui "$emails"
    fi

    if [[ -d "$legacy_mail_root" ]]; then
      ${pkgs.rsync}/bin/rsync -a --ignore-existing "$legacy_mail_root"/ "$emails"/
    fi
    chown -R mail-archive-ui:mail-archive-ui "$emails"

    ${pkgs.acl}/bin/setfacl \
      -m g:kavita-media:--x \
      -m g:mail-archive-ui:--x \
      -m g:immich:--x \
      -m g:paperless:--x \
      "$root"
    ${pkgs.acl}/bin/setfacl \
      -m g:audiobookshelf-media:rwx \
      -m d:g:audiobookshelf-media:rwx \
      "$root"

    apply_recursive_acl() {
      local access_spec="$1"
      local default_spec="$2"
      shift
      shift

      for path in "$@"; do
        [[ -d "$path" ]] || continue
        ${pkgs.acl}/bin/setfacl -R -m "$access_spec" "$path"
        ${pkgs.findutils}/bin/find "$path" -type d -exec ${pkgs.acl}/bin/setfacl -m "$default_spec" '{}' +
      done
    }

    apply_writable_acl() {
      local group_name="$1"
      shift

      apply_recursive_acl "g:''${group_name}:rwX" "d:g:''${group_name}:rwx" "$@"
    }

    apply_readonly_acl() {
      local group_name="$1"
      shift

      apply_recursive_acl "g:''${group_name}:r-X" "d:g:''${group_name}:r-x" "$@"
    }

    apply_writable_acl audiobookshelf-media "$root/audiobooks"
    apply_writable_acl kavita-media \
      "$root/books" \
      ${kavitaWritablePaths}

    apply_readonly_acl immich "$root/photos"
    apply_readonly_acl paperless "$root/documents"
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
    description = "Create per-user fileshare content roots from Kanidm group membership";
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
