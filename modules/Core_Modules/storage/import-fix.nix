{ config, lib, pkgs, vars, ... }:

let
  zpoolBin = "${config.boot.zfs.package}/sbin/zpool";
  zfsBin = "${config.boot.zfs.package}/sbin/zfs";
  poolName = vars.zfsDataPool.name;
  poolImportArgs = "-d /dev/disk/by-id";
  storageValidation = import ../../../lib/storage-validation.nix { inherit lib; };
  expectedPoolGuidRaw = vars.zfsDataPool.expectedGuid or null;
  expectedPoolGuid =
    if builtins.isString expectedPoolGuidRaw && storageValidation.validZpoolGuid expectedPoolGuidRaw
    then expectedPoolGuidRaw
    else null;
  poolImportIdentifier = if expectedPoolGuid == null then poolName else expectedPoolGuid;
  poolIdentityVerifier = pkgs.writeShellScript "verify-zfs-pool-identity"
    (builtins.readFile ../../../scripts/helpers/verify-zfs-pool-identity.sh);
  poolIdentityVerifierArgs = lib.escapeShellArgs (
    [ "--pool" poolName ]
    ++ lib.optionals (expectedPoolGuid != null) [ "--expected-guid" expectedPoolGuid ]
    ++ lib.concatMap
      (diskId: [ "--expected-device" "/dev/disk/by-id/${diskId}" ])
      vars.zfsDataPoolDiskIds
  );
in
lib.mkIf vars.enableZfsDataPool {
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

    poolImported() {
      local pool="$1"
      ${zpoolBin} list "$pool" >/dev/null 2>/dev/null
    }

    poolImport() {
      # shellcheck disable=SC2086
      ${zpoolBin} import ${poolImportArgs} -N $ZFS_FORCE ${lib.escapeShellArg poolImportIdentifier}
    }

    if ! poolImported "${poolName}"; then
      echo -n "importing ZFS pool \"${poolName}\"..."
      for _ in $(seq 1 60); do
        poolImport && break
        sleep 1
      done
      poolImported "${poolName}" || poolImport
    fi

    if poolImported "${poolName}"; then
      ZFS_POOL_IDENTITY_ZPOOL_BIN=${lib.escapeShellArg zpoolBin} \
        ZFS_POOL_IDENTITY_AWK_BIN=${lib.escapeShellArg "${pkgs.gawk}/bin/awk"} \
        ZFS_POOL_IDENTITY_LSBLK_BIN=${lib.escapeShellArg "${pkgs.util-linux}/bin/lsblk"} \
        ${poolIdentityVerifier} ${poolIdentityVerifierArgs}

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
