#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp rg
bash_path="$(command -v bash)"

echo "ℹ️ Checking storage-device discovery and protection helpers…"
fixture_dir="$TESTS_REPO_ROOT/scripts/tests/fixtures/storage-health"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

bin_dir="${tmpdir}/bin"
device_root="${tmpdir}/devices"
dev_disk_root="${tmpdir}/dev-disk"
by_id_dir="${dev_disk_root}/by-id"
state_dir="${tmpdir}/backup-state"
config_file="${tmpdir}/storage-config.json"

system_disk_actual="${device_root}/system-disk"
system_part_actual="${device_root}/system-disk-part1"
data_a_actual="${device_root}/data-a"
data_a_part_actual="${device_root}/data-a-part1"
data_b_actual="${device_root}/data-b"
data_b_part_actual="${device_root}/data-b-part1"
retired_actual="${device_root}/retired-a"
usb_actual="${device_root}/usb-backup"
usb_part_actual="${device_root}/usb-backup-part1"

mkdir -p "$bin_dir" "$device_root" "$by_id_dir" "$state_dir"
touch \
  "$system_disk_actual" \
  "$system_part_actual" \
  "$data_a_actual" \
  "$data_a_part_actual" \
  "$data_b_actual" \
  "$data_b_part_actual" \
  "$retired_actual" \
  "$usb_actual" \
  "$usb_part_actual"

ln -s "$system_disk_actual" "$by_id_dir/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"
ln -s "$system_part_actual" "$by_id_dir/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E-part1"
ln -s "$data_a_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV3997N"
ln -s "$data_a_part_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV3997N-part1"
ln -s "$data_b_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV37712"
ln -s "$data_b_part_actual" "$by_id_dir/ata-ST8000VN002-2ZM188_WPV37712-part1"
ln -s "$retired_actual" "$by_id_dir/ata-HGST_HUS726T4TALA6L4_V1JAKPNH"
ln -s "$retired_actual" "$by_id_dir/wwn-retired-a"
ln -s "$usb_actual" "$by_id_dir/usb-Samsung_PSSD_T7_S7MLNS0Y711062N"
ln -s "$usb_part_actual" "$by_id_dir/usb-Samsung_PSSD_T7_S7MLNS0Y711062N-part1"

cat >"$config_file" <<EOF
{
  "systemDisk": {
    "diskId": "ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E",
    "device": "${by_id_dir}/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E"
  },
  "dataPool": {
    "name": "data",
    "mountPoint": "/mnt/data",
    "datasetMounts": ["/mnt/data/users", "/mnt/data/shared"]
  }
}
EOF

cat >"$bin_dir/smartctl" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\${1:-}" == "--scan-open" ]]; then
  cat <<'SCAN'
${system_disk_actual} -d sat # system disk
${data_a_actual} -d sat # data disk a
${data_b_actual} -d sat # data disk b
${retired_actual} -d sat # retired internal disk
${usb_actual} -d sntasmedia # usb backup disk
SCAN
  exit 0
fi

cat "${fixture_dir}/clean.smartctl"
EOF
chmod +x "$bin_dir/smartctl"

cat >"$bin_dir/zpool" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if [[ "\$1" == "status" && "\${2:-}" == "-P" ]]; then
  cat <<'STATUS'
  pool: data
 state: ONLINE
config:

        NAME                                                     STATE     READ WRITE CKSUM
        data                                                     ONLINE       0     0     0
          mirror-0                                               ONLINE       0     0     0
            ${by_id_dir}/ata-ST8000VN002-2ZM188_WPV3997N-part1   ONLINE       0     0     0
            ${by_id_dir}/ata-ST8000VN002-2ZM188_WPV37712-part1   ONLINE       0     0     0

errors: No known data errors
STATUS
  exit 0
fi

if [[ "\$1" == "list" ]]; then
  printf 'ONLINE\n'
  exit 0
fi

exit 1
EOF
chmod +x "$bin_dir/zpool"

cat >"$bin_dir/lsblk" <<EOF
#!/usr/bin/env bash
set -euo pipefail

if printf '%s\n' "\$*" | grep -q -- '--tree'; then
  cat <<'TREE'
{
  "blockdevices": [
    {
      "path": "${system_disk_actual}",
      "type": "disk",
      "tran": "usb",
      "model": "SK hynix SC401 SATA 256GB",
      "serial": "EI89QSTDS10309C9E",
      "children": [
        {
          "path": "${system_part_actual}",
          "type": "part",
          "fstype": "btrfs",
          "label": "",
          "uuid": "system-part",
          "size": "256G",
          "mountpoints": []
        }
      ]
    },
    {
      "path": "${data_a_actual}",
      "type": "disk",
      "tran": "usb",
      "model": "ST8000VN002-2ZM188",
      "serial": "WPV3997N",
      "children": [
        {
          "path": "${data_a_part_actual}",
          "type": "part",
          "fstype": "exfat",
          "label": "",
          "uuid": "data-a-part",
          "size": "8T",
          "mountpoints": []
        }
      ]
    },
    {
      "path": "${data_b_actual}",
      "type": "disk",
      "tran": "usb",
      "model": "ST8000VN002-2ZM188",
      "serial": "WPV37712",
      "children": [
        {
          "path": "${data_b_part_actual}",
          "type": "part",
          "fstype": "exfat",
          "label": "",
          "uuid": "data-b-part",
          "size": "8T",
          "mountpoints": []
        }
      ]
    },
    {
      "path": "${usb_actual}",
      "type": "disk",
      "tran": "usb",
      "model": "PSSD T7",
      "serial": "S7MLNS0Y711062N",
      "children": [
        {
          "path": "${usb_part_actual}",
          "type": "part",
          "fstype": "exfat",
          "label": "BACKUP",
          "uuid": "usb-backup-part",
          "size": "2T",
          "mountpoints": []
        }
      ]
    }
  ]
}
TREE
else
  cat <<'FLAT'
{
  "blockdevices": [
    { "path": "${system_disk_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "SK hynix SC401 SATA 256GB", "serial": "EI89QSTDS10309C9E", "fstype": null, "mountpoints": [] },
    { "path": "${system_part_actual}", "type": "part", "pkname": "${system_disk_actual}", "tran": null, "model": null, "serial": null, "fstype": "btrfs", "mountpoints": ["/"] },
    { "path": "${data_a_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "ST8000VN002-2ZM188", "serial": "WPV3997N", "fstype": null, "mountpoints": [] },
    { "path": "${data_a_part_actual}", "type": "part", "pkname": "${data_a_actual}", "tran": null, "model": null, "serial": null, "fstype": "zfs_member", "mountpoints": [] },
    { "path": "${data_b_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "ST8000VN002-2ZM188", "serial": "WPV37712", "fstype": null, "mountpoints": [] },
    { "path": "${data_b_part_actual}", "type": "part", "pkname": "${data_b_actual}", "tran": null, "model": null, "serial": null, "fstype": "zfs_member", "mountpoints": [] },
    { "path": "${retired_actual}", "type": "disk", "pkname": null, "tran": "sata", "model": "HGST HUS726T4TALA6L4", "serial": "V1JAKPNH", "fstype": null, "mountpoints": [] },
    { "path": "${usb_actual}", "type": "disk", "pkname": null, "tran": "usb", "model": "PSSD T7", "serial": "S7MLNS0Y711062N", "fstype": null, "mountpoints": [] },
    { "path": "${usb_part_actual}", "type": "part", "pkname": "${usb_actual}", "tran": null, "model": null, "serial": null, "fstype": "exfat", "mountpoints": [] }
  ]
}
FLAT
fi
EOF
chmod +x "$bin_dir/lsblk"

cat >"$bin_dir/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
chmod +x "$bin_dir/sudo"

find "$bin_dir" -maxdepth 1 -type f -perm -0100 \
  -exec sed -i "1s|.*|#!${bash_path}|" {} +

discovery_env=(
  "PATH=$bin_dir:$PATH"
  "STORAGE_DEVICE_DISCOVERY_REPO_ROOT=$TESTS_REPO_ROOT"
  "STORAGE_DEVICE_DISCOVERY_DEV_DISK_ROOT=$dev_disk_root"
  "STORAGE_DEVICE_DISCOVERY_CONFIG_JSON_FILE=$config_file"
)

discovery_json="$(
  env "${discovery_env[@]}" \
    bash scripts/discover-storage-devices.sh --format json
)"

require_json_equal "$(jq -r '.systemDisk.label' <<<"$discovery_json")" "system" \
  "discover-storage-devices.sh must emit a dedicated system-disk entry."
require_json_equal "$(jq -r '[.zfsDataDisks[] | .label] | join(",")' <<<"$discovery_json")" "data1,data2" \
  "discover-storage-devices.sh must enumerate live ZFS pool members separately."
require_json_equal "$(jq -r '.zfsDataDisks[0].smartDevice' <<<"$discovery_json")" "${by_id_dir}/ata-ST8000VN002-2ZM188_WPV3997N" \
  "discover-storage-devices.sh must normalize pool member partitions back to whole-disk by-id paths."
require_json_equal "$(jq -r --arg actual "${usb_actual}" '.otherDisks[] | select(.actualDevice == $actual) | .smartctlArgs | join(" ")' <<<"$discovery_json")" "-d sntasmedia" \
  "discover-storage-devices.sh must preserve device-specific SMART transport args."
require_json_equal "$(jq -r '[.allSmartDisks[] | .label] | join(",")' <<<"$discovery_json")" "system,data1,data2,other1,other2" \
  "discover-storage-devices.sh must combine system, pool, and other disks into one SMART inventory."

smartd_conf="$(
  env "${discovery_env[@]}" \
    SMARTD_CONFIG_REPO_ROOT="$TESTS_REPO_ROOT" \
    bash scripts/generate-smartd-config.sh
)"
require_match <(printf '%s\n' "$smartd_conf") '^DEFAULT -a$' \
  "generate-smartd-config.sh must emit a smartd DEFAULT stanza."
require_match <(printf '%s\n' "$smartd_conf") "${by_id_dir}/usb-Samsung_PSSD_T7_S7MLNS0Y711062N -d sntasmedia" \
  "generate-smartd-config.sh must include discovered transport args for USB disks."

list_output="$(
  env \
    "PATH=$bin_dir:$PATH" \
    "BACKUP_TARGET_REPO_ROOT=$TESTS_REPO_ROOT" \
    "BACKUP_TARGET_DEV_DISK_ROOT=$dev_disk_root" \
    "BACKUP_TARGET_STATE_DIR=$state_dir" \
    "STORAGE_DEVICE_DISCOVERY_CONFIG_JSON_FILE=$config_file" \
    bash scripts/manage-backup-target.sh list
)"
require_match <(printf '%s\n' "$list_output") 'usb-Samsung_PSSD_T7_S7MLNS0Y711062N-part1' \
  "manage-backup-target.sh list must retain the eligible USB backup disk."
forbid_match <(printf '%s\n' "$list_output") 'ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E-part1' \
  "manage-backup-target.sh list must exclude the protected system disk even if it otherwise looks selectable."
forbid_match <(printf '%s\n' "$list_output") 'ata-ST8000VN002-2ZM188_WPV3997N-part1' \
  "manage-backup-target.sh list must exclude live protected ZFS pool members."

set +e
protected_status="$(
  env \
    "PATH=$bin_dir:$PATH" \
    "BACKUP_TARGET_REPO_ROOT=$TESTS_REPO_ROOT" \
    "BACKUP_TARGET_DEV_DISK_ROOT=$dev_disk_root" \
    "BACKUP_TARGET_STATE_DIR=$state_dir" \
    "STORAGE_DEVICE_DISCOVERY_CONFIG_JSON_FILE=$config_file" \
    bash scripts/manage-backup-target.sh select "${by_id_dir}/ata-ST8000VN002-2ZM188_WPV3997N-part1" 2>&1
)"
protected_code=$?
set -e
require_json_equal "$protected_code" "1" \
  "manage-backup-target.sh must refuse selecting live pool devices."
require_match <(printf '%s\n' "$protected_status") 'Refusing to select a protected system or pool device' \
  "manage-backup-target.sh must surface the live protection guardrail."

env \
  "PATH=$bin_dir:$PATH" \
  "BACKUP_TARGET_REPO_ROOT=$TESTS_REPO_ROOT" \
  "BACKUP_TARGET_DEV_DISK_ROOT=$dev_disk_root" \
  "BACKUP_TARGET_STATE_DIR=$state_dir" \
  "STORAGE_DEVICE_DISCOVERY_CONFIG_JSON_FILE=$config_file" \
  bash scripts/manage-backup-target.sh select "${by_id_dir}/usb-Samsung_PSSD_T7_S7MLNS0Y711062N-part1" >/dev/null

require_json_equal "$(cat "$state_dir/selected-device")" "${by_id_dir}/usb-Samsung_PSSD_T7_S7MLNS0Y711062N-part1" \
  "manage-backup-target.sh must still allow selecting an eligible USB backup disk."

echo "✅ Storage-device discovery tests passed."
