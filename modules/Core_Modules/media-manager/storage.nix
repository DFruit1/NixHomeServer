{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  sharedPaths = [
    "${vars.sharedRoot}/_Videos"
    "${vars.sharedRoot}/_Music"
    "${vars.sharedRoot}/_Audiobooks"
    "${vars.sharedRoot}/_Podcasts"
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
        relativePaths = [ "_Videos" "_Music" "_Audiobooks" "_Podcasts" "_Books" ];
      }
    ];
    recursiveWritableGrants = [
      {
        group = "media-manager-broker";
        relativePaths = [ "_Videos" "_Music" "_Audiobooks" "_Podcasts" "_Books" ];
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
      if [[ -d ${lib.escapeShellArg "${vars.sharedRoot}/_ISO"} ]]; then
        setfacl -m g:media-manager:r-x -m g:media-manager-broker:r-x ${lib.escapeShellArg "${vars.sharedRoot}/_ISO"}
      fi
      for path in ${pathArgs}; do
        [[ -d "$path" ]] || continue
        # Re-apply access ACLs on every activation: files moved in by other
        # applications (torrent clients, Syncthing, ...) do not inherit the
        # default ACL applied to freshly created entries, and a one-time
        # bootstrap misses them.
        setfacl -P -R \
          -m g:media-manager:r-X \
          -m g:media-manager-broker:rwX \
          "$path"
        find "$path" -type d -exec setfacl \
          -m d:g:media-manager:r-x \
          -m d:g:media-manager-broker:rwx \
          '{}' +
      done
    '';
  };

  systemd.tmpfiles.rules = [
    "d ${cfg.stateDir} 0770 media-manager media-manager -"
    "d ${cfg.stateDir}/refresh-requests 0750 media-manager media-manager -"
    "d ${cfg.stateDir}/refresh-results 0750 media-manager media-manager -"
    # SQLite WAL mode is three-file state. Repair legacy modes before either
    # writer starts: https://www.freedesktop.org/software/systemd/man/latest/tmpfiles.d.html#z
    "z ${cfg.stateDir}/control.sqlite3 0660 media-manager media-manager -"
    "z ${cfg.stateDir}/control.sqlite3-wal 0660 media-manager media-manager -"
    "z ${cfg.stateDir}/control.sqlite3-shm 0660 media-manager media-manager -"
  ];
}
