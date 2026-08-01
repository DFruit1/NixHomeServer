{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  sharedPaths = [
    "${vars.sharedRoot}/_Videos"
    "${vars.sharedRoot}/_Music"
    "${vars.sharedRoot}/_Audiobooks"
    "${vars.sharedRoot}/_Books"
    "${vars.sharedRoot}/_ISO/_DVDs"
  ];
  pathArgs = lib.escapeShellArgs sharedPaths;
in
{
  repo.storage.userRoots = {
    rootTraverseGroups = [ "media-manager" "media-manager-broker" ];
    recursiveReadonlyGrants = [
      {
        group = "media-manager";
        relativePaths = [ "_Videos" "_Music" "_Audiobooks" "_Books" ];
      }
    ];
    recursiveWritableGrants = [
      {
        group = "media-manager-broker";
        relativePaths = [ "_Videos" "_Music" "_Audiobooks" "_Books" ];
      }
    ];
  };

  repo.storage.dataPool.guardedServices = [
    "media-manager-storage-access"
    "media-manager"
  ];

  systemd.services.media-manager-storage-access = {
    description = "Grant Media Manager read-only ACLs to shared media roots";
    wantedBy = [ "multi-user.target" ];
    requires = [ "data-pool-layout.service" ];
    after = [ "data-pool-layout.service" ];
    before = [ "fileshare-user-root-sync.service" "media-manager.service" ];
    unitConfig = lib.mkIf vars.dataRootIsMountPoint {
      ConditionPathIsMountPoint = vars.dataRoot;
    };
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = with pkgs; [ acl coreutils findutils gnugrep ];
    script = ''
      set -euo pipefail

      for group in media-manager media-manager-broker; do
        if getfacl -cp ${lib.escapeShellArg vars.sharedRoot} \
          | grep -q "^default:group:$group:"; then
          setfacl -x "d:g:$group" ${lib.escapeShellArg vars.sharedRoot}
        fi
      done
      setfacl \
        -m g:media-manager:r-x \
        -m g:media-manager-broker:r-x \
        ${lib.escapeShellArg vars.sharedRoot}
      for path in ${pathArgs}; do
        [[ -d "$path" ]] || continue
        if ! getfacl -cp "$path" | grep -q '^group:media-manager-broker:rwx$'; then
          setfacl -P -R \
            -m g:media-manager:r-X \
            -m g:media-manager-broker:rwX \
            "$path"
        fi
        find "$path" -type d -exec setfacl \
          -m d:g:media-manager:r-x \
          -m d:g:media-manager-broker:rwx \
          '{}' +
      done
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${cfg.stateDir} 0750 media-manager media-manager -"
  ];
}
