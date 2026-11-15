{ config, lib, vars, ... }:

let
  cfg = config.repo.mkvmaker;
in
{
  options.repo.mkvmaker.paths = {
    stateRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/mkvmaker";
      description = "Persistent mkvmaker queue, scan cache, manifests, and logs.";
    };

    sharedIsoRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_ISO";
      description = "Shared ISO storage root exposed to users through _Shared/_ISO.";
    };

    dvdInbox = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.paths.sharedIsoRoot}/_DVDs";
      description = "The only ISO directory watched for automatic DVD conversion.";
    };

    moviesOutput = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Videos/_Movies";
      description = "Shared Jellyfin movie library destination.";
    };

    showsOutput = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Videos/_Shows";
      description = "Shared Jellyfin TV library destination.";
    };

    heldOutput = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Videos/_Unidentified";
      description = ''
        Holding folder for TV episodes whose identity is not certain. It is
        browsable but outside the Jellyfin libraries, so guessed episode
        numbers never reach Jellyfin. It must share a filesystem with
        showsOutput so publishing is a rename.
      '';
    };

    needsIdentification = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.paths.dvdInbox}/_NeedsIdentification";
      description = ''
        ISOs whose episodes await a person. Renaming one to a Jellyfin TV name
        with an episode range publishes its held episodes without re-encoding.
      '';
    };

    stagingRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/.mkvmaker-staging";
      description = ''
        Hidden staging directory for partially written MKVs, kept outside the
        Jellyfin library so scanners never observe an incomplete file. It must
        stay on the same filesystem as moviesOutput/showsOutput for the final
        atomic rename.
      '';
    };
  };

  config = {
    # Every personal file root and the shared file root get an _ISO folder.
    # Only cfg.paths.dvdInbox under the shared root is watched.
    repo.storage.userRoots.contentSubdirs = [ "_ISO" ];
    repo.storage.sharedRoots.contentSubdirs = [ "_ISO" "_Videos" ".mkvmaker-staging" ];
    repo.storage.sharedRoots.videoSubdirs = [ "_Movies" "_Shows" "_Unidentified" ];

    systemd.tmpfiles.rules = [
      "d ${cfg.paths.stateRoot} 0750 mkvmaker mkvmaker -"
      "d ${cfg.paths.stateRoot}/config 0750 mkvmaker mkvmaker -"
      "d ${cfg.paths.stateRoot}/cache 0750 mkvmaker mkvmaker -"
      "d ${cfg.paths.stateRoot}/state 0750 mkvmaker mkvmaker -"
    ];
  };
}
