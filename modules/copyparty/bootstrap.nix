{ config, lib, pkgs, vars, ... }:

let
  oauth2ProxyRuntimeDir = "/run/oauth2-proxy";
  oauth2ProxyKeyFilePath = "${oauth2ProxyRuntimeDir}/oauth2-proxy.env";
  oauth2ProxyClientSecretPath = "${oauth2ProxyRuntimeDir}/client-secret";
  oauth2ProxySecretMaterializePath = with pkgs; [
    coreutils
    gnugrep
    gnused
  ];
in
{
  config = {
    systemd.services.oauth2-proxy-secret-materialize = {
      description = "Materialize raw oauth2-proxy secrets";
      wantedBy = [ "multi-user.target" ];
      before = [ "oauth2-proxy.service" "kanidm.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
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

        install -d -m 0750 -o root -g root ${oauth2ProxyRuntimeDir}

        client_secret="$(read_secret_value ${config.age.secrets.oauth2ProxyClientSecret.path} OAUTH2_PROXY_CLIENT_SECRET)"
        cookie_secret="$(read_secret_value ${config.age.secrets.oauth2ProxyCookieSecret.path} OAUTH2_PROXY_COOKIE_SECRET)"

        printf '%s' "$client_secret" > ${oauth2ProxyClientSecretPath}
        printf 'OAUTH2_PROXY_CLIENT_SECRET=%s\nOAUTH2_PROXY_COOKIE_SECRET=%s\n' "$client_secret" "$cookie_secret" > ${oauth2ProxyKeyFilePath}

        chown root:kanidm ${oauth2ProxyClientSecretPath}
        chmod 0440 ${oauth2ProxyClientSecretPath}
        chown root:oauth2-proxy ${oauth2ProxyKeyFilePath}
        chmod 0440 ${oauth2ProxyKeyFilePath}
      '';
      path = oauth2ProxySecretMaterializePath;
    };
  };
}
