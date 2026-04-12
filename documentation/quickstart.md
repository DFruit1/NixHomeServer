# Quickstart (Existing Host)

Use this guide when the server already has NixOS installed and reachable by SSH.

## 0) One-time prep block (copy/paste)
Run from your workstation in the repo root:

```bash
set -euo pipefail

# Clone if needed
# git clone <your-fork-or-origin-url> NixHomeServer
# cd NixHomeServer

mkdir -p ~/.config/nix
grep -qxF 'accept-flake-config = true' ~/.config/nix/nix.conf 2>/dev/null || echo 'accept-flake-config = true' >> ~/.config/nix/nix.conf

export SERVER_USER='<admin-user>'
export HOST_NAME="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.hostname')"
export SERVER_IP="$(nix eval --raw --impure --expr 'let flake = builtins.getFlake (toString ./.); vars = import ./vars.nix { lib = flake.inputs.nixpkgs.lib; }; in vars.serverLanIP')"

echo "HOST_NAME=$HOST_NAME"
echo "SERVER_IP=$SERVER_IP"
```

## 1) Verify workstation tools
```bash
git --version
ssh -V
nix --version
age --version
rg --version
jq --version
```

## 2) Set machine-specific values
Edit [`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix) and confirm at minimum:
- `serverLanIP`
- `netIface`
- `serverSSHPubKey`
- `mainDisk`, `dataDisks`, `parityDisk`
- `enableDietPiCompanion` and `piLanIP` (if using DietPi)

## 3) Prepare secrets
Generate age keys (skip if reusing existing recipient key):
```bash
mkdir -p ~/.age
age-keygen -o ~/.age/agenix.key
mkdir -p secrets/pubkeys
age-keygen -y ~/.age/agenix.key > secrets/pubkeys/age.pub
```

Stage required manual secrets:
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
```

Encrypt everything:
```bash
./scripts/gen-all-secrets.sh
```

## 4) Install age key on server
```bash
scp ~/.age/agenix.key "$SERVER_USER@$SERVER_IP:/tmp/agenix.key"
ssh -t "$SERVER_USER@$SERVER_IP" "sudo install -d -m 0700 /etc/agenix && sudo install -m 0400 /tmp/agenix.key /etc/agenix/age.key && rm -f /tmp/agenix.key"
```

## 5) Validate repository
```bash
nix flake check --no-build
scripts/check-repo.sh
tests/run-all.sh
```

## 6) Deploy
Preferred local-first activation:
```bash
ssh -t "$SERVER_USER@$SERVER_IP"
# then on server:
# sudo -i
# cd /etc/nixos
# nix flake check --no-build
# scripts/check-repo.sh
# nixos-rebuild test --flake .#server
# systemctl --failed
# nixos-rebuild switch --flake .#server
```

Workstation-driven deploy:
```bash
nix run nixpkgs#nixos-rebuild -- test \
  --flake ".#$HOST_NAME" \
  --target-host "$SERVER_USER@$SERVER_IP" \
  --build-host "$SERVER_USER@$SERVER_IP" \
  --sudo \
  --ask-sudo-password

nix run nixpkgs#nixos-rebuild -- switch \
  --flake ".#$HOST_NAME" \
  --target-host "$SERVER_USER@$SERVER_IP" \
  --build-host "$SERVER_USER@$SERVER_IP" \
  --sudo \
  --ask-sudo-password
```

## 7) Bootstrap Kanidm users
Use [Kanidm Guide](./kanidm.md).

Recommended operator model:
- `admindsaw`: delegated admin identity
- `dsaw`: normal daily-use identity

Recommended onboarding model:
1. create the person in Kanidm
2. add them to `users`
3. add them to app-specific `*-users` groups
4. add them to `*-admin` groups only when needed
5. have them sign into the target app so OIDC can create or link the local row

## 8) Verify expected access boundaries
- Public should work: `https://id.<domain>`, `https://files.<domain>`
- Private should require NetBird: `paperless`, `photos`, `audiobooks`, `books`, `video`, `jellyseerr`

After the first successful deploy, continue with:

1. [First Admin Session](./first-admin-session.md)
2. [Kanidm Guide](./kanidm.md)
3. [Operations](./operations.md)
