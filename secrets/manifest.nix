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
    metubeOauth2ProxyClientSecret = {
      description = "OIDC client secret for the MeTube OAuth2 Proxy.";
      bytes = 32;
    };
    metubeOauth2ProxyCookieSecret = {
      description = "Cookie secret for the MeTube OAuth2 Proxy.";
      bytes = 32;
    };
    runtimeCanaryFilesPassword = {
      description = "Password for the synthetic runtime access canary.";
      bytes = 32;
    };
    vaultwardenAdminToken = {
      description = "Vaultwarden admin token.";
      bytes = 32;
    };
    copypartyClientSecret = {
      description = "OIDC client secret for Copyparty uploads.";
      bytes = 32;
    };
    filebrowserQuantumClientSecret = {
      description = "OIDC client secret for FileBrowser Quantum.";
      bytes = 32;
    };
    filebrowserQuantumAdminPassword = {
      description = "Local FileBrowser Quantum admin password.";
      bytes = 32;
    };
    filebrowserQuantumJwtSecret = {
      description = "JWT signing secret for FileBrowser Quantum.";
      bytes = 64;
    };
    kavitaClientSecret = {
      description = "OIDC client secret for Kavita.";
      bytes = 32;
    };
    kavitaTokenKey = {
      description = "Token key for Kavita.";
      bytes = 64;
    };
    resticSystemStatePassword = {
      description = "Restic repository password for SSD-backed system state.";
      bytes = 32;
    };
  };

  externalSecrets = {
    netbirdSetupKey = {
      description = "NetBird setup key used to enroll the server.";
      format = "plain text setup key";
      settingPath = "secrets/top/netbirdSetupKey";
    };
    cfHomeCreds = {
      description = "Cloudflare Tunnel credentials JSON for the configured tunnel.";
      format = "cloudflared tunnel credentials JSON";
      settingPath = "secrets/top/cfHomeCreds";
    };
    cfAPIToken = {
      description = "Cloudflare API token used by ACME DNS-01 certificate issuance.";
      format = "plain token value";
      settingPath = "secrets/top/cfAPIToken";
    };
    storageAlertWebhookUrl = {
      description = "Webhook URL for storage health alerts.";
      format = "https URL";
      settingPath = "secrets/top/storageAlertWebhookUrl";
    };
    virusTotalApiKey = {
      description = "VirusTotal API key used for hash-only upload scanning lookups.";
      format = "plain API key";
      settingPath = "secrets/top/virusTotalApiKey";
    };
  };
}
