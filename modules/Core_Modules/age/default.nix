{ ... }:

let
  repoRoot = ../../..;
  secretFile = name: repoRoot + "/secrets/${name}.age";
in
{
  imports = [
    ./bootstrap.nix
  ];

  age.identityPaths = [ "/etc/agenix/age.key" ];

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
    immichClientSecret = { file = secretFile "immichClientSecret"; owner = "kanidm"; group = "immich"; mode = "0440"; };
    paperlessClientSecret = { file = secretFile "paperlessClientSecret"; owner = "kanidm"; group = "paperless"; mode = "0440"; };
    absClientSecret = { file = secretFile "absClientSecret"; owner = "kanidm"; group = "audiobookshelf"; mode = "0440"; };
    absBootstrapPass = { file = secretFile "absBootstrapPass"; owner = "root"; mode = "0400"; };
    kavitaClientSecret = { file = secretFile "kavitaClientSecret"; owner = "kanidm"; group = "kavita"; mode = "0440"; };
    kavitaTokenKey = { file = secretFile "kavitaTokenKey"; owner = "kavita"; mode = "0400"; };
    oauth2ProxyClientSecret = { file = secretFile "oauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    oauth2ProxyCookieSecret = { file = secretFile "oauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    mailArchiveOauth2ProxyClientSecret = { file = secretFile "mailArchiveOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    mailArchiveOauth2ProxyCookieSecret = { file = secretFile "mailArchiveOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    kiwixOauth2ProxyClientSecret = { file = secretFile "kiwixOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    kiwixOauth2ProxyCookieSecret = { file = secretFile "kiwixOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    youtubeDownloaderOauth2ProxyClientSecret = { file = secretFile "youtubeDownloaderOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    youtubeDownloaderOauth2ProxyCookieSecret = { file = secretFile "youtubeDownloaderOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    homepageOauth2ProxyClientSecret = { file = secretFile "homepageOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    homepageOauth2ProxyCookieSecret = { file = secretFile "homepageOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    kopiaServerPassword = { file = secretFile "kopiaServerPassword"; owner = "root"; mode = "0400"; };
    kopiaPhonePassword = { file = secretFile "kopiaPhonePassword"; owner = "root"; mode = "0400"; };
    kopiaOauth2ProxyClientSecret = { file = secretFile "kopiaOauth2ProxyClientSecret"; owner = "kanidm"; group = "oauth2-proxy"; mode = "0440"; };
    kopiaOauth2ProxyCookieSecret = { file = secretFile "kopiaOauth2ProxyCookieSecret"; owner = "oauth2-proxy"; mode = "0400"; };
    vaultwardenAdminToken = { file = secretFile "vaultwardenAdminToken"; owner = "vaultwarden"; mode = "0400"; };
    serverBootstrapSudoPassword = { file = secretFile "serverBootstrapSudoPassword"; owner = "root"; mode = "0400"; };
    storageAlertWebhookUrl = { file = secretFile "storageAlertWebhookUrl"; owner = "root"; mode = "0400"; };
  };

  systemd.tmpfiles.rules = [
    "d /run/secrets 0750 root root -"
  ];
}
