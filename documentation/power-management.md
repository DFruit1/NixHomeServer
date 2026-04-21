# Power Management

This guide covers the declarative nightly suspend policy and the low-risk power
defaults defined directly in `modules/power-management/default.nix`.

## Current policy

The active module currently manages:

- suspend-to-RAM every day at `23:30`
- RTC wake at `06:00`
- Wake-on-LAN on the primary wired interface
- CPU governor `powersave`
- `powertop --auto-tune`
- SATA/SCSI link policy `med_power_with_dipm`
- USB autosuspend by default
- `fstrim` on `Sun *-*-* 19:00:00`

The first pass intentionally does not manage:

- hibernate
- suspend-then-hibernate
- HDD spin-down policies
- generic PCI runtime power rules
- per-host audio, Bluetooth, Wi-Fi, or LED cleanup

## Module ownership

Power management is no longer configured through `vars.nix`.

If you want to change the default behavior, edit:

- `modules/power-management/default.nix`

That module currently owns:

- the nightly suspend timer
- RTC wake scheduling
- Wake-on-LAN policy
- CPU governor
- powertop and storage link tuning
- USB autosuspend defaults
- the weekly `fstrim` schedule

## Nightly availability model

When enabled, the host is intentionally unavailable during the nightly sleep
window. That includes:

- `https://id.<domain>`
- `https://files.<domain>`
- all private app endpoints
- SSH

The suspend job skips itself instead of forcing sleep when:

- a declared blocker unit is active
- an SSH session is active
- a non-root interactive session is active

Current blocker units:

- `zfs-scrub-data.service`

## Maintenance schedules vs sleep window

Current defaults place maintenance outside the suspend window:

- `fstrim`: `Sun *-*-* 19:00:00`
- ZFS scrub: managed by `services.zfs.autoScrub` for the `data` pool

If you change the sleep window, re-check these timers in:

- `modules/power-management/default.nix`
- `configuration.nix`

## Power audit workflow

Use the on-demand audit helper from repo root:

```bash
./scripts/power-audit.sh
```

This script is read-only. It reports:

- the configured CPU governor
- whether `powertop` and the SCSI link policy are enabled
- the nightly suspend timer
- the `fstrim` schedule
- `cpupower frequency-info`
- a one-shot `turbostat` sample when available
- power-related timers
- recent nightly suspend skip reasons
- current `networkctl`, `lsusb`, `lspci`, and `smartctl --scan` output

## Firmware / BIOS checklist

Keep this checklist generic across vendors:

- enable ACPI suspend support
- enable resume by RTC alarm
- enable wake by PCIe or onboard LAN
- disable ErP, EuP, or Deep S5 if it removes standby power needed for RTC or Wake-on-LAN
- leave PCIe ASPM at `Auto` or `Enabled`
- leave CPU C-states at `Auto` or `Enabled`
- set restore-after-power-loss intentionally for your environment
- disable fast boot if NIC wake or resume behavior is inconsistent
- update BIOS and NIC firmware before troubleshooting NixOS

## Validation after deploy

Run the normal repo validation first:

```bash
nix flake check --no-build
scripts/check-repo.sh
```

Then validate the power-management surface on the host:

```bash
systemctl list-timers power-management-nightly-suspend
systemctl status power-management-nightly-suspend.timer
systemctl status cpufreq
systemctl status fstrim.timer
systemctl cat power-management-nightly-suspend.service
networkctl status <netIface>
./scripts/power-audit.sh
```
