{ config, vars, ... }:

let
  host = "fdroid.${vars.domain}";
  stateDir = config.repo.fdroid.paths.stateDir;
in
{
  services.caddy.virtualHosts.${host} = {
    logFormat = null;
    useACMEHost = vars.domain;
    extraConfig = ''
      encode zstd gzip
      @repoRoot path /fdroid/repo
      redir @repoRoot /fdroid/repo/ 308

      handle_path /fdroid/repo/* {
        root * ${stateDir}/repo
        header Cache-Control "no-cache"
        file_server
      }

      handle {
        respond "F-Droid repository" 200
      }
    '';
  };

  services.unbound.privateHosts.${host} = {
    target = "private";
    publishOnLan = true;
    publishOnNetbird = true;
  };
}
