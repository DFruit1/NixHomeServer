# Quickstart

Use this guide for the first install on new hardware, before the homepage,
SSO, or the "For Admins" page exists.

This is the bootstrap exception path:
- choose machine-specific settings in [`vars.nix`](../vars.nix)
- discover target disks and network interfaces
- create or install the agenix identity
- stage and encrypt required secrets
- provision blank disks
- install NixOS
- run the first guarded deploy

After the first guarded deploy succeeds, use [Operations](./operations.md) and
the homepage "For Admins" page for normal app configuration, user onboarding,
runtime checks, and rebuilds.

## Prerequisites

Prepare these before touching disks:

- Git access to this repo or your fork.
- A Nix-capable admin workstation or a NixOS installer shell with network.
- The SSH public key that should log in as `vars.identity.localAdminUser`.
- Static LAN settings for the target: hostname, interface, IP, prefix, and gateway.
- A domain and Cloudflare zone access for DNS-01 ACME and the Cloudflare Tunnel.
- A Cloudflare Tunnel credentials JSON for `cfHomeCreds`.
- A Cloudflare DNS API token for `cfAPIToken`.
- A NetBird setup key for `netbirdSetupKey`.
- A storage alert webhook URL for `storageAlertWebhookUrl`.
- A MEGA password for `rcloneMegaPassword`, because the current secret manifest expects it.
- Exact target disk IDs from `/dev/disk/by-id`, not kernel names such as `/dev/sda`.

## Prepare `vars.nix`

For a new one-host install, start from [`vars.example.nix`](../vars.example.nix):

```bash
cp vars.example.nix vars.nix
$EDITOR vars.nix
```

Set the operator-facing block first:

- `identity.adminUser`: the dedicated Kanidm operator account.
- `identity.localAdminUser`: the local Unix SSH/sudo account.
- `identity.sshPublicKey`: the public SSH key for root and the local admin.
- `network`: hostname, domain, LAN interface, LAN IP, prefix, gateway, and NetBird IP.
- `system.timeZone`.
- `system.hostId`: a stable 8-character lowercase hexadecimal value. It is
  required for `zfs-mirror`; `single-disk-ext4` may keep `00000000`, but setting
  a real value keeps later ZFS migration straightforward.
- `edge.cloudflareTunnelName`.
- `storage.systemDisk` and `storage.dataPool.mirrorPairs`.

Generate a host ID if you do not already have one:

```bash
head -c 4 /dev/urandom | od -An -tx1 | tr -d ' \n'
printf '\n'
```

Run the non-destructive readiness checks:

```bash
nix run .#validate-config-readiness
nix run .#show-config-summary
```

Disk and interface warnings are expected when you run these checks from a
workstation that is not the target server. Verify those values again from the
installer before destructive disk work.

## Discover Target Hardware

Boot a recent NixOS installer ISO, get network access, then clone the repo:

```bash
mkdir -p /mnt/src
git clone <your-fork-or-origin-url> /mnt/src
cd /mnt/src
```

Inspect disks and network interfaces from the installer:

```bash
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
ip link
```

Print the repo's read-only storage planning helper:

```bash
nix run .#bootstrap-storage-plan
```

Record:

- one system SSD for `storage.systemDisk`
- for `storage.profile = "zfs-mirror"`, pairs of data disks for `storage.dataPool.mirrorPairs`
- for `storage.profile = "single-disk-ext4"`, no separate data disks
- the real wired LAN interface for `network.lanInterface`

Stop here if any selected disk contains data you intend to keep.

## Create And Stage Agenix Identity

The deployed system decrypts agenix secrets with `/etc/agenix/age.key`.
Create or copy that private key before generating secrets.

For a new identity:

```bash
install -d -m 0700 /tmp/nixhomeserver-age
age-keygen -o /tmp/nixhomeserver-age/age.key
install -d -m 0755 secrets/pubkeys
age-keygen -y /tmp/nixhomeserver-age/age.key > secrets/pubkeys/age.pub
```

If you already have an age identity, derive the public recipient from that key:

```bash
install -d -m 0755 secrets/pubkeys
age-keygen -y /path/to/age.key > secrets/pubkeys/age.pub
```

Track `secrets/pubkeys/age.pub`. Do not commit the private `age.key`.

## Stage And Encrypt Secrets

Create the plaintext staging directory:

```bash
install -d -m 0700 secrets/unencrypted
```

Stage these files:

- `secrets/unencrypted/netbirdSetupKey`: plain NetBird setup key.
- `secrets/unencrypted/cfHomeCreds`: Cloudflare Tunnel credentials JSON with `AccountTag`, `TunnelID`, and `TunnelSecret`.
- `secrets/unencrypted/cfAPIToken`: plain Cloudflare API token. Legacy staging
  input containing `CLOUDFLARE_DNS_API_TOKEN=...` or
  `CLOUDFLARE_ZONE_API_TOKEN=...` is accepted and normalized to the raw token
  required by ACME's `CF_DNS_API_TOKEN_FILE` credential.
- `secrets/unencrypted/storageAlertWebhookUrl`: an `http://` or `https://` webhook URL.
- `secrets/unencrypted/rcloneMegaPassword`: plain MEGA password for the configured offsite copy target.

Generate repo-managed secrets and encrypt all staged external inputs:

```bash
./scripts/generate-all-secrets.sh
```

Expected result:

- encrypted `secrets/*.age` files exist
- `secrets/pubkeys/age.pub` matches the private key you will install on the target
- no error reports a missing staged input or invalid external secret format

Track intended `secrets/*.age` files and `secrets/pubkeys/age.pub`. Keep
`secrets/unencrypted/` and private age keys untracked.

## Provision Blank Disks

This section is destructive. Use it only for blank hardware or disks you are
intentionally wiping.

This repo does not maintain a destructive disk-wrapper helper. Treat
[`bootstrap/disko-system.nix`](../bootstrap/disko-system.nix) and
[`bootstrap/disko-data.nix`](../bootstrap/disko-data.nix) as blank-machine
bootstrap references, or provision the same layout with your own reviewed
process.

Expected layout for `storage.profile = "zfs-mirror"`:

- system disk partition 1: EFI filesystem mounted at `/boot`
- system disk partition 2: Btrfs with `/`, `/nix`, and `/persist` subvolumes
- data disks: GPT with ZFS partitions assigned to the configured mirrored pool
- data pool: `vars.zfsDataPool.name`, normally `data`
- data datasets: mounted under `vars.zfsDataPool.mountPoint`, normally `/mnt/data`

Expected layout for `storage.profile = "single-disk-ext4"`:

- system disk partition 1: EFI filesystem mounted at `/boot`
- system disk partition 2: ext4 mounted at `/`
- `/persist` and `/mnt/data`: regular directories on the root filesystem

Do not use `disko` for an already-installed server or an in-place storage
migration. Existing-server storage maintenance belongs in
[Restore And Recovery](./restore-and-recovery.md).

After provisioning, mount the target layout under `/mnt` and verify it:

For `storage.profile = "zfs-mirror"`:

```bash
findmnt /mnt
findmnt /mnt/boot
findmnt /mnt/nix
findmnt /mnt/persist
zpool status
```

For `storage.profile = "single-disk-ext4"`:

```bash
findmnt /mnt
findmnt /mnt/boot
df -hT /mnt
test -d /mnt/persist
test -d /mnt/nix
```

## Install NixOS

Copy the complete repo into the installed system. Use `cp -a /mnt/src/.` so
dotfiles are included:

```bash
mkdir -p /mnt/etc/nixos
cp -a /mnt/src/. /mnt/etc/nixos/
```

Generate and review target hardware config:

```bash
nixos-generate-config --root /mnt
$EDITOR /mnt/etc/nixos/hardware-configuration.nix
```

Install the private agenix identity:

```bash
install -d -m 0700 /mnt/etc/agenix
install -m 0400 /path/to/agenix.key /mnt/etc/agenix/age.key
```

Install the host. Replace `<vars.hostname>` with the configured hostname:

```bash
nixos-install --flake /mnt/etc/nixos#<vars.hostname>
reboot
```

## First Boot Verification

After reboot, SSH in as `vars.localAdminUser`:

```bash
ssh <local-admin-user>@<vars.hostname>
```

Check the target:

```bash
sudo systemctl --failed --no-pager
test -d /mnt/data
```

For the ZFS mirror profile, also run `zpool status`, `findmnt /persist`, and
`findmnt /mnt/data`.

For the single-disk ext4 profile, also run `df -hT /`, `test -d /persist`,
and `test -d /mnt/data`.

From the admin workstation repo, run the full first guarded test:

```bash
./scripts/deploy.sh --debug --action test
```

Only switch after the guarded test path passes:

```bash
./scripts/deploy.sh --action switch
```

At this point the host exists. Continue with [Operations](./operations.md), and
use the homepage "For Admins" page for app configuration, user onboarding, and
routine server management once homepage and SSO are reachable.
