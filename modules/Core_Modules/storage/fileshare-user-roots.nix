{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.storage.userRoots;
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  memberGroups = lib.unique cfg.memberGroups;
  userContentSubdirs = lib.escapeShellArgs vars.userContentSubdirs;
  userBooksSubdirs = lib.escapeShellArgs vars.userBooksSubdirs;
  userVideoSubdirs = lib.escapeShellArgs vars.userVideoSubdirs;
  userBookWritablePaths = lib.concatMapStringsSep " \\\n      " (name: ''"$root/books/${name}"'') vars.userBooksSubdirs;
  fileshareUserRootSyncPath = with pkgs; [
    acl
    coreutils
    findutils
    jq
    kanidm_1_9
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

    install -d -m 2750 -g users "$root"
    chown root:users "$root"
    chmod 2750 "$root"
    for name in ${userContentSubdirs}; do
      [[ "$name" == "emails" ]] && continue
      install -d -m 2770 -g users "$root/$name"
      chown root:users "$root/$name"
      chmod 2770 "$root/$name"
    done
    for name in ${userVideoSubdirs}; do
      install -d -m 2770 -g users "$root/videos/$name"
      chown root:users "$root/videos/$name"
      chmod 2770 "$root/videos/$name"
    done
    for name in ${userBooksSubdirs}; do
      install -d -m 2770 -g users "$root/books/$name"
      chown root:users "$root/books/$name"
      chmod 2770 "$root/books/$name"
      install -d -m 2770 -g users "$root/books/$name/_Anon"
      chown root:users "$root/books/$name/_Anon"
      chmod 2770 "$root/books/$name/_Anon"
    done

    ${perUserDirectoryScript}

    root_acl_args=(
      -m u::rwx
      -m g::r-x
      -m o::---
      -m m::rwx
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

    apply_owner_group_writable_acl() {
      apply_recursive_acl "g::rwX" "d:g::rwx" "$@"
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

    apply_owner_group_writable_acl \
      "$root/uploads" \
      "$root/files" \
      "$root/documents" \
      "$root/photos" \
      "$root/audiobooks" \
      "$root/videos" \
      "$root/books" \
      ${userBookWritablePaths}

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

    members_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

      for group_name in ${lib.escapeShellArgs memberGroups}; do
        if group_json="$(
          ${pkgs.kanidm_1_9}/bin/kanidm group get \
            "$group_name" \
            -H ${kanidmCliUrl} \
            -D idm_admin \
            -o json
        )"; then
          printf '%s\n' "$group_json" | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]'
        fi
      done | ${pkgs.coreutils}/bin/sort -u
    )"

    while IFS= read -r username; do
      [[ -n "$username" ]] || continue
      ${prepareUserRoot} "$username"
    done <<<"$members_json"
  '';
in
{
  options.repo.storage.userRoots = {
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
  };
}
