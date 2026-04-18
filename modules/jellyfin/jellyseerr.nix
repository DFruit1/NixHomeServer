{ config, pkgs, vars, lib, ... }:

let
  jellyfinPort = 8096;
  jellyseerrPort = 5055;
in
{
  users.groups.jellyseerr = { };
  users.users.jellyseerr = {
    isSystemUser = true;
    group = "jellyseerr";
    home = vars.jellyseerrConfigDir;
  };

  services.jellyseerr = {
    enable = true;
    port = jellyseerrPort;
    configDir = vars.jellyseerrConfigDir;
  };

  systemd.services.jellyseerr.serviceConfig = {
    DynamicUser = lib.mkForce false;
    User = "jellyseerr";
    Group = "jellyseerr";
    ReadWritePaths = [ vars.jellyseerrConfigDir ];
  };

  systemd.services.jellyseerr-bootstrap-v1 = {
    description = "Bootstrap Jellyseerr media-server and public settings";
    wantedBy = [ "multi-user.target" ];
    after = [
      "jellyseerr.service"
      "jellyfin.service"
      "caddy.service"
    ];
    wants = [
      "jellyseerr.service"
      "jellyfin.service"
      "caddy.service"
    ];
    path = with pkgs; [ curl jq coreutils ];
    script = ''
      set -euo pipefail

      settings_json="${config.services.jellyseerr.configDir}/settings.json"
      managed_dir="${config.services.jellyseerr.configDir}/.nixos-managed"
      marker_file="$managed_dir/jellyseerr-bootstrap-v1.done"
      public_url="http://127.0.0.1:${toString jellyseerrPort}/api/v1/settings/public"
      public_body="$(mktemp)"
      changed=0
      http_code=""
      trap 'rm -f "$public_body"' EXIT

      ${pkgs.coreutils}/bin/install -d -m 0755 "$managed_dir"

      if [[ -f "$marker_file" ]]; then
        echo "Jellyseerr bootstrap v1 already applied"
        exit 0
      fi

      for _ in $(seq 1 60); do
        http_code="$(${pkgs.curl}/bin/curl \
          --silent \
          --show-error \
          --output "$public_body" \
          --write-out '%{http_code}' \
          "$public_url" || true)"
        if [[ "$http_code" == "200" || "$http_code" == "401" ]]; then
          break
        fi
        sleep 1
      done
      if [[ "$http_code" != "200" && "$http_code" != "401" ]]; then
        echo "Jellyseerr public settings endpoint did not become ready (last status: $http_code)" >&2
        exit 1
      fi

      if [[ ! -f "$settings_json" ]]; then
        exit 0
      fi

      if [[ -f "$settings_json" ]]; then
        current="$(${pkgs.jq}/bin/jq -c . "$settings_json")"
        updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
          --arg appUrl "https://${vars.jellyseerrDomain}" \
          --arg jellyfinHost "127.0.0.1" \
          --arg jellyfinExternalHost "${vars.jellyfinDomain}" \
          --arg forgotPasswordUrl "https://${vars.jellyfinDomain}/web/#/forgotpassword.html" \
          --argjson jellyfinPort ${toString jellyfinPort} \
          '
            .main.applicationUrl = $appUrl
            | .main.applicationTitle = "Jellyseerr"
            | .main.mediaServerType = 2
            | .main.mediaServerLogin = true
            | .main.localLogin = true
            | .jellyfin.ip = $jellyfinHost
            | .jellyfin.port = $jellyfinPort
            | .jellyfin.useSsl = false
            | .jellyfin.urlBase = ""
            | .jellyfin.externalHostname = $jellyfinExternalHost
            | .jellyfin.jellyfinForgotPasswordUrl = $forgotPasswordUrl
          ')"

        if [[ "$current" != "$updated" ]]; then
          changed=1
          owner="$(stat -c '%u' "$settings_json")"
          group="$(stat -c '%g' "$settings_json")"
          mode="$(stat -c '%a' "$settings_json")"
          tmp="$(mktemp)"
          printf '%s\n' "$updated" | ${pkgs.jq}/bin/jq . > "$tmp"
          install -m "$mode" -o "$owner" -g "$group" "$tmp" "$settings_json"
          rm -f "$tmp"
        fi
      fi

      if [[ "$http_code" == "401" ]]; then
        if [[ "$changed" == "1" ]]; then
          echo "Jellyseerr bootstrap v1 updated managed settings"
          touch "$marker_file"
          /run/current-system/sw/bin/systemctl restart jellyseerr.service
        else
          echo "Jellyseerr bootstrap v1 already converged"
          touch "$marker_file"
        fi
        exit 0
      fi

      if [[ "$changed" == "1" ]]; then
        echo "Jellyseerr bootstrap v1 updated managed settings"
        touch "$marker_file"
        /run/current-system/sw/bin/systemctl restart jellyseerr.service
      else
        echo "Jellyseerr bootstrap v1 already converged"
        touch "$marker_file"
      fi
    '';
    serviceConfig = {
      Type = "oneshot";
    };
  };
}
