{ pkgs, vars, ... }:

{
  imports = [ ./jellyseerr.nix ];

  services.jellyfin = {
    enable = true;
    dataDir = vars.jellyfinDataDir;
    cacheDir = "/var/cache/jellyfin";
    logDir = vars.jellyfinLogDir;
  };

  systemd.services.jellyfin-network-config-v1 = {
    description = "Align Jellyfin reverse-proxy trust settings with local Caddy";
    wantedBy = [ "multi-user.target" ];
    wants = [ "jellyfin.service" ];
    after = [ "jellyfin.service" ];
    path = [ pkgs.coreutils pkgs.perl ];
    script = ''
      set -euo pipefail

      config_file="${vars.jellyfinDataDir}/config/network.xml"
      managed_dir="${vars.jellyfinDataDir}/.nixos-managed"
      marker_file="$managed_dir/jellyfin-network-config-v1.done"

      ${pkgs.coreutils}/bin/install -d -m 0755 "$managed_dir"

      if [[ -f "$marker_file" ]]; then
        echo "Jellyfin network config v1 already applied"
        exit 0
      fi

      for _ in $(seq 1 30); do
        [[ -f "$config_file" ]] && break
        sleep 1
      done
      [[ -f "$config_file" ]] || exit 0

      current="$(cat "$config_file")"
      updated="$(
        printf '%s' "$current" | ${pkgs.perl}/bin/perl -0pe '
          s#<KnownProxies(?:\s*/>|>.*?</KnownProxies>)#<KnownProxies><string>127.0.0.1/32</string><string>::1/128</string></KnownProxies>#s;
        '
      )"

      if [[ "$current" == "$updated" ]]; then
        echo "Jellyfin network config v1 already converged"
        touch "$marker_file"
        exit 0
      fi

      owner="$(stat -c '%u' "$config_file")"
      group="$(stat -c '%g' "$config_file")"
      mode="$(stat -c '%a' "$config_file")"
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT
      printf '%s' "$updated" > "$tmp"
      install -m "$mode" -o "$owner" -g "$group" "$tmp" "$config_file"
      echo "Jellyfin network config v1 updated KnownProxies"
      touch "$marker_file"
      /run/current-system/sw/bin/systemctl restart jellyfin.service
    '';
    serviceConfig = {
      Type = "oneshot";
    };
  };
}
