{ ... }:

{
  age.identityPaths = [ "/etc/agenix/age.key" ];

  age.secrets = {
    netbirdSetupKey = {
      file = ../../../secrets/netbirdSetupKey.age;
      owner = "netbird-main";
      group = "netbird-main";
      mode = "0400";
    };
    cfHomeCreds = { file = ../../../secrets/cfHomeCreds.age; owner = "cloudflared"; group = "cloudflared"; mode = "0400"; };
    cfAPIToken = { file = ../../../secrets/cfAPIToken.age; owner = "caddy"; group = "caddy"; mode = "0400"; };
    kanidmAdminPass = { file = ../../../secrets/kanidmAdminPass.age; owner = "kanidm"; mode = "0400"; };
    kanidmSysAdminPass = { file = ../../../secrets/kanidmSysAdminPass.age; owner = "kanidm"; mode = "0400"; };
    immichClientSecret = { file = ../../../secrets/immichClientSecret.age; owner = "kanidm"; group = "immich"; mode = "0440"; };
    paperlessClientSecret = { file = ../../../secrets/paperlessClientSecret.age; owner = "kanidm"; group = "paperless"; mode = "0440"; };
    absClientSecret = { file = ../../../secrets/absClientSecret.age; owner = "kanidm"; group = "audiobookshelf"; mode = "0440"; };
    absBootstrapPass = { file = ../../../secrets/absBootstrapPass.age; owner = "root"; mode = "0400"; };
    copypartyClientSecret = { file = ../../../secrets/copypartyClientSecret.age; owner = "copyparty"; mode = "0400"; };
    kavitaClientSecret = { file = ../../../secrets/kavitaClientSecret.age; owner = "kanidm"; group = "kavita"; mode = "0440"; };
    kavitaTokenKey = { file = ../../../secrets/kavitaTokenKey.age; owner = "kavita"; mode = "0400"; };
    oauth2ProxyClientSecret = { file = ../../../secrets/oauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    oauth2ProxyCookieSecret = { file = ../../../secrets/oauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    mailArchiveOauth2ProxyClientSecret = { file = ../../../secrets/mailArchiveOauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    mailArchiveOauth2ProxyCookieSecret = { file = ../../../secrets/mailArchiveOauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    kiwixOauth2ProxyClientSecret = { file = ../../../secrets/kiwixOauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    kiwixOauth2ProxyCookieSecret = { file = ../../../secrets/kiwixOauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    youtubeDownloaderOauth2ProxyClientSecret = { file = ../../../secrets/youtubeDownloaderOauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    youtubeDownloaderOauth2ProxyCookieSecret = { file = ../../../secrets/youtubeDownloaderOauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    vaultwardenAdminToken = { file = ../../../secrets/vaultwardenAdminToken.age; owner = "vaultwarden"; mode = "0400"; };
    resticSystemStatePassword = { file = ../../../secrets/resticSystemStatePassword.age; owner = "root"; mode = "0400"; };
    serverBootstrapSudoPassword = { file = ../../../secrets/serverBootstrapSudoPassword.age; owner = "root"; mode = "0400"; };
    storageAlertWebhookUrl = { file = ../../../secrets/storageAlertWebhookUrl.age; owner = "root"; mode = "0400"; };
    virusTotalApiKey = { file = ../../../secrets/virusTotalApiKey.age; owner = "upload-processor"; group = "upload-processor"; mode = "0400"; };
  };

  systemd.tmpfiles.rules = [
    "d /run/secrets 0750 root root -"
  ];
}
