{ config, lib, pkgs, vars, ... }:

let
  zpoolBin = "${config.boot.zfs.package}/sbin/zpool";
  zfsBin = "${config.boot.zfs.package}/sbin/zfs";
  poolName = vars.zfsDataPool.name;
  poolDeviceArgs = lib.concatMapStringsSep " " (diskId: "-d /dev/disk/by-id/${diskId}-part1") vars.zfsDataPoolDiskIds;
in
{
  systemd.services.zfs-import-data.script = lib.mkForce ''
    set -e

    # shellcheck disable=SC2013
    for o in $(cat /proc/cmdline); do
      case "$o" in
        zfs_force|zfs_force=1|zfs_force=y)
          ZFS_FORCE="-f"
          ;;
      esac
    done

    poolReady() {
      local pool="$1"
      local state
      state="$(${zpoolBin} import ${poolDeviceArgs} 2>/dev/null \
        | ${pkgs.gawk}/bin/awk "/pool: $pool/ { found = 1 }; /state:/ { if (found == 1) { print \\$2; exit } }; END { if (found == 0) { print \"MISSING\" } }")"
      if [[ "$state" = "ONLINE" || "$state" = "DEGRADED" ]]; then
        return 0
      else
        echo "Pool $pool in state $state, waiting"
        return 1
      fi
    }

    poolImported() {
      local pool="$1"
      ${zpoolBin} list "$pool" >/dev/null 2>/dev/null
    }

    poolImport() {
      local pool="$1"
      # shellcheck disable=SC2086
      ${zpoolBin} import ${poolDeviceArgs} -N $ZFS_FORCE "$pool"
    }

    if ! poolImported "${poolName}"; then
      echo -n "importing ZFS pool \"${poolName}\"..."
      for _ in $(seq 1 60); do
        poolReady "${poolName}" && poolImport "${poolName}" && break
        sleep 1
      done
      poolImported "${poolName}" || poolImport "${poolName}"
    fi

    if poolImported "${poolName}"; then
      ${zfsBin} list -rHo name,keylocation,keystatus -t volume,filesystem ${poolName} | while IFS=$'\t' read -r ds kl ks; do
        {
          if [[ "$ks" != unavailable ]]; then
            continue
          fi
          case "$kl" in
            none)
              ;;
            prompt)
              tries=3
              success=false
              while [[ $success != true && $tries -gt 0 ]]; do
                ${pkgs.systemd}/bin/systemd-ask-password --timeout=0 "Enter key for $ds:" \
                  | ${zfsBin} load-key "$ds" \
                  && success=true \
                  || tries=$((tries - 1))
              done
              [[ $success = true ]]
              ;;
            *)
              ${zfsBin} load-key "$ds"
              ;;
          esac
        } < /dev/null
      done

      echo "Successfully imported ${poolName}"
    else
      exit 1
    fi
  '';
}
