# Quickstart

Use this for bootstrap only:
- workstation prerequisites
- machine-specific `vars.nix` setup
- secrets staging
- the supported destructive disk wrappers
- the initial agenix key install on a target host

Canonical validation, guarded deploy, runtime checks, and troubleshooting live in [Operations](./operations.md).

## 1. Workstation And External Prerequisites

Required workstation tools:

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

## 2. Set Machine Values

Edit [`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix) and confirm at minimum:
- `serverLanIP`
- `serverLanGateway`
- `netIface`
- `dnsMode`
- `lanDnsHosts`
- `kanidmAuthSessionExpirySeconds`
- `serverSSHPubKey`
- `mainDisk`
- `zfsDataPool`
- `coldStoragePools`

List stable disk IDs before changing storage values:

```bash
ls -l /dev/disk/by-id/
```

Use `/dev/disk/by-id/*`, not transient `/dev/sdX` names.

## 3. Generate And Stage Secrets

Generate an age keypair if needed:

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

Expected examples:

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

Generate repo-managed secrets and encrypt staged inputs:

```bash
./scripts/gen-all-secrets.sh
```

For full details on accepted formats, use:

```bash
./scripts/gen-all-secrets.sh --help
```

## 4. Install The Agenix Key On The Target Host

On an existing host, copy the agenix private key in before the first guarded deploy:

```bash
export SERVER_USER='dsaw'
export CURRENT_SERVER_IP='192.168.8.12'

scp ~/.age/agenix.key "$SERVER_USER@$CURRENT_SERVER_IP:/tmp/agenix.key"
ssh -t "$SERVER_USER@$CURRENT_SERVER_IP" "sudo install -d -m 0700 /etc/agenix && sudo install -m 0400 /tmp/agenix.key /etc/agenix/age.key && rm -f /tmp/agenix.key"
```

For the first validation gate and guarded deploy, continue with [Operations](./operations.md#2-common-commands).

## 5. Blank-Machine Install

Boot a recent NixOS installer ISO, get network access, then clone the repo:

```bash
mkdir -p /mnt/src
git clone <your-fork-or-origin-url> /mnt/src
cd /mnt/src
```

Preview the destructive wrapper commands first:

```bash
./scripts/format-system-disk.sh --print-only
./scripts/format-data-disks.sh --print-only
```

Run the destructive install path only after `vars.nix` matches the target hardware:

```bash
./scripts/format-system-disk.sh
./scripts/format-data-disks.sh
findmnt -R /mnt
```

Direct `nix run ... disko ...` commands are reserved for expert/manual
debugging only and are not the supported operator workflow.

Copy the repo into the installed system, install the agenix key, and install:

```bash
cp -r /mnt/src/* /mnt/etc/nixos
nixos-generate-config --root /mnt
install -d -m 0700 /mnt/etc/agenix
install -m 0400 /path/to/agenix.key /mnt/etc/agenix/age.key
nixos-install --flake /mnt/etc/nixos#server
reboot
```

For wrapper details and guardrails, use:

```bash
./scripts/format-system-disk.sh --help
./scripts/format-data-disks.sh --help
```

## 6. First Deploy And First Login

After the host is bootable and has the agenix key:
1. Run the canonical validation and guarded deploy workflow in [Operations](./operations.md).
2. Continue with [Kanidm Guide](./kanidm.md) for delegated operator login, user creation, and group grants.
3. Use [Restore and Recovery](./restore-and-recovery.md) only if the mirrored data pool or a cold-storage pool needs manual intervention.
