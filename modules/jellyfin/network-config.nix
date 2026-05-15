{ pkgs, vars, ... }:

let
  dataDir = "/var/lib/jellyfin";
  managedDir = "${dataDir}/.nixos-managed";
  knownProxiesXml = "<string>${vars.networking.loopbackProxyCidr}</string><string>${vars.networking.loopbackIPv6}/128</string>";
  jellyfinNetworkConfigPath = with pkgs; [
    coreutils
    perl
  ];
in
{
  systemd.services.jellyfin-network-config-v1 = {
    description = "Align Jellyfin reverse-proxy trust settings with local Caddy";
    wantedBy = [ "multi-user.target" ];
    wants = [ "jellyfin.service" ];
    after = [ "jellyfin.service" ];
    path = jellyfinNetworkConfigPath;
    script = ''
      set -euo pipefail

      config_file="${dataDir}/config/network.xml"
      managed_dir="${managedDir}"
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
          s#<KnownProxies(?:\s*/>|>.*?</KnownProxies>)#<KnownProxies>${knownProxiesXml}</KnownProxies>#s;
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
    serviceConfig.Type = "oneshot";
  };
}
