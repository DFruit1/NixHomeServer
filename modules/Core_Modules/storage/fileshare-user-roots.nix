{ config, lib, pkgs, vars, ... }:

let
  kanidmPort = 8443;
  kanidmCliUrl = "https://${vars.kanidmDomain}:${toString kanidmPort}";
  userFilesGroup = "user-files";
  userContentSubdirs = lib.escapeShellArgs vars.userContentSubdirs;
  userBooksSubdirs = lib.escapeShellArgs vars.userBooksSubdirs;
  kavitaWritablePaths = lib.concatMapStringsSep " \\\n      " (name: ''"$root/books/${name}"'') vars.userBooksSubdirs;

  prepareUserRoot = pkgs.writeShellScript "prepare-fileshare-user-root" ''
    set -euo pipefail

    username="$1"
    root="${vars.usersRoot}/$username"
    emails="$root/emails"

    install -d -m 2750 -g users "$root"
    chown root:users "$root"
    chmod 2750 "$root"
    for name in ${userContentSubdirs}; do
      [[ "$name" == "emails" ]] && continue
      install -d -m 2770 -g users "$root/$name"
      chown root:users "$root/$name"
      chmod 2770 "$root/$name"
    done
    for name in ${userBooksSubdirs}; do
      install -d -m 2770 -g users "$root/books/$name"
      chown root:users "$root/books/$name"
      chmod 2770 "$root/books/$name"
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
    apply_writable_acl mail-archive-ui "$root/files"
    apply_writable_acl kavita-media \
      "$root/books" \
      ${kavitaWritablePaths}

    apply_readonly_acl filebrowser-quantum "$root/emails"
    apply_readonly_acl immich "$root/photos"
    apply_readonly_acl paperless "$root/documents"
  '';

  syncFileshareUserRoots = pkgs.writeShellScript "sync-fileshare-user-roots" ''
    set -euo pipefail

    export HOME="$(mktemp -d)"
    trap 'rm -rf "$HOME"' EXIT
    export KANIDM_PASSWORD="$(< ${config.age.secrets.kanidmAdminPass.path})"

    members_json="$(
      ${pkgs.kanidm_1_9}/bin/kanidm login \
        -H ${kanidmCliUrl} \
        -D idm_admin >/dev/null

      ${pkgs.kanidm_1_9}/bin/kanidm group get \
        ${lib.escapeShellArg userFilesGroup} \
        -H ${kanidmCliUrl} \
        -D idm_admin \
        -o json \
        | ${pkgs.jq}/bin/jq -r '.attrs.member[]? | split("@")[0]' \
        | ${pkgs.coreutils}/bin/sort -u
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
      "local-fs.target"
    ];
    after = [
      "data-pool-layout.service"
      "kanidm.service"
      "local-fs.target"
    ];
    before = [
      "copyparty.service"
    ];
    serviceConfig.Type = "oneshot";
    path = [
      pkgs.acl
      pkgs.coreutils
      pkgs.findutils
      pkgs.jq
      pkgs.kanidm_1_9
      pkgs.rsync
    ];
    script = ''
      ${syncFileshareUserRoots}
    '';
  };
}
