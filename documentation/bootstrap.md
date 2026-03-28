# Home Server Bootstrap Guide (Current)

This runbook matches the current flake and module set in this repository (`NixOS 25.05` state version, `nixpkgs` release branch `25.11`).

## What this stack currently includes

- Identity and SSO: **Kanidm** + **OAuth2 Proxy**
- Applications: **Immich**, **Paperless-ngx**, **Audiobookshelf**, **Copyparty**
- Edge/routing: **Caddy** + **Cloudflared tunnel**
- Networking: **Unbound + dnscrypt-proxy**, optional **NetBird** mesh
- Storage: **Disko + mergerfs + SnapRAID**
- Hardening: generated **AppArmor** profiles

---

## 1) Prerequisites

On your admin workstation:

```bash
git --version
ssh -V
nix --version
```

If `nix` is missing, install it before continuing. All repository validation scripts require `nix` on `PATH`.

Clone repo:

```bash
git clone <your-fork-or-origin-url> NixHomeServer
cd NixHomeServer
```

---

## 2) Prepare Age key material

```bash
mkdir -p ~/.age
age-keygen -o ~/.age/agenix.key
mkdir -p secrets/pubkeys
age-keygen -y ~/.age/agenix.key > secrets/pubkeys/age.pub
```

Copy the private key to target host as `/etc/agenix/age.key` with mode `0400`.

---

## 3) Generate and encrypt secrets

```bash
./scripts/gen-all-secrets.sh
```

This creates encrypted secrets for Kanidm, app OIDC clients, and OAuth2 Proxy.

Manual secrets still required in `secrets/top/` before rerunning script:

- `netbirdSetupKey`
- `cfHomeCreds`
- `cfAPIToken`

After encryption, remove cleartext files from `secrets/top/`.

---

## 4) Validate repository before deployment

```bash
nix flake check --no-build
scripts/check-repo.sh
```

Both should pass locally before deploy.

---

## 5) Deploy

```bash
nix --extra-experimental-features 'nix-command flakes' \
  run github:serokell/deploy-rs -- .#home-server
```

Target defaults to `vars.lanIP`.

---

## 6) Bootstrap Kanidm

```bash
nix shell nixpkgs#kanidm
kanidm login --name admin --password "$(age --decrypt -i ~/.age/agenix.key secrets/kanidmSysAdminPass.age)"
kanidm person create <user> --display-name "<Name>"
kanidm person set-password <user>
kanidm group add-member users <user>
```

Then configure OIDC clients in Kanidm for:

- `immich-web`
- `paperless-web`
- `abs-web`
- `copyparty-web`
- `oauth2-proxy`

Use redirect/callback URLs expected by each module.

---

## 7) DNS and redundancy note (DietPi companion)

You can run a separate Raspberry Pi (DietPi) for Home page, AdGuard Home, Unbound, DHCP, and power scripts **alongside** this server.

Recommended pattern:

- Keep this Nix server as app/identity/storage host.
- Put DHCP + primary LAN DNS filtering (AdGuard Home) on DietPi.
- Run Unbound on both hosts for resolver redundancy.
- Configure clients/routers with **both DNS servers** in order of preference.

Avoid split-brain by making one source authoritative for local overrides:

- Either keep local DNS rewrites centrally in AdGuard (forward to one/both Unbound backends),
- or keep authoritative local records on one resolver and replicate changes deliberately.

If this server is periodically powered down, make DietPi the primary always-on resolver and keep the server resolver as secondary/failover.
