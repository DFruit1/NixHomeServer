{ config, pkgs, vars, ... }:

{
  services.jellyseerr = {
    enable = true;
    port = vars.jellyseerrPort;
  };

  systemd.services.jellyseerr-bootstrap = {
    description = "Synchronize Jellyseerr first-run settings";
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
    path = with pkgs; [ jq ];
    script = ''
      set -euo pipefail

      settings_json="${config.services.jellyseerr.configDir}/settings.json"
      for _ in $(seq 1 30); do
        [[ -f "$settings_json" ]] && break
        sleep 1
      done
      [[ -f "$settings_json" ]] || {
        echo "Jellyseerr settings file not found at $settings_json" >&2
        exit 1
      }

      current="$(${pkgs.jq}/bin/jq -c . "$settings_json")"
      updated="$(printf '%s' "$current" | ${pkgs.jq}/bin/jq -c \
        --arg appUrl "https://${vars.jellyseerrDomain}" \
        --arg jellyfinHost "127.0.0.1" \
        --arg jellyfinExternalHost "${vars.jellyfinDomain}" \
        --arg forgotPasswordUrl "https://${vars.jellyfinDomain}/web/#/forgotpassword.html" \
        --argjson jellyfinPort ${toString vars.jellyfinPort} \
        '
          .main.applicationUrl = $appUrl
          | .main.applicationTitle = "Jellyseerr"
          | .main.mediaServerType = 4
          | .main.mediaServerLogin = true
          | .main.localLogin = true
          | .jellyfin.ip = $jellyfinHost
          | .jellyfin.port = $jellyfinPort
          | .jellyfin.useSsl = false
          | .jellyfin.urlBase = ""
          | .jellyfin.externalHostname = $jellyfinExternalHost
          | .jellyfin.jellyfinForgotPasswordUrl = $forgotPasswordUrl
        ')"

      if [[ "$current" == "$updated" ]]; then
        exit 0
      fi

      owner="$(stat -c '%u' "$settings_json")"
      group="$(stat -c '%g' "$settings_json")"
      mode="$(stat -c '%a' "$settings_json")"
      tmp="$(mktemp)"
      printf '%s\n' "$updated" | ${pkgs.jq}/bin/jq . > "$tmp"
      install -m "$mode" -o "$owner" -g "$group" "$tmp" "$settings_json"
      rm -f "$tmp"

      /run/current-system/sw/bin/systemctl restart jellyseerr.service
    '';
    serviceConfig = {
      Type = "oneshot";
    };
  };
}
