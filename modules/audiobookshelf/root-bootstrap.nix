{ config, pkgs, vars, ... }:

let
  audiobookshelfPort = 13378;
  dataDir = "/var/lib/audiobookshelf";
  managedDir = "${dataDir}/.nixos-managed";
in
{
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
    path = with pkgs; [
      curl
      jq
    ];
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
          "http://127.0.0.1:${toString audiobookshelfPort}/status")"; then
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
        "http://127.0.0.1:${toString audiobookshelfPort}/init"

      status_json="$(${pkgs.curl}/bin/curl --silent --show-error --fail \
        "http://127.0.0.1:${toString audiobookshelfPort}/status")"

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
}
