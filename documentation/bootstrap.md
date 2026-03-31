# Home Server Bootstrap Guide (Current)

This runbook matches the current flake and module set in this repository (`NixOS 25.05` state version, `nixpkgs` release branch `25.11`).

## What this stack includes

- Identity and SSO: **Kanidm** + **OAuth2 Proxy**
- Applications: **Immich**, **Paperless-ngx**, **Audiobookshelf**, **Copyparty**
- Edge/routing: **Caddy** + **Cloudflared tunnel**
- Networking: **Unbound + dnscrypt-proxy**, optional **NetBird** mesh
- Storage: **Disko + mergerfs + SnapRAID**
- Hardening: generated **AppArmor** profiles

Public exposure policy:

- **Cloudflare Tunnel** is intentionally limited to endpoints that must be reachable from the public internet.
- The current public set is:
  - `fileshare.<domain>`
  - `id.<domain>` (to support the public auth flow used by `fileshare`)
- Application hostnames such as `paperless`, `immich`, `photoshare`, and `audiobookshelf` are intended to stay **LAN/NetBird-only**.
- Caddy still fronts local HTTP routing; the tunnel only publishes the small public subset.
- In Cloudflare, only keep public tunnel/DNS exposure for `fileshare.<domain>` and `id.<domain>` unless you are intentionally expanding internet access.
- Internal-only app hostnames should not keep public Cloudflare routes that expose them to the internet or create tunnel 404 noise.

---

## 1) Prerequisites

On your admin workstation:

```bash
git --version
ssh -V
nix --version
```

If `nix` is missing, install it before continuing. All repository validation scripts require `nix` on `PATH`.
Repository validation also expects `rg` and `jq` on `PATH`.

Create the local secret staging folder now:

```bash
mkdir -p secrets/top
chmod 700 secrets/top
```

### Cloudflare account + tunnel prep (web)

1. Create a Cloudflare account (or sign in):  
   https://dash.cloudflare.com/
2. Make sure your domain is onboarded to Cloudflare DNS for the zone used by this repo.
3. Open **Networking → Tunnels** in the dashboard and confirm you can access your tunnel settings:  
   https://dash.cloudflare.com/?to=/:account/network/tunnels
4. Create or retrieve the credentials/token material needed for this host.
5. Save credentials into `secrets/top/cfHomeCreds` (plaintext temporary staging file).
6. Create an API token with the minimum required permissions for this setup (at least Tunnel/DNS edit for the target zone/account), then save it to `secrets/top/cfAPIToken`.
7. Protect these staged files locally until they are encrypted:

```bash
chmod 600 secrets/top/cfHomeCreds secrets/top/cfAPIToken
```

Reference docs:
- Cloudflare Tunnel setup guide: https://developers.cloudflare.com/tunnel/setup/
- Cloudflare Tunnel overview: https://developers.cloudflare.com/tunnel/

### NetBird account + setup key prep (web)

1. Create a NetBird account (or sign in):  
   https://app.netbird.io/
2. Open **Setup Keys**:  
   https://app.netbird.io/setup-keys
3. Select **Create Setup Key**.
4. Give the key a clear name (for example, `homeserver-bootstrap`), choose a safe key type/expiration, and (recommended) assign only required auto-groups.
5. Copy the generated setup key immediately (you may not be able to view it again depending on dashboard settings).
6. Save it to `secrets/top/netbirdSetupKey`, then protect the file:

```bash
chmod 600 secrets/top/netbirdSetupKey
```

Reference docs:
- NetBird setup keys: https://docs.netbird.io/manage/peers/register-machines-using-setup-keys

Clone the repository:

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

This command creates encrypted secrets for Kanidm, app OIDC clients, and OAuth2 Proxy.

Before rerunning the script, place these manual secrets in `secrets/top/`:

- `netbirdSetupKey`
- `cfHomeCreds`
- `cfAPIToken`

After encryption completes, remove cleartext files from `secrets/top/`.

---

## 4) Validate repository before deployment

```bash
NIX_CONFIG='experimental-features = nix-command flakes' nix flake check --no-build
NIX_CONFIG='experimental-features = nix-command flakes' scripts/check-repo.sh
tests/run-all.sh
tests/run-all.sh --with-runtime
tests/bootstrap-audit.sh
```

Validation flow:

- `scripts/check-repo.sh` runs the static repository policy suite through `tests/run-all.sh`.
- `tests/run-all.sh --with-runtime` also runs the live DietPi companion check for bootstrap/debugging once SSH access to the Pi is available.
- If DietPi does not allow `root` SSH login, set `DIETPI_SSH_TARGET` to the correct login user.

`tests/run-all.sh` covers bootstrap readiness, AppArmor, auth/routing policy, firewall intent, networking policy, runtime contracts, and secret ownership/consumers. Run individual scripts only for targeted debugging.

After the first successful deploy, use `documentation/first_bootstrap_checklist.md` for end-to-end operator validation (tunnel, auth, and mesh connectivity). For a single command that reports all failing runtime checks together, run `tests/bootstrap-audit.sh`.

---

## 5) Deploy

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#server \
  --target-host root@192.168.0.144 \
  --build-host root@192.168.0.144
```

This is the recommended deploy path. You need Nix on the workstation to invoke `nixos-rebuild`, but the server still builds and activates the new system over SSH.

Before deploying to a different machine, update the following in `vars.nix`:

- `serverLanIP`
- `enableDietPiCompanion`
- `piLanIP` if the DietPi companion is enabled
- `netIface`
- `serverSSHPubKey`
- `mainDisk`
- `dataDisks`
- `parityDisk`

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
- `oauth2-proxy` (now provisioned automatically from the NixOS config and agenix secret)

The configuration also provisions a `fileshare_users` Kanidm group for the public fileshare flow. Add users to that group if they should be allowed through `oauth2-proxy`. Treat `oauth2-proxy` as Nix-managed state: manage access through group membership rather than manual client edits in Kanidm after deployment.

Bootstrap note: Kanidm provisioning currently accepts invalid certificates during its local post-start flow. This is intentional because bootstrap trust currently depends on the local Caddy-presented chain rather than an already-trusted system CA path.

Use redirect/callback URLs expected by each module.

For the current public routing model, `oauth2-proxy` and the public `fileshare` flow depend on `https://id.<domain>` remaining reachable from the internet.

From a non-NetBird external network, only `https://id.<domain>` and `https://fileshare.<domain>` should resolve publicly. Internal app hostnames should remain private.

The NetBird peer should enroll automatically from `netbirdSetupKey` during startup. A brief `Disconnected` state while `netbird-main-login` runs is expected. The peer is healthy once `nb0` exists and the service reports a NetBird IP.

---

## 7) DNS and redundancy note (DietPi companion)

This companion setup is optional and should only be treated as active when `enableDietPiCompanion = true` in `vars.nix`.

You can run a separate Raspberry Pi (DietPi) for homepage, AdGuard Home, Unbound, DHCP, and power scripts **alongside** this server.

Recommended pattern:

- Keep this Nix server as app/identity/storage host.
- Put DHCP + primary LAN DNS filtering (AdGuard Home) on DietPi.
- Run Unbound on both hosts for resolver redundancy.
- Configure clients/routers with **both DNS servers** in order of preference.

Avoid split-brain by keeping one source authoritative for local overrides:

- Either keep local DNS rewrites centrally in AdGuard (forward to one/both Unbound backends),
- or keep authoritative local records on one resolver and replicate changes deliberately.

If this server is periodically powered down, make DietPi the primary always-on resolver and keep the server resolver as secondary/failover.
