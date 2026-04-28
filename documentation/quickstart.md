# Quickstart

Use this guide for bootstrap only:
- workstation prerequisites
- machine-specific [`vars.nix`](../vars.nix) setup
- secrets staging
- the supported destructive disk wrappers
- the initial agenix key install on a target host
- blank-machine installation

Canonical validation, guarded deploys, runtime checks, and rollback live in [Operations](./operations.md).

## When To Use This Guide

Use Quickstart when any of these are true:
- the workstation still needs the required CLI tools
- the repo has not been tailored to the target hardware in [`vars.nix`](../vars.nix)
- the required secrets have not been staged and encrypted yet
- the target host does not yet have `/etc/agenix/age.key`
- the machine is blank and needs its first install

If the host already exists and you only need validation, deployment, or runtime troubleshooting, use [Operations](./operations.md) instead.

## Conventions

- Placeholders such as `<domain>`, `CURRENT_SERVER_IP`, `SERVER_USER`, and `/path/to/agenix.key` are examples. Replace them with the actual operator values before running commands.
- Group names such as `users`, `immich-users`, `paperless-users`, `fileshare_users`, and `*-admin` are literal names managed by this repo.
- Command blocks use the same context format:
  - Run from: where to execute the commands
  - Privileges: whether `sudo` is required
  - Environment: whether a plain shell or a specific `nix shell` is expected

## Workstation And External Prerequisites

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
git --version
ssh -V
nix --version
age --version
jq --version
rg --version
```

Required external setup before first deploy:
- Cloudflare zone for `<domain>`
- Cloudflare Tunnel for this host
- NetBird management account and reusable setup key
- Age keypair for agenix secrets

## Set Machine Values

Edit [`vars.nix`](../vars.nix) and confirm at minimum:
- `serverLanIP`
- `serverLanGateway`
- `netIface`
- `dnsMode`
- `lanDnsHosts`
- `kanidmAuthSessionExpirySeconds`
- `serverSSHPubKey`
- `mainDisk`
- `zfsDataPool`
- `coldStoragePools` if you have any manual cold-storage pools

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
ls -l /dev/disk/by-id/
```

Use `/dev/disk/by-id/*`, not transient `/dev/sdX` names.

## Media Categories

Steady-state storage model:
- `media/*` holds app-managed payload trees. In current steady state that means `media/documents` for Paperless and `media/photos` for Immich-managed photo payloads.
- `users/*` and `shared/*` hold the canonical user-facing content libraries.
- `kiwix` intentionally remains its own top-level content root at `/mnt/data/kiwix`.
- `media/audio`, `media/books`, and `media/video` are historical migration roots only and must not be treated as steady-state library locations.

Per-user book roots are created automatically under `/mnt/data/users/<user>/books/`.

Books categories:
- `ebooks`: general book files such as EPUB, MOBI, AZW, and standard PDFs
- `comics`: western comics and comic archive formats
- `manga`: manga and similar chapter or volume-oriented material
- `other`: book-like reading material that should still be exposed through Kavita, such as textbooks, papers, manuals, and reference PDFs

All Jellyfin-visible video content is shared-only under `/mnt/data/shared/videos/`.
There are no per-user Jellyfin video folders.
Upload shared video content through the files app or the admin-only SMB share into these categories:
- `movies`: standard movie collections
- `shows`: episodic TV or series content
- `home`: personal videos and recordings
- `music-videos`: music video collections using Jellyfin's dedicated Music Videos type
- `youtube`: downloaded YouTube-style videos exposed as Jellyfin `homevideos`, including MeTube downloads written directly into the shared library tree
- `other`: catch-all video material exposed as Jellyfin `homevideos`

Shared media roots:
- shared books: `ebooks`, `comics`, `manga`, `other`
- shared videos: `movies`, `shows`, `home`, `music-videos`, `youtube`, `other`
- shared audiobooks: `/mnt/data/shared/audiobooks`
- app-managed payloads: `/mnt/data/media/documents`, `/mnt/data/media/photos`

Private MeTube downloads are available at `https://ytdownload.<domain>` on LAN or over NetBird only.

Offsite NetBird DNS expectations:
- Private app hostnames resolve over NetBird only after a NetBird nameserver group is configured in the NetBird admin plane to send those match domains to `100.72.113.237:53`.
- Match only the private app hostnames. Keep `id.<domain>`, `files.<domain>`, and the zone apex on the normal public path.
- Linux peers need `systemd-resolved` for NetBird match-domain split DNS. macOS, Windows, iOS, and Android can use NetBird-managed DNS directly.

## Destructive Storage Command Matrix

| Command or workflow | What it destroys | What it must not touch | Verify first in [`vars.nix`](../vars.nix) | Preview or handoff |
| --- | --- | --- | --- | --- |
| `./scripts/format-system-disk.sh` | The entire system SSD referenced by `mainDisk`, including the EFI partition and Btrfs root layout. | Both disks in the active `data` mirror and every `coldStoragePools` disk. | `mainDisk`, `hostname`, and that `mainDisk` does not appear anywhere in `zfsDataPool.mirrorPairs` or `coldStoragePools`. | Always run `./scripts/format-system-disk.sh --print-only` first. |
| `./scripts/format-data-disks.sh` | Both members of the active `zfsDataPool` mirror, recreating the mirrored `data` pool from scratch. Existing pool contents on those disks are destroyed. | `mainDisk` and every `coldStoragePools` disk. | `zfsDataPool.name`, `zfsDataPool.mountPoint`, `zfsDataPool.mirrorPairs`, that `builtins.length zfsDataPool.mirrorPairs == 1`, and that none of those disk IDs overlap with `mainDisk` or `coldStoragePools`. | Always run `./scripts/format-data-disks.sh --print-only` first. |
| Mirrored ZFS recovery after the host already exists | The recovery workflow may intentionally recreate only the `data` pool, depending on the scenario. | The system SSD unless the scenario explicitly says the SSD is being rebuilt. | Confirm the exact disk sets in [`vars.nix`](../vars.nix) and then use the matching scenario in [Restore And Recovery](./restore-and-recovery.md). | Use [Restore And Recovery](./restore-and-recovery.md) for the scenario recipe before touching disks. |

## Generate And Stage Secrets

Generate an age keypair if needed.

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
mkdir -p ~/.age
age-keygen -o ~/.age/agenix.key
mkdir -p secrets/pubkeys
age-keygen -y ~/.age/agenix.key > secrets/pubkeys/age.pub
```

Stage the required cleartext inputs under `secrets/top/`:
- `netbirdSetupKey`
- `cfHomeCreds`
- `cfAPIToken`
- `storageAlertWebhookUrl`

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
mkdir -p secrets/top

cat > secrets/top/netbirdSetupKey <<'EOF_KEY'
<PASTE_NETBIRD_SETUP_KEY>
EOF_KEY

cat > secrets/top/cfHomeCreds <<'EOF_CF'
{"AccountTag":"<CF_ACCOUNT_TAG>","TunnelID":"<CF_TUNNEL_ID>","TunnelSecret":"<CF_TUNNEL_SECRET>"}
EOF_CF

cat > secrets/top/cfAPIToken <<'EOF_TOKEN'
CLOUDFLARE_DNS_API_TOKEN=<CF_DNS_API_TOKEN>
EOF_TOKEN

cat > secrets/top/storageAlertWebhookUrl <<'EOF'
https://ntfy.example.test/storage
EOF
```

Generate repo-managed secrets and encrypt the staged inputs.

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
./scripts/gen-all-secrets.sh
```

Expected result:
- encrypted secrets under `secrets/` update without leaving cleartext material outside `secrets/top/`
- no error reports a missing staged input or invalid JSON for `cfHomeCreds`
- `secrets/pubkeys/age.pub` matches the private key you plan to install on the target host

Stop if wrong:
- `cfHomeCreds` is rejected as malformed JSON
- the script reports a missing staged file
- you are unsure whether the private key and `secrets/pubkeys/age.pub` belong together

For accepted formats and generated outputs:

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
./scripts/gen-all-secrets.sh --help
```

## Install The Agenix Key On The Target Host

On an existing host, copy the agenix private key in before the first guarded deploy.

- Run from: `workstation repo root`
- Privileges: `sudo required on the target host`
- Environment: `plain shell`

```bash
export SERVER_USER='dsaw'
export CURRENT_SERVER_IP='192.168.8.12'

scp ~/.age/agenix.key "$SERVER_USER@$CURRENT_SERVER_IP:/tmp/agenix.key"
ssh -t "$SERVER_USER@$CURRENT_SERVER_IP" "sudo install -d -m 0700 /etc/agenix && sudo install -m 0400 /tmp/agenix.key /etc/agenix/age.key && rm -f /tmp/agenix.key"
```

Expected result:
- `/etc/agenix/age.key` exists on the target host with mode `0400`
- the temporary copy at `/tmp/agenix.key` is gone
- the host is ready for the guarded deploy workflow in [Operations](./operations.md#guarded-deploy)

Stop if wrong:
- `scp` or `ssh` does not reach `CURRENT_SERVER_IP`
- the target host does not permit `sudo`
- the key lands anywhere other than `/etc/agenix/age.key`

## Blank-Machine Install

Boot a recent NixOS installer ISO, get network access, then clone the repo.

- Run from: `installer environment`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
mkdir -p /mnt/src
git clone <your-fork-or-origin-url> /mnt/src
cd /mnt/src
```

Preview the destructive wrapper commands first.

- Run from: `installer environment`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
./scripts/format-system-disk.sh --print-only
./scripts/format-data-disks.sh --print-only
```

Run the destructive install path only after [`vars.nix`](../vars.nix) matches the target hardware.

- Run from: `installer environment`
- Privileges: `sudo required if you are not already root`
- Environment: `plain shell`

```bash
./scripts/format-system-disk.sh
./scripts/format-data-disks.sh
findmnt -R /mnt
```

Direct `nix run ... disko ...` commands are reserved for expert or manual debugging only and are not the supported operator workflow.

Expected result:
- `/mnt` contains the new Btrfs system layout and the ZFS-backed `/mnt/data` tree
- the wrapper confirmation prompts list exactly the disk IDs you intended to destroy
- `findmnt -R /mnt` shows Btrfs for the system tree and ZFS for the mirrored data datasets

Stop if wrong:
- any disk listed by the wrapper preview is not the disk you intended
- `/mnt/data` is absent after the data-disk wrapper completes
- the wrapper output suggests that `mainDisk` overlaps with any data or cold-storage disk ID

Copy the repo into the installed system, install the agenix key, and install the OS.

- Run from: `installer environment`
- Privileges: `sudo not required if you are root in the installer`
- Environment: `plain shell`

```bash
cp -r /mnt/src/* /mnt/etc/nixos
nixos-generate-config --root /mnt
install -d -m 0700 /mnt/etc/agenix
install -m 0400 /path/to/agenix.key /mnt/etc/agenix/age.key
nixos-install --flake /mnt/etc/nixos#server
reboot
```

Expected result:
- `nixos-install` completes without unresolved secret or flake errors
- the installed system contains `/etc/agenix/age.key`
- after reboot, the host is reachable so you can continue with [Operations](./operations.md)

Stop if wrong:
- `nixos-install` cannot evaluate the flake or read secrets
- the agenix key path inside `/mnt/etc/agenix` is missing before reboot
- the machine boots but does not provide the expected network reachability for follow-up operations

For wrapper details and guardrails:

- Run from: `installer environment`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
./scripts/format-system-disk.sh --help
./scripts/format-data-disks.sh --help
```

## First Deploy And First Login

After the host is bootable and has the agenix key:
1. Run the canonical validation and guarded deploy workflow in [Operations](./operations.md).
2. Continue with [Kanidm Guide](./kanidm.md) for delegated operator login, user creation, and group grants.
3. Use [Restore And Recovery](./restore-and-recovery.md) only if the mirrored data pool or a cold-storage pool needs manual intervention.
