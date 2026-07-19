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

For a first Jellyfin login, list the root-only one-time credentials created for
managed users, retrieve the intended account, and change its password after
sign-in:

```bash
sudo jellyfin-initial-credential
sudo jellyfin-initial-credential USERNAME
```

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
- A MEGA password for `rcloneMegaPassword` only if you choose to enable the
  optional `rcloneMega` offsite mirror.
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

Print the non-destructive evaluated summary:

```bash
nix run .#show-config-summary
```

The full readiness gate intentionally comes after secrets and real target disk
IDs are available. Verify those values again from the installer before
destructive disk work.

## Discover Target Hardware

Boot a recent NixOS installer ISO, get network access, and inspect disks and
network interfaces. These read-only commands do not need a repository clone:

```bash
lsblk -o NAME,PATH,TYPE,SIZE,MODEL,SERIAL,FSTYPE,MOUNTPOINTS
ls -l /dev/disk/by-id/
ip link
```

Record:

- one system SSD for `storage.systemDisk`
- for `storage.profile = "zfs-mirror"`, pairs of data disks for `storage.dataPool.mirrorPairs`
- for `storage.profile = "single-disk-ext4"`, no separate data disks
- the real wired LAN interface for `network.lanInterface`

Stop here if any selected disk contains data you intend to keep.
Record the values in the admin workstation's `vars.nix`. The installer receives
a fresh repository clone or secure copy only after the encrypted configuration
checkpoint below.

## Create And Stage Agenix Identity

The deployed system decrypts agenix secrets directly from
`/persist/etc/agenix/age.key`. `/etc/agenix` is an impermanence-backed view of
the same directory after boot.
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
- Optional: `secrets/unencrypted/rcloneMegaPassword`, only when enabling the
  configured MEGA offsite copy target.

Generate repo-managed secrets and encrypt all staged external inputs:

```bash
nix run .#generate-secrets -- \
  --fresh \
  --identity /tmp/nixhomeserver-age/age.key
rm -rf secrets/unencrypted
```

Expected result:

- encrypted `secrets/*.age` files exist
- `secrets/pubkeys/age.pub` matches the private key you will install on the target
- `serverBootstrapSudoPassword.age` is generated with the other managed secrets
- the plaintext staging directory has been removed before the repo is copied
- no error reports a missing staged input or invalid external secret format

Track intended `secrets/*.age` files and `secrets/pubkeys/age.pub`. Never copy or
install the repository while `secrets/unencrypted/` contains anything. Move any
plaintext values you need to retain into a password manager, then remove the
staging directory; merely leaving it ignored by Git does not protect a filesystem
copy.

`--fresh` is intentionally required when adopting a clone that already contains
ciphertext for somebody else's key. It replaces generated values and requires a
staged value for every external secret. For an existing installation, verify
without changing values using:

```bash
nix run .#generate-secrets -- --identity /path/to/current/age.key
```

To rotate one externally supplied value without changing generated application
credentials, stage only that file and name its manifest key explicitly:

```bash
nix run .#generate-secrets -- \
  --replace-external cfAPIToken \
  --identity /path/to/current/age.key
```

To change recipients while preserving every current value, keep both private
keys available for one operation:

```bash
nix run .#generate-secrets -- --rekey \
  --source-identity /path/to/old/age.key \
  --identity /path/to/new/age.key
```

All modes fail unless the new private identity matches `secrets/pubkeys/age.pub`
and can decrypt every resulting manifest secret.

`serverBootstrapSudoPassword.age` holds a generated recovery password for
`identity.localAdminUser`. If SSH-key access is unavailable, decrypt it on the
trusted admin workstation, keep the output off logs and chat, and use that
password at the server's physical or virtual console:

```bash
age --decrypt --identity /path/to/age.key \
  secrets/serverBootstrapSudoPassword.age
```

This password cannot be used over SSH. Both SSH password authentication and
keyboard-interactive authentication remain disabled. After boot, the same
secret materializes root-only at
`/run/agenix/serverBootstrapSudoPassword` for local recovery or an unavoidable
interactive sudo prompt.

## Checkpoint The Encrypted Configuration

Before making a fresh installer clone or copy, commit every intended encrypted
configuration file and record the exact revision. Add any other configuration
files you intentionally changed as well:

```bash
git add vars.nix secrets/pubkeys/age.pub secrets/*.age
git add -u -- secrets
git diff --cached --check
git status --short
git commit -m "Prepare encrypted server configuration"
git status --short
git rev-parse HEAD
```

The second `git status --short`, after the commit, must print nothing. If it
lists a file, either commit that intended configuration or remove it from the
installer workflow before continuing.

Push that revision to a private Git remote:

```bash
git push
```

If no suitable remote is available, put a committed bundle on trusted removable
media or transfer it through another secure channel:

```bash
git bundle create /path/to/secure-media/nixhomeserver.bundle HEAD
```

Keep the private age key separate, never copy `secrets/unencrypted/`, and record
the printed revision in either workflow.

## Bring The Encrypted Revision To The Installer

For a private remote, make the fresh clone and verify the recorded revision:

```bash
git clone <your-fork-or-origin-url> /tmp/nixhomeserver
cd /tmp/nixhomeserver
test "$(git rev-parse HEAD)" = "<recorded-encrypted-config-revision>"
nix run .#bootstrap-storage-plan
```

When using a bundle, substitute its local path for the clone URL. When using a
direct secure copy, place the committed repository at `/tmp/nixhomeserver`,
enter it, and run the same revision check and read-only storage plan. Stop if
the plan does not show the hardware IDs you just recorded.

## Provision Blank Disks

This section is destructive. Use it only for blank hardware or disks you are
intentionally wiping.

Before printing or applying a destructive plan, prove the complete config and
every manifest ciphertext. If the identity was created elsewhere, transfer it
to the installer through a secure channel or removable medium; never add it to
the repository.

```bash
nix run .#validate-config-readiness -- \
  --host <vars.hostname> \
  --require-local-hardware \
  --identity /path/to/age.key
```

The repository pins disko in `flake.lock` and exposes a guarded wrapper. First
print the exact destructive set from the target installer; this mode is
read-only:

```bash
nix run .#bootstrap-disks -- --host <vars.hostname>
```

The wrapper refuses placeholders, missing or mounted disks, partitions instead
of whole disks, duplicate IDs, and two by-id aliases resolving to one physical
disk. Review the model, size, existing signatures, and every ID in the output.
Then repeat the hostname and every listed disk exactly once:

```bash
sudo nix run .#bootstrap-disks -- \
  --host <vars.hostname> \
  --apply \
  --confirm-host <vars.hostname> \
  --confirm-disk <system-disk-by-id-basename> \
  --confirm-disk <first-data-disk-by-id-basename> \
  --confirm-disk <second-data-disk-by-id-basename>
```

For `single-disk-ext4`, provide only the system disk confirmation. The wrapper
also requires a UEFI-booted installer and builds the pinned disko plan before it
can erase anything.

After the guarded Disko command completes, enter a root login shell for every
remaining `/mnt` operation and for `nixos-install`. The NixOS installer normally
logs in as the unprivileged `nixos` user, so the following commands otherwise
fail with permission errors:

```bash
sudo -i
cd /tmp/nixhomeserver
```

Expected layout for `storage.profile = "zfs-mirror"`:

- system disk partition 1: EFI filesystem mounted at `/boot`
- system disk partition 2: Btrfs whose top level is mounted at `/` by default,
  with separate `/nix` and `/persist` subvolumes
- data disks: GPT with ZFS partitions assigned to the configured mirrored pool
- data pool: `vars.zfsDataPool.name`, normally `data`
- data datasets: mounted under `vars.zfsDataPool.mountPoint`, normally `/mnt/data`

Choose `storage.enableRootRollback` before running Disko; it changes this
on-disk layout and is only available with `zfs-mirror`. When enabled, Disko
creates a writable `root` subvolume mounted at `/` and a read-only `root-blank`
subvolume as its rollback source, alongside `/nix` and `/persist`.

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

Keep the source clone somewhere that is not hidden by `/mnt`, such as
`/tmp/nixhomeserver`; never place it under `/mnt` before provisioning. Use the
controlled seeding helper to create a new persisted checkout, then bind that
checkout at the conventional NixOS path. The helper refuses non-empty
`secrets/unencrypted` and legacy `SensitivePrivateSecrets` staging, refuses all
untracked non-ignored files, copies only current Git-tracked contents, and
preserves the checkout metadata for later commits and synchronization:

```bash
cd /tmp/nixhomeserver
install -d -m 0755 /mnt/persist/etc
scripts/admin/seed-install-repository.sh --target /mnt/persist/etc/nixos
install -d -m 0755 /mnt/etc/nixos
mount --bind /mnt/persist/etc/nixos /mnt/etc/nixos
```

Generate and review target hardware config:

```bash
nixos-generate-config --root /mnt --no-filesystems --show-hardware-config \
  > /mnt/etc/nixos/hardware-configuration.nix
$EDITOR /mnt/etc/nixos/hardware-configuration.nix
```

Keep `--no-filesystems`: this repository declares the system and data-pool
filesystems itself, and generated duplicate mounts can race those units.

Before expecting public routes to work, run `nix run .#show-config-summary` and
add every **Cloudflare Tunnel ingress** hostname as a Public Hostname in the
configured tunnel (or as a proxied CNAME to `<TunnelID>.cfargotunnel.com`).
Tunnel credentials and the ACME token do not create those DNS records.

Keep `system.hardwareProfile = "generated"`. Using `--show-hardware-config`
avoids overwriting this repository's `configuration.nix`.

Install the private agenix identity:

```bash
install -d -m 0700 /mnt/persist/etc/agenix
install -m 0400 /path/to/age.key /mnt/persist/etc/agenix/age.key
test "$(age-keygen -y /mnt/persist/etc/agenix/age.key)" = \
  "$(tr -d '\r\n' </mnt/etc/nixos/secrets/pubkeys/age.pub)"
```

Before installation, run the full readiness check against that identity:

```bash
cd /mnt/etc/nixos
nix run .#validate-config-readiness -- \
  --host <vars.hostname> \
  --require-local-hardware \
  --identity /mnt/persist/etc/agenix/age.key
```

Install the host. Replace `<vars.hostname>` with the configured hostname:

```bash
nixos-install --flake /mnt/etc/nixos#<vars.hostname>
reboot
```

## First Boot Verification

After reboot, SSH in as `vars.localAdminUser`:

```bash
ssh <local-admin-user>@<network.lanIp>
```

Use the LAN IP until client DNS is configured, then check the target:

```bash
sudo systemctl --failed --no-pager
test -d /mnt/data
```

For the ZFS mirror profile, also run `zpool status`, `findmnt /persist`, and
`findmnt /mnt/data`.

NetBird assigns the peer address during first enrollment. While still connected
over LAN, compare it with the configured value:

```bash
ip -4 -o address show dev nb0
systemctl status netbird-address-verify.service --no-pager
```

If the assigned address differs from `network.netbirdIp`, update `vars.nix` to
the actual peer address (and the NetBird dashboard assignment when available),
then run the guarded deploy over the LAN IP. Private DNS intentionally remains
failed closed until those values agree.

For the single-disk ext4 profile, also run `df -hT /`, `test -d /persist`,
and `test -d /mnt/data`.

From the admin workstation repo, run the full first guarded test:

```bash
./scripts/deploy.sh --debug --action test
```

Do not deploy from a second clone until its `git rev-parse HEAD` matches the
installed repo and `git status --short` shows no missing target-side hardware or
disk edits. Commit and push the target configuration, then pull that exact
revision on the workstation first.

Only switch after the guarded test path passes:

```bash
./scripts/deploy.sh --action switch
```

At this point the host exists. Continue with [Operations](./operations.md), and
use the homepage "For Admins" page for app configuration, user onboarding, and
routine server management once homepage and SSO are reachable.
