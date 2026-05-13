{ pkgs, lib, ... }:

let
  dataDir = "/var/lib/jellyfin";
  managedDir = "${dataDir}/.nixos-managed";
  jellyfinLibraryMonitorPath = with pkgs; [
    coreutils
    perl
  ];
in
{
  systemd.services.jellyfin-library-monitor-v1 = {
    description = "Tune Jellyfin's native realtime monitor for settled scans";
    wantedBy = [ "multi-user.target" ];
    wants = [ "jellyfin.service" ];
    after = [ "jellyfin.service" ];
    path = jellyfinLibraryMonitorPath;
    script = ''
      set -euo pipefail

      config_file="${dataDir}/config/system.xml"
      managed_dir="${managedDir}"
      marker_file="$managed_dir/jellyfin-library-monitor-v1.done"

      ${pkgs.coreutils}/bin/install -d -m 0755 "$managed_dir"

      for _ in $(seq 1 30); do
        [[ -f "$config_file" ]] && break
        sleep 1
      done
      [[ -f "$config_file" ]] || exit 0

      current="$(cat "$config_file")"
      updated="$(
        printf '%s' "$current" | ${pkgs.perl}/bin/perl -0pe '
          s#<LibraryMonitorDelay>.*?</LibraryMonitorDelay>#<LibraryMonitorDelay>20</LibraryMonitorDelay>#s;
          s#<LibraryUpdateDuration>.*?</LibraryUpdateDuration>#<LibraryUpdateDuration>30</LibraryUpdateDuration>#s;
        '
      )"

      if [[ "$current" == "$updated" ]]; then
        touch "$marker_file"
        exit 0
      fi

      owner="$(stat -c '%u' "$config_file")"
      group="$(stat -c '%g' "$config_file")"
      mode="$(stat -c '%a' "$config_file")"
      tmp="$(mktemp)"
      trap 'rm -f "$tmp"' EXIT
      printf '%s' "$updated" >"$tmp"
      install -m "$mode" -o "$owner" -g "$group" "$tmp" "$config_file"
      touch "$marker_file"
      /run/current-system/sw/bin/systemctl restart jellyfin.service
    '';
    serviceConfig.Type = "oneshot";
  };
}
