{ config, lib, ... }:

{
  config = lib.mkIf config.repo.qbittorrent.enable {
    repo.backups.appStateEntries = [
      {
        app = "qbittorrent";
        component = "app";
        stateRoot = config.repo.qbittorrent.paths.profileDir;
        payloadRoots = [ ];
        notes = "qBittorrent profile, categories, torrent metadata, and resume state. Download payloads are intentionally excluded.";
      }
    ];
  };
}
