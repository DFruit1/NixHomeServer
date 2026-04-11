{ vars, ... }:

{
  imports = [ ./jellyseerr.nix ];

  services.jellyfin = {
    enable = true;
    dataDir = "${vars.dataRoot}/jellyfin";
    cacheDir = "/var/cache/jellyfin";
    logDir = "${vars.dataRoot}/jellyfin/log";
  };
}
