#!/usr/bin/env bash
# Void desktop only: reduce GRUB's menu wait and install passive runit markers.
set -euo pipefail
export PATH=/usr/bin:/usr/sbin:/bin:/sbin
[[ $EUID -eq 0 ]] || { echo 'Run this script with sudo or pkexec.' >&2; exit 1; }
[[ -d /etc/runit/core-services ]] && grep -Eq '^ID="?void"?$' /etc/os-release || { echo 'Requires Void Linux with runit.' >&2; exit 1; }
for tool in grub-mkconfig grub-script-check; do command -v "$tool" >/dev/null; done

scratch=$(mktemp -d /tmp/desktop-boot-setup.XXXXXX)
backup=""
changed=false
complete=false
cleanup() {
    local status=$?
    if [[ $changed == true && $complete == false ]]; then
        cp -p "$backup/grub.defaults" /etc/default/grub
        cp -p "$backup/grub.cfg" /boot/grub/grub.cfg
        for name in 01-desktop-boot-timing.sh 96-desktop-boot-timing.sh; do
            if [[ -f "$backup/$name" ]]; then
                cp -p "$backup/$name" "/etc/runit/core-services/$name"
            else
                rm -f "/etc/runit/core-services/$name"
            fi
        done
        echo "Update failed; restored configuration from $backup" >&2
    fi
    if [[ $changed == true ]]; then rm -f /boot/grub/grub.cfg.desktop-boot-new; fi
    rm -rf -- "$scratch"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

[[ $(grep -c '^GRUB_TIMEOUT=' /etc/default/grub) == 1 ]] || { echo 'Expected one GRUB_TIMEOUT assignment.' >&2; exit 1; }
[[ ! -e /boot/grub/grub.cfg.desktop-boot-new ]] || { echo 'A staged GRUB menu already exists; inspect it first.' >&2; exit 1; }
sed 's/^GRUB_TIMEOUT=.*/GRUB_TIMEOUT=1/' /etc/default/grub > "$scratch/grub.defaults"
bash -n "$scratch/grub.defaults"
cat > "$scratch/01-desktop-boot-timing.sh" <<'EOF'
# desktop-boot-timing: passive timestamp after pseudo-filesystems are mounted.
if read -r desktop_boot_time _ < /proc/uptime; then
    {
        read -r desktop_boot_id < /proc/sys/kernel/random/boot_id
        printf 'boot_id %s\ncore-start %s\n' "$desktop_boot_id" "$desktop_boot_time"
    } > /run/desktop-boot-timing || :
fi
unset desktop_boot_time desktop_boot_id
EOF
cat > "$scratch/96-desktop-boot-timing.sh" <<'EOF'
# desktop-boot-timing: passive timestamp before boot-log capture and cleanup.
if read -r desktop_boot_time _ < /proc/uptime; then
    printf 'core-end %s\n' "$desktop_boot_time" >> /run/desktop-boot-timing || :
fi
unset desktop_boot_time
EOF
for name in 01-desktop-boot-timing.sh 96-desktop-boot-timing.sh; do
    sh -n "$scratch/$name"
    if [[ -e /etc/runit/core-services/$name ]]; then
        cmp -s "$scratch/$name" "/etc/runit/core-services/$name" || { echo "Refusing to overwrite a different $name" >&2; exit 1; }
    fi
done
install -d -m 0700 /var/backups/desktop-boot
backup=$(mktemp -d /var/backups/desktop-boot/change.XXXXXX)
cp -p /etc/default/grub "$backup/grub.defaults"
cp -p /boot/grub/grub.cfg "$backup/grub.cfg"
for name in 01-desktop-boot-timing.sh 96-desktop-boot-timing.sh; do
    [[ ! -e /etc/runit/core-services/$name ]] || cp -p "/etc/runit/core-services/$name" "$backup/$name"
done
changed=true
cat "$scratch/grub.defaults" > /etc/default/grub
# Generate away from the live menu; validate before replacing it.
grub-mkconfig -o "$scratch/grub.cfg"
grub-script-check "$scratch/grub.cfg"
grep -Eq '^[[:space:]]*set timeout=1$' "$scratch/grub.cfg"
grep -Eq '^[[:space:]]*menuentry ' "$scratch/grub.cfg"
install -m 0600 "$scratch/grub.cfg" /boot/grub/grub.cfg.desktop-boot-new
mv /boot/grub/grub.cfg.desktop-boot-new /boot/grub/grub.cfg
for name in 01-desktop-boot-timing.sh 96-desktop-boot-timing.sh; do
    install -m 0644 "$scratch/$name" "/etc/runit/core-services/$name"
done
complete=true
printf 'GRUB_TIMEOUT=1; generated menu passed grub-script-check.\nBackups: %s\nTiming hooks begin on the next boot. No reboot performed.\n' "$backup"
