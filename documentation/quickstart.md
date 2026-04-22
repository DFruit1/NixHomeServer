# Quickstart

Use this as the single bootstrap guide for:
- first deploys to an existing NixOS host
- blank-machine installs from a NixOS installer ISO
- secrets staging
- the supported destructive disk wrapper entrypoints

The operator contract is simple:
- machine-specific values live in [`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix)
- `./scripts/gen-all-secrets.sh` is the only documented secrets entrypoint
- `./scripts/format-system-disk.sh` and `./scripts/format-data-disks.sh` are the only documented destructive Disko entrypoints
- `./scripts/deploy-validated.sh` is the normal remote deploy path

## 1. Workstation And External Prereqs

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

## 4. Existing Host Deploy

Derive the intended target IP from `vars.serverLanIP`, then keep any temporary
SSH cutover address in a local override only:

```bash
export TARGET_SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"
export CURRENT_SERVER_IP="${CURRENT_SERVER_IP:-$TARGET_SERVER_IP}"
export SERVER_USER='dsaw'
export HOST_NAME="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.hostname')"
```

Install the agenix private key on the target host:

```bash
scp ~/.age/agenix.key "$SERVER_USER@$CURRENT_SERVER_IP:/tmp/agenix.key"
ssh -t "$SERVER_USER@$CURRENT_SERVER_IP" "sudo install -d -m 0700 /etc/agenix && sudo install -m 0400 /tmp/agenix.key /etc/agenix/age.key && rm -f /tmp/agenix.key"
```

Run the repo validation gate:

```bash
nix flake check --no-build
scripts/check-repo.sh
tests/run-all.sh
tests/core-config.sh
```

Run the guarded deploy:

```bash
./scripts/deploy-validated.sh \
  --target "$SERVER_USER@$CURRENT_SERVER_IP" \
  --build-host "$SERVER_USER@$CURRENT_SERVER_IP" \
  --action test \
  --hostname "$HOST_NAME"
```

Switch only after the test generation looks correct:

```bash
./scripts/deploy-validated.sh \
  --target "$SERVER_USER@$CURRENT_SERVER_IP" \
  --build-host "$SERVER_USER@$CURRENT_SERVER_IP" \
  --action switch \
  --hostname "$HOST_NAME"
```

For argument details and cutover notes, use:

```bash
./scripts/deploy-validated.sh --help
```

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

Run the destructive install path only after `vars.nix` matches the target
hardware:

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

## 6. Post-Boot

After first boot:
1. Run the validation gate again from the repo root.
2. Continue with [Operations](./operations.md) for runtime checks, DNS expectations, and guarded day-2 deploys.
3. Continue with [Kanidm Guide](./kanidm.md) for admin login, user creation, and group grants.
