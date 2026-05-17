{ config, lib, pkgs, ... }:

let
  dataDir = "/var/lib/jellyfin";
  managedDir = "${dataDir}/.nixos-managed";
  jellyfinLibraryMonitorPath = with pkgs; [
    coreutils
    findutils
    perl
  ];
in
{
  config = lib.mkIf config.nixhomeserver.apps.jellyfin.enable {
    systemd.services.jellyfin-library-monitor-v1 = {
      description = "Tune Jellyfin's native realtime monitor for settled scans";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
      ];
      after = [
        "jellyfin.service"
        "jellyfin-library-bootstrap-v1.service"
      ];
      path = jellyfinLibraryMonitorPath;
      script = ''
        set -euo pipefail

        config_file="${dataDir}/config/system.xml"
        library_root="${dataDir}/root/default"
        managed_dir="${managedDir}"
        marker_file="$managed_dir/jellyfin-library-monitor-v1.done"
        changed=0

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
          :
        else
          owner="$(stat -c '%u' "$config_file")"
          group="$(stat -c '%g' "$config_file")"
          mode="$(stat -c '%a' "$config_file")"
          tmp="$(mktemp)"
          trap 'rm -f "$tmp"' EXIT
          printf '%s' "$updated" >"$tmp"
          install -m "$mode" -o "$owner" -g "$group" "$tmp" "$config_file"
          changed=1
        fi

        if [[ -d "$library_root" ]]; then
          while IFS= read -r -d "" options_file; do
            current="$(cat "$options_file")"
            updated="$(
              printf '%s' "$current" | ${pkgs.perl}/bin/perl -0pe '
                if (!s#<EnableRealtimeMonitor>.*?</EnableRealtimeMonitor>#<EnableRealtimeMonitor>true</EnableRealtimeMonitor>#s) {
                  s#(<Enabled>.*?</Enabled>)#$1\n  <EnableRealtimeMonitor>true</EnableRealtimeMonitor>#s;
                }
              '
            )"

            [[ "$current" != "$updated" ]] || continue

            owner="$(stat -c '%u' "$options_file")"
            group="$(stat -c '%g' "$options_file")"
            mode="$(stat -c '%a' "$options_file")"
            tmp="$(mktemp)"
            printf '%s' "$updated" >"$tmp"
            install -m "$mode" -o "$owner" -g "$group" "$tmp" "$options_file"
            rm -f "$tmp"
            changed=1
          done < <(find "$library_root" -mindepth 2 -maxdepth 2 -name options.xml -print0)
        fi

        touch "$marker_file"
        if (( changed == 1 )); then
          /run/current-system/sw/bin/systemctl restart jellyfin.service
        fi
      '';
      serviceConfig.Type = "oneshot";
    };
  };
}
