{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.storage.userRoots;
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  webAccessGroup = vars.fileAccess.webAccessGroup or "user-files";
  sftpAccessGroup = vars.fileAccess.sftpAccessGroup or "files-sftp-users";
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  sharedMountName = vars.fileAccess.sharedMountName or "_Shared";
  sftpChrootBase = vars.fileAccess.sftpChrootBase or "/srv/files-sftp/chroots";
  memberGroups = lib.unique (cfg.memberGroups ++ [
    webAccessGroup
    sftpAccessGroup
  ]);
  userContentSubdirs = lib.escapeShellArgs cfg.contentSubdirs;
  userBooksSubdirs = lib.escapeShellArgs cfg.bookSubdirs;
  userVideoSubdirs = lib.escapeShellArgs cfg.videoSubdirs;
  userBookWritablePaths = lib.concatMapStringsSep " \\\n      " (name: ''"$root/books/${name}"'') cfg.bookSubdirs;
  fileshareUserRootSyncPath = with pkgs; [
    acl
    coreutils
    findutils
    getent
    jq
    kanidm_1_9
    systemd
    util-linux
  ];

  mkPerUserDirCommand =
    { root
    , relativePath
    , mode
    , user
    , group
    ,
    }:
    let
      pathExpr =
        if relativePath == "" then
          ''${lib.escapeShellArg root}/"$username"''
        else
          ''${lib.escapeShellArg root}/"$username"/${lib.escapeShellArg relativePath}'';
    in
    ''
      install -d -m ${mode} -o ${user} -g ${group} ${pathExpr}
    '';

  mkRootPathArg = relativePath:
    if relativePath == "" then
      ''"$root"''
    else
      ''"$root"/${lib.escapeShellArg relativePath}'';

  mkRecursiveGrant =
    grantFn:
    { group
    , relativePaths
    ,
    }:
    ''
      ${grantFn} ${lib.escapeShellArg group} ${
        lib.concatMapStringsSep " \\\n      " mkRootPathArg relativePaths
      }
    '';

  perUserDirectoryScript = lib.concatStringsSep "\n" (map mkPerUserDirCommand cfg.perUserDirectories);
  recursiveWritableGrantScript = lib.concatStringsSep "\n" (map (mkRecursiveGrant "apply_writable_acl") cfg.recursiveWritableGrants);
  recursiveReadonlyGrantScript = lib.concatStringsSep "\n" (map (mkRecursiveGrant "apply_readonly_acl") cfg.recursiveReadonlyGrants);
  recursiveDirectoryNoAccessGrantScript =
    lib.concatStringsSep "\n" (map (mkRecursiveGrant "apply_directory_noaccess_acl") cfg.recursiveDirectoryNoAccessGrants);

  prepareUserRoot = pkgs.writeShellScript "prepare-fileshare-user-root" ''
    set -euo pipefail

    username="$1"
    root="${vars.usersRoot}/$username"

    install -d -m 0750 -o root -g root "$root"
    chown root:root "$root"
    chmod 0750 "$root"
    for name in ${userContentSubdirs}; do
      [[ "$name" == "emails" ]] && continue
      install -d -m 0700 -o "$username" -g root "$root/$name"
      chown "$username":root "$root/$name"
      chmod 0700 "$root/$name"
    done
    for name in ${userVideoSubdirs}; do
      install -d -m 0700 -o "$username" -g root "$root/videos/$name"
      chown "$username":root "$root/videos/$name"
      chmod 0700 "$root/videos/$name"
    done
    for name in ${userBooksSubdirs}; do
      install -d -m 0700 -o "$username" -g root "$root/books/$name"
      chown "$username":root "$root/books/$name"
      chmod 0700 "$root/books/$name"
      install -d -m 0700 -o "$username" -g root "$root/books/$name/_Anon"
      chown "$username":root "$root/books/$name/_Anon"
      chmod 0700 "$root/books/$name/_Anon"
    done

    ${perUserDirectoryScript}

    user_owned_paths=(
      "$root/uploads"
      "$root/files"
      "$root/documents"
      "$root/photos"
      "$root/audiobooks"
      "$root/videos"
      "$root/books"
      ${userBookWritablePaths}
    )
    for path in "''${user_owned_paths[@]}"; do
      [[ -d "$path" ]] || continue
      chown -R "$username":root "$path"
      chmod u+rwX,go-rwx "$path"
    done
    if [[ -d "$root/emails" ]]; then
      ${pkgs.acl}/bin/setfacl -R -m "u:''${username}:r-X" "$root/emails"
      ${pkgs.findutils}/bin/find "$root/emails" -type d -exec ${pkgs.acl}/bin/setfacl -m "d:u:''${username}:r-x" '{}' +
      if [[ -d "$root/emails/.internal-sync" ]]; then
        ${pkgs.findutils}/bin/find "$root/emails/.internal-sync" -type d -exec ${pkgs.acl}/bin/setfacl \
          -m "u:''${username}:---" \
          -m "d:u:''${username}:---" \
          '{}' +
      fi
    fi

    root_acl_args=(
      -m u::rwx
      -m g::r-x
      -m o::---
      -m m::rwx
      -m "u:''${username}:r-x"
      -m d:u::rwx
      -m d:g::r-x
      -m d:o::---
      -m d:m::rwx
    )
    for group_name in ${lib.escapeShellArgs cfg.rootTraverseGroups}; do
      root_acl_args+=(-m "g:''${group_name}:--x")
    done
    for group_name in ${lib.escapeShellArgs cfg.rootWritableGroups}; do
      root_acl_args+=(-m "g:''${group_name}:rwx" -m "d:g:''${group_name}:rwx")
    done
    ${pkgs.acl}/bin/setfacl "''${root_acl_args[@]}" "$root"

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

    apply_directory_noaccess_acl() {
      local group_name="$1"
      shift

      for path in "$@"; do
        [[ -d "$path" ]] || continue
        ${pkgs.findutils}/bin/find "$path" -type d -exec ${pkgs.acl}/bin/setfacl \
          -m "g:''${group_name}:---" \
          -m "d:g:''${group_name}:---" \
          '{}' +
      done
    }

    ${recursiveWritableGrantScript}
    ${recursiveReadonlyGrantScript}
    ${recursiveDirectoryNoAccessGrantScript}
  '';

  syncFileshareUserRoots = pkgs.writeShellScript "sync-fileshare-user-roots" ''
    set -euo pipefail

    export HOME="$(mktemp -d)"
    trap 'rm -rf "$HOME"' EXIT
    KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"
    export KANIDM_PASSWORD

    group_members() {
      local group_name="$1"

      if group_json="$(
        ${pkgs.kanidm_1_9}/bin/kanidm group get \
          "$group_name" \
          -H ${kanidmCliUrl} \
          -D idm_admin \
          -o json
      )"; then
        printf '%s\n' "$group_json" | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]'
      fi
    }

    service_instance() {
      local template="$1"
      local username="$2"

      ${pkgs.systemd}/bin/systemd-escape --template="$template" "$username"
    }

    ensure_posix_account() {
      local username="$1"

      ${pkgs.kanidm_1_9}/bin/kanidm person posix set \
        "$username" \
        --shell ${lib.escapeShellArg "${pkgs.bashInteractive}/bin/bash"} \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null
    }

    wait_for_unix_user() {
      local username="$1"

      for _ in $(seq 1 20); do
        if ${pkgs.getent}/bin/getent passwd "$username" >/dev/null; then
          return 0
        fi
        sleep 1
      done

      echo "Kanidm user '$username' was POSIX-enabled but is not visible through NSS yet" >&2
      return 1
    }

    apply_shared_root_acl() {
      if [[ ! -d ${lib.escapeShellArg vars.sharedRoot} ]]; then
        return
      fi

      ${pkgs.acl}/bin/setfacl \
        -m u::rwx \
        -m g::r-x \
        -m o::--- \
        -m m::rwx \
        -m g:${lib.escapeShellArg sharedAccessGroup}:rwx \
        -m d:u::rwx \
        -m d:g::r-x \
        -m d:o::--- \
        -m d:m::rwx \
        -m d:g:${lib.escapeShellArg sharedAccessGroup}:rwx \
        ${lib.escapeShellArg vars.sharedRoot}
      ${pkgs.findutils}/bin/find ${lib.escapeShellArg vars.sharedRoot} -type d -exec ${pkgs.acl}/bin/setfacl \
        -m g:${lib.escapeShellArg sharedAccessGroup}:rwx \
        -m d:g:${lib.escapeShellArg sharedAccessGroup}:rwx \
        '{}' +
      ${pkgs.acl}/bin/setfacl -R -m g:${lib.escapeShellArg sharedAccessGroup}:rwX ${lib.escapeShellArg vars.sharedRoot}
    }

    ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

    members_json="$(
      for group_name in ${lib.escapeShellArgs memberGroups}; do
        group_members "$group_name"
      done | ${pkgs.coreutils}/bin/sort -u
    )"

    shared_members_json="$(
      group_members ${lib.escapeShellArg sharedAccessGroup} | ${pkgs.coreutils}/bin/sort -u
    )"

    sftp_members_json="$(
      group_members ${lib.escapeShellArg sftpAccessGroup} | ${pkgs.coreutils}/bin/sort -u
    )"

    declare -A shared_members=()
    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      shared_members["$username"]=1
    done <<<"$shared_members_json"

    declare -A sftp_members=()
    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      sftp_members["$username"]=1
    done <<<"$sftp_members_json"

    apply_shared_root_acl

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      ensure_posix_account "$username"
      wait_for_unix_user "$username"
      ${prepareUserRoot} "$username"

      if [[ -n "''${shared_members[$username]:-}" ]]; then
        install -d -m 0755 -o root -g root ${lib.escapeShellArg vars.usersRoot}/"$username"/${lib.escapeShellArg sharedMountName}
        ${pkgs.systemd}/bin/systemctl start "$(service_instance files-shared-bindfs@.service "$username")"
      fi

      if [[ -n "''${sftp_members[$username]:-}" ]]; then
        install -d -m 0755 -o root -g root ${lib.escapeShellArg sftpChrootBase}/"$username"
        ${pkgs.systemd}/bin/systemctl start "$(service_instance files-sftp-user-root@.service "$username")"
      fi
    done <<<"$members_json"

    while IFS= read -r -d "" shared_mount; do
      username="$(basename "$(dirname "$shared_mount")")"
      if [[ -z "''${shared_members[$username]:-}" ]]; then
        ${pkgs.systemd}/bin/systemctl stop --no-block "$(service_instance files-shared-bindfs@.service "$username")" || true
        if ! ${pkgs.util-linux}/bin/mountpoint -q "$shared_mount"; then
          rmdir --ignore-fail-on-non-empty "$shared_mount" || true
        fi
      fi
    done < <(${pkgs.findutils}/bin/find ${lib.escapeShellArg vars.usersRoot} -mindepth 2 -maxdepth 2 -type d -name ${lib.escapeShellArg sharedMountName} -print0)

    if [[ -d ${lib.escapeShellArg sftpChrootBase} ]]; then
      while IFS= read -r -d "" chroot_path; do
        username="$(basename "$chroot_path")"
        if [[ -z "''${sftp_members[$username]:-}" ]]; then
          ${pkgs.systemd}/bin/systemctl stop --no-block "$(service_instance files-sftp-user-root@.service "$username")" || true
        fi
      done < <(${pkgs.findutils}/bin/find ${lib.escapeShellArg sftpChrootBase} -mindepth 1 -maxdepth 1 -type d -print0)
    fi
  '';
in
{
  options.repo.storage.userRoots = {
    contentSubdirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = vars.userContentSubdirs or [ ];
      description = "Top-level content directories to create in each fileshare user root.";
    };

    bookSubdirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Book library subdirectories to create under each user's books directory.";
    };

    videoSubdirs = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Video library subdirectories to create under each user's videos directory.";
    };

    memberGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Kanidm groups whose members receive fileshare user roots.";
    };

    perUserDirectories = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          root = lib.mkOption { type = lib.types.str; };
          relativePath = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
          mode = lib.mkOption { type = lib.types.str; };
          user = lib.mkOption { type = lib.types.str; };
          group = lib.mkOption { type = lib.types.str; };
        };
      });
      default = [ ];
      description = "Additional per-user directories to create under configured per-user roots.";
    };

    rootTraverseGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Groups granted traverse-only access to each user root.";
    };

    rootWritableGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Groups granted writable access to each user root.";
    };

    recursiveWritableGrants = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          group = lib.mkOption { type = lib.types.str; };
          relativePaths = lib.mkOption { type = lib.types.listOf lib.types.str; };
        };
      });
      default = [ ];
      description = "Recursive writable ACL grants relative to each user root.";
    };

    recursiveReadonlyGrants = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          group = lib.mkOption { type = lib.types.str; };
          relativePaths = lib.mkOption { type = lib.types.listOf lib.types.str; };
        };
      });
      default = [ ];
      description = "Recursive read-only ACL grants relative to each user root.";
    };

    recursiveDirectoryNoAccessGrants = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          group = lib.mkOption { type = lib.types.str; };
          relativePaths = lib.mkOption { type = lib.types.listOf lib.types.str; };
        };
      });
      default = [ ];
      description = "Recursive directory no-access ACL grants relative to each user root.";
    };
  };

  config = {
    programs.fuse.userAllowOther = true;

    environment.systemPackages = [
      pkgs.bindfs
    ];

    systemd.tmpfiles.rules = [
      "d ${sftpChrootBase} 0755 root root -"
    ];

    systemd.services.fileshare-user-root-sync = {
      description = "Create per-user fileshare content and upload roots from Kanidm group membership";
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
      serviceConfig.Type = "oneshot";
      path = fileshareUserRootSyncPath;
      script = ''
        ${syncFileshareUserRoots}
      '';
    };

    systemd.services."files-shared-bindfs@" = {
      description = "Mount delete-protected shared files view for %i";
      unitConfig.ConditionPathIsDirectory = "${vars.usersRoot}/%i/${sharedMountName}";
      requires = [
        "data-pool-layout.service"
      ];
      after = [
        "data-pool-layout.service"
      ];
      serviceConfig = {
        Type = "simple";
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${vars.usersRoot}/%i/${sharedMountName}";
        ExecStart = "${pkgs.bindfs}/bin/bindfs -f -o allow_other --delete-deny ${vars.sharedRoot} ${vars.usersRoot}/%i/${sharedMountName}";
        ExecStop = "-${pkgs.fuse3}/bin/fusermount3 -u ${vars.usersRoot}/%i/${sharedMountName}";
        Restart = "on-failure";
      };
    };

    systemd.services."files-sftp-user-root@" = {
      description = "Bind per-user files root into the SFTP chroot for %i";
      requires = [ "data-pool-layout.service" ];
      wants = [ "files-shared-bindfs@%i.service" ];
      after = [
        "data-pool-layout.service"
        "files-shared-bindfs@%i.service"
      ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStartPre = "${pkgs.coreutils}/bin/install -d -m 0755 -o root -g root ${sftpChrootBase}/%i";
        ExecStart = "${pkgs.util-linux}/bin/mount --rbind ${vars.usersRoot}/%i ${sftpChrootBase}/%i";
        ExecStop = "-${pkgs.util-linux}/bin/umount -l ${sftpChrootBase}/%i";
      };
    };
  };
}
