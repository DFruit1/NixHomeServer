#!/usr/bin/env bash
# setUpDualPartitionUSB.sh — create a small LUKS-encrypted ext4 partition
# and a large plaintext Btrfs partition on a removable drive.
# Designed for XFCE/Thunar with udisks(+udiskie) integration.
set -Eeuo pipefail
exec 3</dev/tty 4>/dev/tty

###############################################################################
# CONFIGURATION
###############################################################################
REAL_USER=${SUDO_USER:-$USER}
LABEL_LUKS="secureluks"
LABEL_DATA="usbdata"
LUKS_NAME="secure_usb" # mapper name when opened
# Small LUKS partition: 30 MiB (61440 × 512-byte sectors)
LUKS_SIZE_SECTORS=61440

###############################################################################
# DEPENDENCY CHECK
###############################################################################
need() { command -v "$1" >/dev/null || {
  echo "Missing dependency: $1"
  exit 1
}; }
for cmd in lsblk fzf sfdisk cryptsetup mkfs.ext4 mkfs.btrfs blkid \
  sudo mount umount udisksctl udiskie; do
  need "$cmd"
done

###############################################################################
# SELECT TARGET DEVICE
###############################################################################
DEV=$(lsblk -dno PATH,RM,SIZE | awk '$2==1{printf "%s (%s)\n",$1,$3}' |
  fzf --prompt='Select removable device: ' | awk '{print $1}')
[[ -n $DEV ]] || {
  echo "No device selected."
  exit 1
}

PART1="${DEV}1" # encrypted partition
PART2="${DEV}2" # plaintext partition

###############################################################################
# WARN ABOUT EXISTING DATA
###############################################################################
HAS_DATA=false
lsblk -n "$DEV" | tail -n +2 | grep -q . && HAS_DATA=true
mount | grep -q "$DEV" && HAS_DATA=true

if $HAS_DATA; then
  echo -e "\nWARNING: $DEV already contains partitions or mounted filesystems!" >&4
  read -rp "Erase EVERYTHING on this device? (y/N): " a
  [[ ${a,,} == y ]] || exit 1
  read -rp "Type ERASE to confirm: " b
  [[ $b == "ERASE" ]] || exit 1
fi

###############################################################################
# UNMOUNT ANY EXISTING MOUNTS
###############################################################################
while read -r mp; do
  [[ -n $mp ]] && sudo umount "$mp"
done < <(lsblk -pnlo MOUNTPOINT "$DEV" | grep -v '^$')

###############################################################################
# CREATE NEW PARTITION TABLE & PARTITIONS
###############################################################################
echo ">> Partitioning $DEV ..."
sudo sfdisk "$DEV" <<EOF
label: dos
device: $DEV
unit: sectors

${PART1} : start=2048, size=${LUKS_SIZE_SECTORS}, type=83
${PART2} : type=83
EOF

sudo partprobe "$DEV"
sleep 1 # give the kernel a moment to notice

###############################################################################
# SET UP LUKS (PARTITION 1)
###############################################################################
echo ">> Setting up LUKS on $PART1 ..."
read -rs -p "Enter passphrase for LUKS partition: " LUKS_PW
echo
read -rs -p "Confirm passphrase: " CONFIRM_PW
echo
[[ $LUKS_PW != "$CONFIRM_PW" ]] && {
  echo "Passphrases do not match."
  exit 1
}

printf '%s' "$LUKS_PW" | sudo cryptsetup luksFormat --type luks2 "$PART1" -
printf '%s' "$LUKS_PW" | sudo cryptsetup open "$PART1" "$LUKS_NAME" -

echo ">> Formatting encrypted ext4 filesystem ..."
sudo mkfs.ext4 -L "$LABEL_LUKS" "/dev/mapper/$LUKS_NAME"
sudo cryptsetup close "$LUKS_NAME"

###############################################################################
# FORMAT PLAINTEXT (PARTITION 2)
###############################################################################
echo ">> Formatting second partition as Btrfs ..."
sudo mkfs.btrfs -f -L "$LABEL_DATA" "$PART2"

###############################################################################
# DONE ─── Show usage instructions
###############################################################################
cat <<EOF

╭─────────────────────────── SUCCESS ───────────────────────────╮
│  • $PART1 → LUKS2-encrypted ext4 (label: $LABEL_LUKS)         │
│  • $PART2 → plaintext Btrfs      (label: $LABEL_DATA)         │
╰───────────────────────────────────────────────────────────────╯

🔐 **Unlock & mount the encrypted partition**
   sudo cryptsetup open "$PART1" "$LUKS_NAME"
   udisksctl mount -b /dev/mapper/$LUKS_NAME
   # Thunar will show it under /media/$REAL_USER/$LABEL_LUKS

🔒 **Lock the encrypted partition**
   udisksctl unmount -b /dev/mapper/$LUKS_NAME
   sudo cryptsetup close "$LUKS_NAME"

📂 **Mount / unmount the data partition (if not auto-mounted)**
   udisksctl mount   -b "$PART2"
   udisksctl unmount -b "$PART2"

💡 With **udiskie** running (e.g. started from your XFCE session),
   both partitions will appear in Thunar automatically; udiskie
   will prompt for the LUKS passphrase and handle mounting for you.
EOF
