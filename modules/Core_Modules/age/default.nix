{ config, lib, vars, ... }:

let
  repoRoot = ../../..;
  secretFile = name: repoRoot + "/secrets/${name}.age";
  moduleEnabled = name: config.nixhomeserver.modules.${name} or false;
  megaEnabled = (vars.rcloneMega or { }).enable or false;
  kiwixEnabled = moduleEnabled "kiwix" && config.repo.kiwix.enable;
  mailArchiveEnabled =
    moduleEnabled "mail-archive-ui"
    && config.services.mail-archive-ui.enable;
  prowlarrEnabled = moduleEnabled "prowlarr" && config.repo.prowlarr.enable;
  qbittorrentEnabled = moduleEnabled "qbittorrent" && config.repo.qbittorrent.enable;
  radarrEnabled = moduleEnabled "radarr" && config.repo.radarr.enable;
  seerrEnabled = moduleEnabled "seerr" && config.repo.seerr.enable;
  sonarrEnabled = moduleEnabled "sonarr" && config.repo.sonarr.enable;
  groundwaterEnabled =
    moduleEnabled "groundwater-logger"
    && config.repo.groundwaterLogger.enable;
in
{
  imports = [
    ./bootstrap.nix
  ];

  # Read directly from persistent storage so first activation does not depend on
  # the impermanence bind mount for /etc/agenix already being active.
  age.identityPaths = [ "/persist/etc/agenix/age.key" ];

  age.secrets = {
    netbirdSetupKey = {
      file = secretFile "netbirdSetupKey";
      owner = "netbird-main";
      group = "netbird-main";
      mode = "0400";
    };
    cfHomeCreds = { file = secretFile "cfHomeCreds"; owner = "cloudflared"; group = "cloudflared"; mode = "0400"; };
    cfAPIToken = { file = secretFile "cfAPIToken"; owner = "caddy"; group = "caddy"; mode = "0400"; };
    kanidmAdminPass = { file = secretFile "kanidmAdminPass"; owner = "kanidm"; mode = "0400"; };
    kanidmSysAdminPass = { file = secretFile "kanidmSysAdminPass"; owner = "kanidm"; mode = "0400"; };
    oauth2ProxyClientSecret = { file = secretFile "oauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    oauth2ProxyCookieSecret = { file = secretFile "oauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    monitorOauth2ProxyClientSecret = { file = secretFile "monitorOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    monitorOauth2ProxyCookieSecret = { file = secretFile "monitorOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    beszelHubEnv = { file = secretFile "beszelHubEnv"; owner = "root"; mode = "0400"; };
    kopiaServerPassword = { file = secretFile "kopiaServerPassword"; owner = "root"; mode = "0400"; };
    kopiaOauth2ProxyClientSecret = { file = secretFile "kopiaOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    kopiaOauth2ProxyCookieSecret = { file = secretFile "kopiaOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    serverBootstrapSudoPassword = { file = secretFile "serverBootstrapSudoPassword"; owner = "root"; mode = "0400"; };
  }
  // lib.optionalAttrs megaEnabled {
    rcloneMegaPassword = { file = secretFile "rcloneMegaPassword"; owner = "root"; mode = "0400"; };
  }
  // lib.optionalAttrs (moduleEnabled "immich") {
    immichClientSecret = { file = secretFile "immichClientSecret"; owner = "kanidm"; group = "immich"; mode = "0440"; };
  }
  // lib.optionalAttrs (moduleEnabled "paperless") {
    paperlessClientSecret = { file = secretFile "paperlessClientSecret"; owner = "kanidm"; group = "paperless"; mode = "0440"; };
  }
  // lib.optionalAttrs (moduleEnabled "audiobookshelf") {
    absClientSecret = { file = secretFile "absClientSecret"; owner = "kanidm"; group = "audiobookshelf"; mode = "0440"; };
    absBootstrapPass = { file = secretFile "absBootstrapPass"; owner = "root"; mode = "0400"; };
  }
  // lib.optionalAttrs (moduleEnabled "kavita") {
    kavitaClientSecret = { file = secretFile "kavitaClientSecret"; owner = "kanidm"; group = "kavita"; mode = "0440"; };
    kavitaTokenKey = { file = secretFile "kavitaTokenKey"; owner = "kavita"; mode = "0400"; };
  }
  // lib.optionalAttrs mailArchiveEnabled {
    mailArchiveOauth2ProxyClientSecret = { file = secretFile "mailArchiveOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    mailArchiveOauth2ProxyCookieSecret = { file = secretFile "mailArchiveOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs kiwixEnabled {
    kiwixOauth2ProxyClientSecret = { file = secretFile "kiwixOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    kiwixOauth2ProxyCookieSecret = { file = secretFile "kiwixOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs (moduleEnabled "youtube-downloader") {
    youtubeDownloaderOauth2ProxyClientSecret = { file = secretFile "youtubeDownloaderOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    youtubeDownloaderOauth2ProxyCookieSecret = { file = secretFile "youtubeDownloaderOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs (moduleEnabled "homepage") {
    homepageOauth2ProxyClientSecret = { file = secretFile "homepageOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    homepageOauth2ProxyCookieSecret = { file = secretFile "homepageOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    canaryUserPassword = { file = secretFile "canaryUserPassword"; owner = "homepage-canary"; group = "homepage-canary"; mode = "0400"; };
  }
  // lib.optionalAttrs seerrEnabled {
    seerrOauth2ProxyClientSecret = { file = secretFile "seerrOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    seerrOauth2ProxyCookieSecret = { file = secretFile "seerrOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs sonarrEnabled {
    sonarrOauth2ProxyClientSecret = { file = secretFile "sonarrOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    sonarrOauth2ProxyCookieSecret = { file = secretFile "sonarrOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs radarrEnabled {
    radarrOauth2ProxyClientSecret = { file = secretFile "radarrOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    radarrOauth2ProxyCookieSecret = { file = secretFile "radarrOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs prowlarrEnabled {
    prowlarrOauth2ProxyClientSecret = { file = secretFile "prowlarrOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    prowlarrOauth2ProxyCookieSecret = { file = secretFile "prowlarrOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs qbittorrentEnabled {
    qbittorrentOauth2ProxyClientSecret = { file = secretFile "qbittorrentOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    qbittorrentOauth2ProxyCookieSecret = { file = secretFile "qbittorrentOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
  }
  // lib.optionalAttrs (moduleEnabled "vaultwarden") {
    vaultwardenAdminToken = { file = secretFile "vaultwardenAdminToken"; owner = "vaultwarden"; mode = "0400"; };
  }
  // lib.optionalAttrs groundwaterEnabled {
    groundwaterAppMqttPassword = { file = secretFile "groundwaterAppMqttPassword"; owner = "groundwater-logger"; group = "groundwater-logger"; mode = "0400"; };
    groundwaterLoggerMqttPassword = { file = secretFile "groundwaterLoggerMqttPassword"; owner = "root"; mode = "0400"; };
  };

  systemd.tmpfiles.rules = [
    "d /run/secrets 0750 root root -"
  ];
}
