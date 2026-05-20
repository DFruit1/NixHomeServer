{ config, lib, pkgs, vars, ... }:

let
  kanidmPort = vars.networking.ports.kanidm;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  userRootGroups = [
    "user-files"
    "jellyfin-users"
  ];
  userContentSubdirs = lib.escapeShellArgs vars.userContentSubdirs;
  userBooksSubdirs = lib.escapeShellArgs vars.userBooksSubdirs;
  userVideoSubdirs = lib.escapeShellArgs vars.userVideoSubdirs;
  userBookWritablePaths = lib.concatMapStringsSep " \\\n      " (name: ''"$root/books/${name}"'') vars.userBooksSubdirs;
  userVideoWritablePaths = lib.concatMapStringsSep " \\\n      " (name: ''"$root/videos/${name}"'') vars.userVideoSubdirs;
  fileshareUserRootSyncPath = with pkgs; [
    acl
    coreutils
    findutils
    jq
    kanidm_1_9
  ];

  prepareUserRoot = pkgs.writeShellScript "prepare-fileshare-user-root" ''
    set -euo pipefail

    username="$1"
    root="${vars.usersRoot}/$username"
    emails="$root/emails"
    staging="${vars.uploadSecurity.stagingRoot}/$username"

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

    if [[ -e "$emails" ]]; then
      [[ -d "$emails" ]] || {
        echo "Refusing to replace existing non-directory path: $emails" >&2
        exit 1
      }
      install -d -m 0770 -o mail-archive-ui -g mail-archive-ui "$emails"
    else
      install -d -m 0770 -o mail-archive-ui -g mail-archive-ui "$emails"
    fi
    install -d -m 0770 -o mail-archive-ui -g mail-archive-ui "$emails/.internal-sync"
    install -d -m 0730 -o root -g upload-staging "$staging"

    ${pkgs.acl}/bin/setfacl \
      -m u::rwx \
      -m g::r-x \
      -m o::--- \
      -m m::rwx \
      -m d:u::rwx \
      -m d:g::r-x \
      -m d:o::--- \
      -m d:m::rwx \
      -m g:kavita-media:--x \
      -m g:mail-archive-ui:--x \
      -m g:immich:--x \
      -m g:paperless:--x \
      -m g:audiobookshelf-media:rwx \
      -m d:g:audiobookshelf-media:rwx \
      -m g:jellyfin-media:--x \
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

    apply_writable_acl audiobookshelf-media "$root/audiobooks"
    apply_writable_acl jellyfin-media "$root/videos"
    apply_writable_acl mail-archive-ui "$root/files"
    apply_writable_acl metube \
      "$root/audiobooks" \
      "$root/videos" \
      ${userVideoWritablePaths}
    apply_writable_acl filebrowser-quantum \
      "$root/files" \
      "$root/audiobooks" \
      "$root/videos" \
      "$root/books" \
      ${userVideoWritablePaths} \
      ${userBookWritablePaths}
    apply_writable_acl filestash \
      "$root/uploads" \
      "$root/files" \
      "$root/documents" \
      "$root/photos" \
      "$root/audiobooks" \
      "$root/videos" \
      "$root/books" \
      ${userVideoWritablePaths} \
      ${userBookWritablePaths}
    apply_writable_acl kavita-media \
      "$root/books" \
      ${userBookWritablePaths}

    # FileBrowser may browse and download only the visible hard-linked .eml
    # mirror. The hidden sync payload uses the same file inodes, so deny
    # traversal on hidden directories rather than clobbering file ACLs.
    apply_readonly_acl filebrowser-quantum "$root/emails"
    apply_directory_noaccess_acl filebrowser-quantum "$root/emails/.internal-sync"
    apply_readonly_acl immich "$root/photos"
    apply_readonly_acl paperless "$root/documents"
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

      for group_name in ${lib.escapeShellArgs userRootGroups}; do
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
    before = [
      "copyparty.service"
    ];
    serviceConfig.Type = "oneshot";
    path = fileshareUserRootSyncPath;
    script = ''
      ${syncFileshareUserRoots}
    '';
  };
}
