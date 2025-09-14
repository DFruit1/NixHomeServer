# Home Server Bootstrap Guide

This guide walks through generating secrets, deploying the system and creating the first users.

## 1. Generate an Age key pair

```bash
age-keygen -o ~/.age/agenix.key
mkdir -p secrets/pubkeys
age-keygen -y ~/.age/agenix.key > secrets/pubkeys/age.pub
```
Copy the private key to the server later as `/etc/agenix/age.key` with `0400` permissions.

## 2. Create application secrets

Ensure `age` and `openssl` are installed, then run:

```bash
./scripts/gen-all-secrets.sh
```
The script generates and encrypts the Kanidm passwords plus OIDC client secrets for Immich, Paperless, Audiobookshelf, Vaultwarden and the OAuth2 Proxy.  Clear‑text copies are written to `secrets/top/`, and the entire `secrets/` directory is ignored to keep secrets out of version control.

### Manual secrets
`cfHomeCreds`, `cfApiToken` and `netbirdSetupKey` must be provided manually. Place the raw values in `secrets/top/` and rerun the script; it verifies their format and encrypts them to `.age` files. The script exits with an error if any secret is missing or malformed.

- **netbirdSetupKey** – retrieve a setup key from the NetBird admin UI and save it to `secrets/top/netbirdSetupKey` (single line, at least 20 URL‑safe characters).
- **cfHomeCreds** – after running `cloudflared tunnel login` and `cloudflared tunnel create metro`, copy the resulting credentials JSON to `secrets/top/cfHomeCreds`.
- **cfApiToken** – create a Cloudflare API token with DNS edit rights and save it as `secrets/top/cfApiToken` in the form `CF_API_TOKEN=…`.

Once encrypted, move or delete the contents of `secrets/top` to keep clear‑text copies out of the repository.

## 3. Deploy to the server

From your workstation with SSH access to the server and Nix installed:

```bash
nix --extra-experimental-features 'nix-command flakes' run github:serokell/deploy-rs -- .#home-server
```
This builds the system and activates it on the machine at `vars.lanIP` (default `192.168.0.144`).

## 4. Bootstrap Kanidm

Install the Kanidm CLI and log in as the system administrator using the generated password:

```bash
nix shell nixpkgs#kanidm
kanidm login --name admin --password "$(age --decrypt -i ~/.age/agenix.key secrets/kanidmSysAdminPass.age)"
```
Create your first user and add them to the default group:

```bash
kanidm person create <user> --display-name "<Name>"
kanidm person set-password <user>
kanidm group add-member users <user>
```
Users can now log in to services via OIDC.

## 5. Copyparty file sharing

Copyparty is exposed at `https://share.${vars.domain}` behind the Cloudflare tunnel.  Users authenticate via Kanidm through OAuth2 Proxy and can upload or share files through the web interface.


