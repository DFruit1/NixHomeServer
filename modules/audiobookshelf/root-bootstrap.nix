{ config, lib, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  audiobookshelfPort = config.services.audiobookshelf.port;
  dataDir = "/var/lib/${config.services.audiobookshelf.dataDir}";
  managedDir = "${dataDir}/.nixos-managed";
  audiobookshelfRootBootstrapPath = with pkgs; [
    curl
    jq
  ];
in
{
  config = lib.mkIf config.nixhomeserver.apps.audiobookshelf.enable {
    systemd.services.audiobookshelf-root-bootstrap-v1 = {
      description = "Bootstrap Audiobookshelf root account for OIDC linking";
      wantedBy = [ "multi-user.target" ];
      after = [
        "audiobookshelf.service"
        "audiobookshelf-oidc-bootstrap-v1.service"
      ];
      wants = [
        "audiobookshelf.service"
        "audiobookshelf-oidc-bootstrap-v1.service"
      ];
      path = audiobookshelfRootBootstrapPath;
      script = ''
        set -euo pipefail

        managed_dir="${managedDir}"
        marker_file="$managed_dir/audiobookshelf-root-bootstrap-v1.done"
        status_json=""

        install -d -m 0755 "$managed_dir"

        if [[ -f "$marker_file" ]]; then
          echo "Audiobookshelf root bootstrap v1 already applied"
          exit 0
        fi

        for _ in $(seq 1 30); do
          if status_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
            "http://${loopback}:${toString audiobookshelfPort}/status")"; then
            break
          fi
          sleep 1
        done

        [[ -n "$status_json" ]] || {
          echo "Audiobookshelf status endpoint did not become ready" >&2
          exit 1
        }

        if printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -e '.isInit == true' >/dev/null; then
          echo "Audiobookshelf root bootstrap v1 already converged"
          touch "$marker_file"
          exit 0
        fi

        bootstrap_password="$(< ${config.age.secrets.absBootstrapPass.path})"

        ${pkgs.curl}/bin/curl \
          --silent \
          --show-error \
          --fail \
          -X POST \
          -H 'Content-Type: application/json' \
          --data "$(${pkgs.jq}/bin/jq -cn \
            --arg username '${vars.kanidmAdminUser}' \
            --arg password "$bootstrap_password" \
            '{ newRoot: { username: $username, password: $password } }')" \
          "http://${loopback}:${toString audiobookshelfPort}/init"

        status_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
          "http://${loopback}:${toString audiobookshelfPort}/status")"

        printf '%s' "$status_json" | ${pkgs.jq}/bin/jq -e '.isInit == true' >/dev/null || {
          echo "Audiobookshelf root bootstrap did not complete successfully" >&2
          exit 1
        }

        echo "Audiobookshelf root bootstrap v1 initialized the local root record"
        touch "$marker_file"
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
