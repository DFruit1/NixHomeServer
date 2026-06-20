{ config, lib, vars, ... }:

{
  options.repo.qbittorrent.paths = {
    profileDir = lib.mkOption {
      type = lib.types.path;
      default = "/var/lib/qBittorrent";
      description = "qBittorrent profile directory.";
    };

    downloadRoot = lib.mkOption {
      type = lib.types.str;
      default = "${vars.sharedRoot}/_Downloads/qbittorrent";
      description = "qBittorrent shared staging root.";
    };

    incompleteDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qbittorrent.paths.downloadRoot}/incomplete";
      description = "qBittorrent incomplete downloads directory.";
    };

    completeDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qbittorrent.paths.downloadRoot}/complete";
      description = "qBittorrent completed downloads directory.";
    };

    moviesDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qbittorrent.paths.completeDir}/movies";
      description = "Completed movie downloads category directory.";
    };

    tvDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.repo.qbittorrent.paths.completeDir}/tv";
      description = "Completed TV downloads category directory.";
    };
  };
}
