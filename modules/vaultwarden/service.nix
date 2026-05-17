{ config, pkgs, pkgsUnstable, vars, ... }:

let
  vaultwardenPort = vars.networking.ports.vaultwarden;
  runtimeDir = "/run/vaultwarden";
  environmentFile = "${runtimeDir}/vaultwarden.env";
  vaultwardenSecretMaterializePath = with pkgs; [
    coreutils
    gnugrep
    gnused
  ];
in
{
  assertions = [
    {
      assertion = config.age.secrets ? vaultwardenAdminToken;
      message = "Missing vaultwardenAdminToken secret; run scripts/generate-all-secrets.sh";
    }
  ];

  services.vaultwarden = {
    enable = true;
    package = pkgsUnstable.vaultwarden;
    webVaultPackage = pkgsUnstable.vaultwarden.webvault;
    dbBackend = "sqlite";
    environmentFile = [ environmentFile ];
    config = {
      DOMAIN = "https://${vars.vaultwardenDomain}";
      ROCKET_ADDRESS = vars.networking.loopbackIPv4;
      ROCKET_PORT = vaultwardenPort;
      ENABLE_WEBSOCKET = true;
      SIGNUPS_ALLOWED = false;
      SIGNUPS_VERIFY = false;
      INVITATIONS_ALLOWED = true;
      ORG_CREATION_USERS = "none";
      PASSWORD_HINTS_ALLOWED = false;
      SHOW_PASSWORD_HINT = false;
      INVITATION_ORG_NAME = "Passwords";
    };
  };

  systemd.services.vaultwarden-secret-materialize = {
    description = "Materialize Vaultwarden secret environment";
    wantedBy = [ "multi-user.target" ];
    before = [ "vaultwarden.service" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    path = vaultwardenSecretMaterializePath;
    script = ''
      set -euo pipefail

      read_secret_value() {
        local file="$1"
        local key="$2"
        if grep -q "^''${key}=" "$file"; then
          sed -n "s/^''${key}=//p" "$file" | head -n1 | tr -d '\r\n'
        else
          tr -d '\r\n' < "$file"
        fi
      }

      install -d -m 0750 -o root -g root ${runtimeDir}

      admin_token="$(read_secret_value ${config.age.secrets.vaultwardenAdminToken.path} ADMIN_TOKEN)"
      printf 'ADMIN_TOKEN=%s\n' \
        "$admin_token" \
        > ${environmentFile}

      chown root:vaultwarden ${environmentFile}
      chmod 0440 ${environmentFile}
    '';
  };

  systemd.services.vaultwarden = {
    wants = [
      "network-online.target"
      "unbound.service"
      "vaultwarden-secret-materialize.service"
    ];
    after = [
      "network-online.target"
      "unbound.service"
      "vaultwarden-secret-materialize.service"
    ];
  };
}
