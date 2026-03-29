# Home Server Bootstrap Guide (Current)

This runbook matches the current flake and module set in this repository (`NixOS 25.05` state version, `nixpkgs` release branch `25.11`).

## What this stack currently includes

- Identity and SSO: **Kanidm** + **OAuth2 Proxy**
- Applications: **Immich**, **Paperless-ngx**, **Audiobookshelf**, **Copyparty**
- Edge/routing: **Caddy** + **Cloudflared tunnel**
- Networking: **Unbound + dnscrypt-proxy**, optional **NetBird** mesh
- Storage: **Disko + mergerfs + SnapRAID**
- Hardening: generated **AppArmor** profiles

Public exposure policy:

- **Cloudflare Tunnel** is intentionally limited to the public endpoints that must work from the internet.
- The current public set is:
  - `fileshare.<domain>`
  - `id.<domain>` (to support the public auth flow used by `fileshare`)
- Application hostnames such as `paperless`, `immich`, `photoshare`, and `audiobookshelf` are intended to stay **LAN/NetBird-only**.
- Caddy still fronts the HTTP routing locally; the tunnel only publishes the small public subset.
- In Cloudflare, only keep public tunnel/DNS exposure for `fileshare.<domain>` and `id.<domain>` unless you are intentionally expanding internet access.
- Internal-only app hostnames should not retain public Cloudflare routes that would expose them to the internet or return tunnel 404s.

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
tests/run-all.sh
tests/run-all.sh --with-runtime
```

`scripts/check-repo.sh` runs the static repository policy suite via `tests/run-all.sh`. `tests/run-all.sh --with-runtime` additionally runs the live DietPi companion check for bootstrap/debugging once SSH access to the Pi is available. If DietPi does not allow `root` SSH login, set `DIETPI_SSH_TARGET` to the correct login user.
The `tests/run-all.sh` suite covers bootstrap-readiness, AppArmor, auth-routing, firewall intent, networking policy, runtime contracts, and secrets; use individual scripts only for targeted debugging.

---

## 5) Deploy

```bash
nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#server \
  --target-host root@192.168.0.144 \
  --build-host root@192.168.0.144
```

This is the recommended deploy path. It requires Nix on the workstation so you can invoke `nixos-rebuild`, but the server still builds and activates the new system itself over SSH rather than building on the workstation.

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
- `oauth2-proxy`

Use redirect/callback URLs expected by each module.

For the current public routing model, `oauth2-proxy` and the public `fileshare` flow depend on `https://id.<domain>` remaining reachable from the internet.

From a non-NetBird external network, only `https://id.<domain>` and `https://fileshare.<domain>` should resolve/respond publicly; internal app hostnames should not be publicly published.

---

## 7) DNS and redundancy note (DietPi companion)

This companion setup is optional and should only be treated as active when `enableDietPiCompanion = true` in `vars.nix`.

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
