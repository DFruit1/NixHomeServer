{
  generatedSecrets = {
    kanidmAdminPass = {
      description = "Initial delegated Kanidm admin password.";
      bytes = 24;
    };
    kanidmSysAdminPass = {
      description = "Break-glass Kanidm system administrator password.";
      bytes = 24;
    };
    immichClientSecret = {
      description = "OIDC client secret for Immich.";
      bytes = 32;
    };
    paperlessClientSecret = {
      description = "OIDC client secret for Paperless.";
      bytes = 32;
    };
    absClientSecret = {
      description = "OIDC client secret for Audiobookshelf.";
      bytes = 32;
    };
    absBootstrapPass = {
      description = "Initial local Audiobookshelf bootstrap password.";
      bytes = 32;
    };
    oauth2ProxyClientSecret = {
      description = "OIDC client secret for the uploads OAuth2 Proxy.";
      bytes = 32;
    };
    oauth2ProxyCookieSecret = {
      description = "Cookie secret for the uploads OAuth2 Proxy.";
      bytes = 32;
    };
    mailArchiveOauth2ProxyClientSecret = {
      description = "OIDC client secret for the mail archive OAuth2 Proxy.";
      bytes = 32;
    };
    mailArchiveOauth2ProxyCookieSecret = {
      description = "Cookie secret for the mail archive OAuth2 Proxy.";
      bytes = 32;
    };
    kiwixOauth2ProxyClientSecret = {
      description = "OIDC client secret for the Kiwix OAuth2 Proxy.";
      bytes = 32;
    };
    kiwixOauth2ProxyCookieSecret = {
      description = "Cookie secret for the Kiwix OAuth2 Proxy.";
      bytes = 32;
    };
    youtubeDownloaderOauth2ProxyClientSecret = {
      description = "OIDC client secret for the YouTube downloader OAuth2 Proxy.";
      bytes = 32;
    };
    youtubeDownloaderOauth2ProxyCookieSecret = {
      description = "Cookie secret for the YouTube downloader OAuth2 Proxy.";
      bytes = 32;
    };
    homepageOauth2ProxyClientSecret = {
      description = "OIDC client secret for the home page OAuth2 Proxy.";
      bytes = 32;
    };
    homepageOauth2ProxyCookieSecret = {
      description = "Cookie secret for the home page OAuth2 Proxy.";
      bytes = 32;
    };
    monitorOauth2ProxyClientSecret = {
      description = "OIDC client secret for the monitor OAuth2 Proxy.";
      bytes = 32;
    };
    monitorOauth2ProxyCookieSecret = {
      description = "Cookie secret for the monitor OAuth2 Proxy.";
      bytes = 32;
    };
    beszelHubEnv = {
      description = "Systemd environment file for Beszel hub local admin bootstrap.";
      bytes = 32;
    };
    kopiaServerPassword = {
      description = "Generated native basic-auth password for the Kopia web UI.";
      bytes = 32;
    };
    kopiaPhonePassword = {
      description = "Generated repository password for the phone-scoped Kopia backup seed.";
      bytes = 32;
    };
    kopiaOauth2ProxyClientSecret = {
      description = "OIDC client secret for the Kopia OAuth2 Proxy.";
      bytes = 32;
    };
    kopiaOauth2ProxyCookieSecret = {
      description = "Cookie secret for the Kopia OAuth2 Proxy.";
      bytes = 32;
    };
    rcloneOauth2ProxyClientSecret = {
      description = "OIDC client secret for the Rclone OAuth2 Proxy.";
      bytes = 32;
    };
    rcloneOauth2ProxyCookieSecret = {
      description = "Cookie secret for the Rclone OAuth2 Proxy.";
      bytes = 32;
    };
    seerrOauth2ProxyClientSecret = {
      description = "OIDC client secret for the Seerr OAuth2 Proxy.";
      bytes = 32;
    };
    seerrOauth2ProxyCookieSecret = {
      description = "Cookie secret for the Seerr OAuth2 Proxy.";
      bytes = 32;
    };
    sonarrOauth2ProxyClientSecret = {
      description = "OIDC client secret for the Sonarr OAuth2 Proxy.";
      bytes = 32;
    };
    sonarrOauth2ProxyCookieSecret = {
      description = "Cookie secret for the Sonarr OAuth2 Proxy.";
      bytes = 32;
    };
    radarrOauth2ProxyClientSecret = {
      description = "OIDC client secret for the Radarr OAuth2 Proxy.";
      bytes = 32;
    };
    radarrOauth2ProxyCookieSecret = {
      description = "Cookie secret for the Radarr OAuth2 Proxy.";
      bytes = 32;
    };
    prowlarrOauth2ProxyClientSecret = {
      description = "OIDC client secret for the Prowlarr OAuth2 Proxy.";
      bytes = 32;
    };
    prowlarrOauth2ProxyCookieSecret = {
      description = "Cookie secret for the Prowlarr OAuth2 Proxy.";
      bytes = 32;
    };
    qbittorrentOauth2ProxyClientSecret = {
      description = "OIDC client secret for the qBittorrent OAuth2 Proxy.";
      bytes = 32;
    };
    qbittorrentOauth2ProxyCookieSecret = {
      description = "Cookie secret for the qBittorrent OAuth2 Proxy.";
      bytes = 32;
    };
    vaultwardenAdminToken = {
      description = "Vaultwarden admin token.";
      bytes = 32;
    };
    kavitaClientSecret = {
      description = "OIDC client secret for Kavita.";
      bytes = 32;
    };
    kavitaTokenKey = {
      description = "Token key for Kavita.";
      bytes = 64;
    };
  };

  externalSecrets = {
    netbirdSetupKey = {
      description = "NetBird setup key used to enroll the server.";
      format = "plain text setup key";
      settingPath = "secrets/unencrypted/netbirdSetupKey";
    };
    cfHomeCreds = {
      description = "Cloudflare Tunnel credentials JSON for the configured tunnel.";
      format = "cloudflared tunnel credentials JSON";
      settingPath = "secrets/unencrypted/cfHomeCreds";
    };
    cfAPIToken = {
      description = "Cloudflare API token used by ACME DNS-01 certificate issuance.";
      format = "plain token value";
      settingPath = "secrets/unencrypted/cfAPIToken";
    };
    storageAlertWebhookUrl = {
      description = "Webhook URL for storage health alerts.";
      format = "https URL";
      settingPath = "secrets/unencrypted/storageAlertWebhookUrl";
    };
    rcloneMegaPassword = {
      description = "MEGA account password used by declarative Rclone offsite Kopia sync.";
      format = "plain text MEGA password";
      settingPath = "secrets/unencrypted/rcloneMegaPassword";
    };
  };
}
