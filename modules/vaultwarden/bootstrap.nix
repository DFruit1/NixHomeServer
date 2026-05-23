{ config, lib, pkgs, ... }:

let
  runtimeDir = "/run/vaultwarden";
  environmentFile = "${runtimeDir}/vaultwarden.env";
  vaultwardenSecretMaterializePath = with pkgs; [
    coreutils
    gnugrep
    gnused
  ];
in
{
  config = lib.mkIf config.nixhomeserver.apps.vaultwarden.enable {
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
  };
}
