{ lib, pkgs, vars, config, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  userFilesGroup = "user-files";
  sharedFilesReadOnlyGroup = "shared-files-ro";
  sharedFilesReadWriteGroup = "shared-files-rw";
  sharedContentRoots = [
    "${vars.sharedRoot}/files"
    vars.sharedAudiobooksRoot
    vars.sharedBooksRoot
    vars.sharedEmailsRoot
    vars.sharedVideosRoot
  ];
  escapedSharedContentRoots = lib.escapeShellArgs sharedContentRoots;
  sambaPersonalUsers = "@${userFilesGroup}";
  sambaSharedUsers = "@${sharedFilesReadOnlyGroup} @${sharedFilesReadWriteGroup}";
  userContentSubdirs = lib.escapeShellArgs vars.userContentSubdirs;
  userBooksSubdirs = lib.escapeShellArgs vars.userBooksSubdirs;
  kavitaWritablePaths = lib.concatMapStringsSep " \\\n      " (name: ''"$root/books/${name}"'') vars.userBooksSubdirs;
  prepareUserRoot = pkgs.writeShellScript "prepare-samba-user-root" ''
    set -euo pipefail

    username="$1"
    root="${vars.usersRoot}/$username"
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

  syncFileshareUserRoots = pkgs.writeShellScript "sync-fileshare-user-roots" ''
    set -euo pipefail

    export HOME="$(mktemp -d)"
    trap 'rm -rf "$HOME"' EXIT
    export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmSysAdminPass.path})"

    members_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H ${kanidmCliUrl} \
        -D admin >/dev/null

      collect_group_members() {
        local group_name="$1"

        ${pkgs.kanidm_1_9}/bin/kanidm group get \
          "$group_name" \
          -H ${kanidmCliUrl} \
          -D admin \
          -o json \
          | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]'
      }

      {
        collect_group_members ${lib.escapeShellArg userFilesGroup}
      } | ${pkgs.coreutils}/bin/sort -u
    )"

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      ${prepareUserRoot} "$username"
    done <<<"$members_json"
  '';

  syncSharedFilesAccess = pkgs.writeShellScript "sync-shared-files-access" ''
    set -euo pipefail

    apply_top_level_acls() {
      local root="$1"

      chmod g+s "$root"
      chmod +t "$root"
      ${pkgs.acl}/bin/setfacl \
        -m g:${sharedFilesReadOnlyGroup}:r-x \
        -m g:${sharedFilesReadWriteGroup}:rwx \
        -m d:g:${sharedFilesReadOnlyGroup}:r-x \
        -m d:g:${sharedFilesReadWriteGroup}:r-x \
        "$root"
    }

    apply_descendant_dir_acls() {
      local path="$1"

      ${pkgs.acl}/bin/setfacl \
        -m g:${sharedFilesReadOnlyGroup}:r-x \
        -m g:${sharedFilesReadWriteGroup}:r-x \
        -m d:g:${sharedFilesReadOnlyGroup}:r-x \
        -m d:g:${sharedFilesReadWriteGroup}:r-x \
        "$path"
    }

    apply_descendant_file_acls() {
      local path="$1"

      ${pkgs.acl}/bin/setfacl \
        -m g:${sharedFilesReadOnlyGroup}:r-- \
        -m g:${sharedFilesReadWriteGroup}:r-- \
        "$path"
    }

    for root in ${escapedSharedContentRoots}; do
      [[ -d "$root" ]] || continue
      apply_top_level_acls "$root"

      while IFS= read -r -d "" path; do
        apply_descendant_dir_acls "$path"
      done < <(
        ${pkgs.findutils}/bin/find \
          "$root" \
          -mindepth 1 \
          \( -type d -name .hist \) -prune -o \
          -type d -print0
      )

      while IFS= read -r -d "" path; do
        apply_descendant_file_acls "$path"
      done < <(
        ${pkgs.findutils}/bin/find \
          "$root" \
          -mindepth 1 \
          \( -type d -name .hist \) -prune -o \
          -type f -print0
      )
    done
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

      personal = {
        path = "${vars.usersRoot}/%U";
        "valid users" = sambaPersonalUsers;
        "browseable" = "yes";
        "read only" = "no";
        "guest ok" = "no";
      };

      shared = {
        path = vars.sharedRoot;
        "valid users" = sambaSharedUsers;
        "write list" = "@shared-files-rw";
        "browseable" = "yes";
        "read only" = "yes";
        "guest ok" = "no";
        "hide dot files" = "yes";
        "inherit acls" = "yes";
        "create mask" = "0640";
        "force create mode" = "0640";
        "directory mask" = "2750";
        "force directory mode" = "2750";
        "veto files" = "/.hist/";
      };
    };
  };

  networking.firewall.interfaces.${vars.netIface}.allowedTCPPorts = [ 139 445 ];

  systemd.services.fileshare-user-root-sync = {
    description = "Create per-user fileshare content roots from Kanidm group membership";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "data-pool-layout.service"
      "kanidm.service"
      "kanidm-files-posix-groups.service"
      "local-fs.target"
    ];
    after = [
      "data-pool-layout.service"
      "kanidm.service"
      "kanidm-files-posix-groups.service"
      "local-fs.target"
    ];
    before = [ "copyparty.service" ];
    serviceConfig = {
      Type = "oneshot";
    };
    script = ''
      ${syncFileshareUserRoots}
    '';
  };

  systemd.services.shared-files-access-sync = {
    description = "Converge shared-root ACLs for Samba shared access groups";
    wantedBy = [ "multi-user.target" ];
    wants = [
      "data-pool-layout.service"
      "kanidm-files-posix-groups.service"
      "kanidm-unixd.service"
      "local-fs.target"
    ];
    after = [
      "data-pool-layout.service"
      "kanidm-files-posix-groups.service"
      "kanidm-unixd.service"
      "local-fs.target"
    ];
    before = [ "samba-smbd.service" ];
    serviceConfig.Type = "oneshot";
    script = ''
      ${syncSharedFilesAccess}
    '';
  };

  systemd.services.samba-smbd = {
    wants = [
      "kanidm-files-posix-groups.service"
      "shared-files-access-sync.service"
    ];
    after = [
      "kanidm-files-posix-groups.service"
      "shared-files-access-sync.service"
    ];
  };
}
