{ lib, pkgs, vars, ... }:

let
  sharedJellyfinDirs = map (library: "${vars.sharedVideosRoot}/${library.dir}") vars.sharedJellyfinLibraries;
in
{
  users.groups.jellyfin-media = { };

  systemd.services.jellyfin-storage-layout-v1 = {
    description = "Provision Jellyfin storage layout";
    wantedBy = [ "multi-user.target" ];
    wants = [ "data-pool-layout.service" "local-fs.target" ];
    after = [ "data-pool-layout.service" "local-fs.target" ];
    before = [ "jellyfin.service" ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = [
      pkgs.acl
      pkgs.coreutils
      pkgs.findutils
    ];
    script = ''
      set -euo pipefail

      install -d -m 2775 -o root -g users ${vars.sharedVideosRoot}
      for path in ${lib.escapeShellArgs sharedJellyfinDirs}; do
        install -d -m 2775 -o root -g users "$path"
      done

      apply_recursive_acl() {
        local access_spec="$1"
        local default_spec="$2"
        shift
        shift

        for path in "$@"; do
          [[ -d "$path" ]] || continue
          setfacl -R -m "$access_spec" "$path"
          find "$path" -type d -exec setfacl -m "$default_spec" '{}' +
        done
      }

      apply_recursive_acl "g:jellyfin-media:rwX" "d:g:jellyfin-media:rwx" ${lib.escapeShellArgs sharedJellyfinDirs}
    '';
  };

  systemd.services.jellyfin = {
    wants = [ "jellyfin-storage-layout-v1.service" ];
    after = [ "jellyfin-storage-layout-v1.service" ];
  };
}
