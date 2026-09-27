{ config, lib, options, vars, ... }:

let
  repoDir = "${config.repo.fdroid.paths.stateDir}/repo";
in
{
  config = lib.optionalAttrs
    (lib.hasAttrByPath [ "repo" "fdroid" ] options && lib.hasAttrByPath [ "repo" "ipfs" ] options)
    (lib.mkIf config.repo.ipfs.enable {
      repo.storage.dataPool.guardedServices = [ "fdroid-ipfs-publish" ];

      # fdroidserver appends /repo to each mirror base URL. The alias redirects
      # individual index and APK requests to the current immutable directory CID.
      repo.fdroid.mirrorUrls = [ "https://ipfs.${vars.domain}/fdroid" ];

      systemd.services.fdroid-reindex.unitConfig.OnSuccess = "fdroid-ipfs-publish.service";

      systemd.services.fdroid-ipfs-publish = {
        description = "Pin the signed F-Droid repository in IPFS";
        requires = [ "ipfs.service" ];
        after = [ "ipfs.service" "fdroid-reindex.service" ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = "${config.repo.ipfs.publisher} fdroid ${repoDir}";
          SupplementaryGroups = [ "ipfs" ];
          NoNewPrivileges = true;
          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = true;
          ReadWritePaths = [ config.repo.ipfs.paths.distributionDir "/run/lock" ];
          RestrictAddressFamilies = [ "AF_UNIX" ];
          CapabilityBoundingSet = "";
          AmbientCapabilities = "";
        };
      };
    });
}
