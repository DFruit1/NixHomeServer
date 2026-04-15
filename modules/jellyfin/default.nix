{ vars, ... }:

{
  imports = [ ./jellyseerr.nix ];

  services.jellyfin = {
    enable = true;
    dataDir = vars.jellyfinDataDir;
    cacheDir = "/var/cache/jellyfin";
    logDir = vars.jellyfinLogDir;
  };
}
