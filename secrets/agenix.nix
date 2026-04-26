{ ... }:
{
  # Manually copy the private key to this location, with 0400 permissions
  age.identityPaths = [ "/etc/agenix/age.key" ];

  age.secrets = {
    netbirdSetupKey = {
      file = ./netbirdSetupKey.age;
      owner = "netbird-main";
      group = "netbird-main";
      mode = "0400";
    };
    cfHomeCreds = { file = ./cfHomeCreds.age; owner = "cloudflared"; group = "cloudflared"; mode = "0400"; };
    cfAPIToken = { file = ./cfAPIToken.age; owner = "caddy"; group = "caddy"; mode = "0400"; };
    kanidmAdminPass = { file = ./kanidmAdminPass.age; owner = "kanidm"; mode = "0400"; };
    kanidmSysAdminPass = { file = ./kanidmSysAdminPass.age; owner = "kanidm"; mode = "0400"; };
    immichClientSecret = { file = ./immichClientSecret.age; owner = "kanidm"; group = "immich"; mode = "0440"; };
    paperlessClientSecret = { file = ./paperlessClientSecret.age; owner = "kanidm"; group = "paperless"; mode = "0440"; };
    absClientSecret = { file = ./absClientSecret.age; owner = "kanidm"; group = "audiobookshelf"; mode = "0440"; };
    absBootstrapPass = { file = ./absBootstrapPass.age; owner = "root"; mode = "0400"; };
    copypartyClientSecret = { file = ./copypartyClientSecret.age; owner = "copyparty"; mode = "0400"; };
    kavitaClientSecret = { file = ./kavitaClientSecret.age; owner = "kanidm"; group = "kavita"; mode = "0440"; };
    kavitaTokenKey = { file = ./kavitaTokenKey.age; owner = "kavita"; mode = "0400"; };
    oauth2ProxyClientSecret = { file = ./oauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    oauth2ProxyCookieSecret = { file = ./oauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    mailArchiveOauth2ProxyClientSecret = { file = ./mailArchiveOauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    mailArchiveOauth2ProxyCookieSecret = { file = ./mailArchiveOauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    kiwixOauth2ProxyClientSecret = { file = ./kiwixOauth2ProxyClientSecret.age; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    kiwixOauth2ProxyCookieSecret = { file = ./kiwixOauth2ProxyCookieSecret.age; owner = "oauth2-proxy"; mode = "0400"; };
    resticSystemStatePassword = { file = ./resticSystemStatePassword.age; owner = "root"; mode = "0400"; };
    serverBootstrapSudoPassword = { file = ./serverBootstrapSudoPassword.age; owner = "root"; mode = "0400"; };
    storageAlertWebhookUrl = { file = ./storageAlertWebhookUrl.age; owner = "root"; mode = "0400"; };
  };
}
