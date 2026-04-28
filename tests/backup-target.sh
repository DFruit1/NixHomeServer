#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib.sh"

cd "$TESTS_REPO_ROOT"

ensure_tools jq mktemp nix

echo "ℹ️ Checking backup-target helper behavior…"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mkdir -p \
  "$tmpdir/bin" \
  "$tmpdir/dev/disk/by-id" \
  "$tmpdir/state" \
  "$tmpdir/nix-cache" \
  "$tmpdir/mnt"

touch \
  "$tmpdir/dev/sdz1" \
  "$tmpdir/dev/sdy1" \
  "$tmpdir/dev/sdx1" \
  "$tmpdir/dev/sda2"

ln -s ../../sdz1 "$tmpdir/dev/disk/by-id/usb-Backup_A-0:0-part1"
ln -s ../../sdy1 "$tmpdir/dev/disk/by-id/usb-Backup_B-0:0-part1"
ln -s ../../sdx1 "$tmpdir/dev/disk/by-id/usb-Backup_C-0:0-part1"
ln -s ../../sda2 "$tmpdir/dev/disk/by-id/ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E-part2"

cat >"$tmpdir/lsblk.json" <<EOF
{
  "blockdevices": [
    {
      "path": "$tmpdir/dev/sdz",
      "type": "disk",
      "tran": "usb",
      "model": "Backup A",
      "serial": "A123",
      "children": [
        {
          "path": "$tmpdir/dev/sdz1",
          "type": "part",
          "fstype": "exfat",
          "label": "T7",
          "uuid": "UUID-EXFAT",
          "size": "931.5G",
          "mountpoints": []
        }
      ]
    },
    {
      "path": "$tmpdir/dev/sdy",
      "type": "disk",
      "tran": "usb",
      "model": "Backup B",
      "serial": "B234",
      "children": [
        {
          "path": "$tmpdir/dev/sdy1",
          "type": "part",
          "fstype": "ext4",
          "label": "DUPLICATE",
          "uuid": "UUID-EXT4",
          "size": "500G",
          "mountpoints": []
        }
      ]
    },
    {
      "path": "$tmpdir/dev/sdx",
      "type": "disk",
      "tran": "usb",
      "model": "Backup C",
      "serial": "C345",
      "children": [
        {
          "path": "$tmpdir/dev/sdx1",
          "type": "part",
          "fstype": "btrfs",
          "label": "DUPLICATE",
          "uuid": "UUID-BTRFS",
          "size": "250G",
          "mountpoints": []
        }
      ]
    },
    {
      "path": "$tmpdir/dev/sda",
      "type": "disk",
      "tran": "sata",
      "model": "System SSD",
      "serial": "SYS1",
      "children": [
        {
          "path": "$tmpdir/dev/sda2",
          "type": "part",
          "fstype": "btrfs",
          "label": "persist",
          "uuid": "UUID-INTERNAL",
          "size": "238G",
          "mountpoints": []
        }
      ]
    }
  ]
}
EOF

cat >"$tmpdir/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
cat "$BACKUP_TARGET_TEST_LSBLK_JSON"
EOF
chmod +x "$tmpdir/bin/lsblk"

cat >"$tmpdir/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="$BACKUP_TARGET_TEST_MOUNT_STATE"
if [[ ! -f "$state_file" ]]; then
  exit 1
fi

source "$state_file"

target=""
output=""
check_presence=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --target)
      target="$2"
      shift 2
      ;;
    -o|-nro|-rnro|-rn|-rno)
      if [[ "$1" == "-o" ]]; then
        output="$2"
        shift 2
      else
        shift
      fi
      ;;
    -nro)
      output="$2"
      target="$3"
      shift 3
      ;;
    *)
      if [[ -z "$target" && "$1" == /* ]]; then
        target="$1"
      fi
      shift
      ;;
  esac
done

if [[ "$target" != "$MOUNT_TARGET" ]]; then
  exit 1
fi

if [[ -z "$output" ]]; then
  printf '%s %s %s\n' "$MOUNT_TARGET" "$MOUNT_SOURCE" "$MOUNT_FSTYPE"
  exit 0
fi

case "$output" in
  SOURCE)
    printf '%s\n' "$MOUNT_SOURCE"
    ;;
  FSTYPE)
    printf '%s\n' "$MOUNT_FSTYPE"
    ;;
  TARGET,SOURCE,FSTYPE)
    printf '%s %s %s\n' "$MOUNT_TARGET" "$MOUNT_SOURCE" "$MOUNT_FSTYPE"
    ;;
  *)
    exit 1
    ;;
esac
EOF
chmod +x "$tmpdir/bin/findmnt"

cat >"$tmpdir/bin/mount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

state_file="$BACKUP_TARGET_TEST_MOUNT_STATE"
fstype=""
options=""
source_device=""
target=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    -t)
      fstype="$2"
      shift 2
      ;;
    -o)
      options="$2"
      shift 2
      ;;
    *)
      if [[ -z "$source_device" ]]; then
        source_device="$1"
      elif [[ -z "$target" ]]; then
        target="$1"
      fi
      shift
      ;;
  esac
done

cat >"$state_file" <<STATE
MOUNT_SOURCE=$source_device
MOUNT_TARGET=$target
MOUNT_FSTYPE=$fstype
MOUNT_OPTS=$options
STATE
EOF
chmod +x "$tmpdir/bin/mount"

cat >"$tmpdir/bin/umount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
rm -f "$BACKUP_TARGET_TEST_MOUNT_STATE"
EOF
chmod +x "$tmpdir/bin/umount"

cat >"$tmpdir/bin/sudo" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
"$@"
EOF
chmod +x "$tmpdir/bin/sudo"

run_backup_target() {
  PATH="$tmpdir/bin:$PATH" \
    BACKUP_TARGET_TEST_LSBLK_JSON="$tmpdir/lsblk.json" \
    BACKUP_TARGET_TEST_MOUNT_STATE="$tmpdir/mount.state" \
    BACKUP_TARGET_DEV_DISK_ROOT="$tmpdir/dev/disk" \
    BACKUP_TARGET_STATE_DIR="$tmpdir/state" \
    BACKUP_TARGET_MOUNT_POINT="$tmpdir/mnt" \
    REPO_NIX_EVAL_CACHE_DIR="$tmpdir/nix-cache" \
    scripts/backup-target.sh "$@"
}

list_output="$(run_backup_target list)"
require_match <(printf '%s\n' "$list_output") 'device=.*/usb-Backup_A-0:0-part1' \
  "The backup-target helper must list eligible exfat USB media."
require_match <(printf '%s\n' "$list_output") 'device=.*/usb-Backup_B-0:0-part1' \
  "The backup-target helper must list eligible ext4 USB media."
require_match <(printf '%s\n' "$list_output") 'device=.*/usb-Backup_C-0:0-part1' \
  "The backup-target helper must list eligible btrfs USB media."
forbid_match <(printf '%s\n' "$list_output") 'ata-SK_hynix_SC401_SATA_256GB_EI89QSTDS10309C9E' \
  "The backup-target helper must exclude the protected internal SSD from candidate output."

set +e
run_backup_target mount >/tmp/backup-target-mount.out 2>/tmp/backup-target-mount.err
mount_status=$?
set -e
require_json_equal "$mount_status" "1" \
  "The backup-target helper must fail when mount is requested without a selection."

run_backup_target select "$tmpdir/dev/disk/by-id/usb-Backup_A-0:0-part1" >/tmp/backup-target-select.out
require_fixed "$tmpdir/state/selected-device" "$tmpdir/dev/disk/by-id/usb-Backup_A-0:0-part1" \
  "Selecting an explicit by-id path must persist that exact path."

run_backup_target mount
require_fixed "$tmpdir/mount.state" "MOUNT_SOURCE=$tmpdir/dev/disk/by-id/usb-Backup_A-0:0-part1" \
  "Mounting a selected backup target must record a mount source."
require_fixed "$tmpdir/mount.state" 'MOUNT_FSTYPE=exfat' \
  "Mounting the exfat fixture must use the exfat filesystem type."
require_fixed "$tmpdir/mount.state" 'MOUNT_OPTS=uid=0,gid=0,fmask=0177,dmask=0077,nodev,nosuid,noexec,noatime' \
  "Mounting exfat media must apply the hardened removable-media mount options."

run_backup_target unmount
if [[ -f "$tmpdir/mount.state" ]]; then
  echo "❌ Unmounting the selected backup target must clear the mock mount state."
  exit 1
fi

run_backup_target select UUID=UUID-EXT4 >/tmp/backup-target-select-ext4.out
require_fixed "$tmpdir/state/selected-device" "$tmpdir/dev/disk/by-id/usb-Backup_B-0:0-part1" \
  "Selecting by UUID must canonicalize to the usb by-id partition path."
run_backup_target mount
require_fixed "$tmpdir/mount.state" 'MOUNT_FSTYPE=ext4' \
  "Mounting the ext4 fixture must use the ext4 filesystem type."
require_fixed "$tmpdir/mount.state" 'MOUNT_OPTS=nodev,nosuid,noexec,noatime' \
  "Mounting ext4 media must apply the hardened mount options."
run_backup_target unmount

run_backup_target select UUID=UUID-BTRFS >/tmp/backup-target-select-btrfs.out
require_fixed "$tmpdir/state/selected-device" "$tmpdir/dev/disk/by-id/usb-Backup_C-0:0-part1" \
  "Selecting the btrfs fixture by UUID must canonicalize to the usb by-id partition path."
run_backup_target mount
require_fixed "$tmpdir/mount.state" 'MOUNT_FSTYPE=btrfs' \
  "Mounting the btrfs fixture must use the btrfs filesystem type."
require_fixed "$tmpdir/mount.state" 'MOUNT_OPTS=nodev,nosuid,noexec,noatime' \
  "Mounting btrfs media must apply the hardened mount options."
run_backup_target unmount

set +e
run_backup_target select LABEL=DUPLICATE >/tmp/backup-target-select-dup.out 2>/tmp/backup-target-select-dup.err
duplicate_status=$?
set -e
require_json_equal "$duplicate_status" "1" \
  "Selecting by LABEL must fail when the label is ambiguous."

set +e
run_backup_target select UUID=UUID-INTERNAL >/tmp/backup-target-select-internal.out 2>/tmp/backup-target-select-internal.err
internal_status=$?
set -e
require_json_equal "$internal_status" "1" \
  "Selecting an internal protected disk must fail."

run_backup_target clear
if [[ -e "$tmpdir/state/selected-device" ]]; then
  echo "❌ Clearing the backup target must remove the persisted selection."
  exit 1
fi

echo "✅ Backup target helper tests passed."
