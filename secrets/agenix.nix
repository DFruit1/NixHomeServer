{ ... }:
{
  # Manually copy the private key to this location, with 0400 permissions
  age.identityPaths = [ "/etc/agenix/age.key" ];

  age.secrets = {
    netbirdSetupKey = { file = ./netbirdSetupKey.age; owner = "netbird-main"; mode = "0400"; };
    cfHomeCreds = { file = ./cfHomeCreds.age; owner = "cloudflared"; group = "cloudflared"; mode = "0400"; };
    cfAPIToken = { file = ./cfAPIToken.age; owner = "caddy"; group = "caddy"; mode = "0400"; };
    kanidmAdminPass = { file = ./kanidmAdminPass.age; owner = "kanidm"; mode = "0400"; };
    kanidmSysAdminPass = { file = ./kanidmSysAdminPass.age; owner = "kanidm"; mode = "0400"; };
    immichClientSecret = { file = ./immichClientSecret.age; owner = "immich"; mode = "0400"; };
    paperlessClientSecret = { file = ./paperlessClientSecret.age; owner = "paperless"; group = "paperless"; mode = "0400"; };
    absClientSecret = { file = ./absClientSecret.age; owner = "audiobookshelf"; mode = "0400"; };
    copypartyClientSecret = { file = ./copypartyClientSecret.age; owner = "copyparty"; mode = "0400"; };
    vaultwardenClientSecret = { file = ./vaultwardenClientSecret.age; owner = "vaultwarden"; mode = "0400"; };
    vaultwardenAdminToken = { file = ./vaultwardenAdminToken.age; owner = "vaultwarden"; mode = "0400"; };
  };
}
