# Home Server Bootstrap Guide (Current)

This runbook matches the current flake and module set in this repository (`NixOS 25.05` state version, `nixpkgs` release branch `25.11`).

## What this stack currently includes

- Identity and SSO: **Kanidm** + **OAuth2 Proxy**
- Applications: **Immich**, **Paperless-ngx**, **Audiobookshelf**, **Copyparty**, **Kavita**, **Jellyfin**, **Jellyseerr**
- Edge/routing: **Caddy** + **Cloudflared tunnel**
- Networking: **Unbound + dnscrypt-proxy**, optional **NetBird** mesh
- Storage: **Disko + mergerfs + SnapRAID**

Public exposure policy:

- **Cloudflare Tunnel** is intentionally limited to the public endpoints that must work from the internet.
- The current public set is:
  - `fileshare.<domain>`
  - `id.<domain>` (to support the public auth flow used by `fileshare`)
- Application hostnames such as `paperless`, `photoshare` (Immich), and `audiobookshelf` are intended to stay **NetBird-only**.
- `kavita`, `jellyfin`, and `jellyseerr` follow the same **NetBird-only** policy and are routed locally through Caddy plus Unbound only.
- Caddy still fronts the HTTP routing locally; the tunnel only publishes the small public subset.
- In Cloudflare, only keep public tunnel/DNS exposure for `fileshare.<domain>` and `id.<domain>` unless you are intentionally expanding internet access.
- Internal-only app hostnames should not retain public Cloudflare routes that would expose them to the internet or return tunnel 404s.
- Private app DNS answers intentionally point at the server NetBird address, so the same FQDNs work the same way on and off the home LAN as long as the client is enrolled in NetBird.
- ACME uses DNS-01, so no public `80`/`443` exposure is required for certificate issuance.
- SSH remains exposed on public `22/tcp` for direct server administration.

---

## 1) Prerequisites

On your admin workstation:

```bash
git --version
ssh -V
nix --version
age --version
```

If `nix` is missing, install it before continuing. All repository validation scripts require `nix` on `PATH`.
Repository validation also expects `rg` and `jq` on `PATH`.

Clone repo:

```bash
git clone <your-fork-or-origin-url> NixHomeServer
cd NixHomeServer
```

This flake declares the required Nix experimental features in `flake.nix`, so the commands below can be run without prefixing `NIX_CONFIG=...`.
If Nix prompts you to trust the repository flake config, accept it. If you want to avoid future prompts globally, add `accept-flake-config = true` to `~/.config/nix/nix.conf`.

```bash
mkdir -p ~/.config/nix
grep -qxF 'accept-flake-config = true' ~/.config/nix/nix.conf 2>/dev/null || echo 'accept-flake-config = true' >> ~/.config/nix/nix.conf
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
If the repository already contains encrypted secrets, do not generate a fresh private key unless you also plan to re-encrypt those secrets for the new recipient set. In that case, first recover or import the existing private key that matches `secrets/pubkeys/age.pub`, then copy that key to the target host.

---

## 3) Generate and encrypt secrets

```bash
./scripts/gen-all-secrets.sh
```

This creates encrypted secrets for Kanidm, app OIDC clients, OAuth2 Proxy, and the Kavita token key.

Manual secrets still required in `secrets/top/` before rerunning script:

- `netbirdSetupKey`
- `cfHomeCreds`
- `cfAPIToken`

`cfAPIToken` must contain a real Cloudflare DNS token. The generator will
normalize it for ACME so both Cloudflare lego token variables are exported.
You can stage it as:
`CLOUDFLARE_DNS_API_TOKEN=<token>`.

After encryption, remove cleartext files from `secrets/top/`.

`kavitaTokenKey.age` is generated automatically, encrypted with agenix, and mounted for `services.kavita.tokenKeyFile`.

---

## 4) Validate repository before deployment

```bash
nix flake check --no-build
scripts/check-repo.sh
tests/run-all.sh
tests/run-all.sh --with-runtime
```

`scripts/check-repo.sh` runs the static repository policy suite via `tests/run-all.sh`. `tests/run-all.sh --with-runtime` additionally runs the live DietPi companion check for bootstrap/debugging once SSH access to the Pi is available. If DietPi does not allow `root` SSH login, set `DIETPI_SSH_TARGET` to the correct login user.
The `tests/run-all.sh` suite covers bootstrap-readiness, auth-routing, firewall intent, networking policy, runtime contracts, and secrets; use individual scripts only for targeted debugging.

---

## 5) Deploy

For an already-installed server, prefer a local first activation on the host before you rely on remote deploys:

```bash
ssh dsaw@192.168.0.144
sudo -i
install -d -m 0700 /etc/agenix
install -m 0400 /path/to/agenix.key /etc/agenix/age.key
cd /etc/nixos   # or your checked-out repo path on the server
nix flake check --no-build
scripts/check-repo.sh
nixos-rebuild test --flake .#server
systemctl --failed
nixos-rebuild switch --flake .#server
```

This is the safest bootstrap path for an existing machine because `test` activates the new generation without making it the boot default.

Once the host is healthy and `dsaw` SSH access plus `sudo` are working, you can drive the same machine remotely from the workstation:

```bash
nix run nixpkgs#nixos-rebuild -- test \
  --flake .#server \
  --target-host dsaw@192.168.0.144 \
  --build-host dsaw@192.168.0.144 \
  --sudo \
  --ask-sudo-password

nix run nixpkgs#nixos-rebuild -- switch \
  --flake .#server \
  --target-host dsaw@192.168.0.144 \
  --build-host dsaw@192.168.0.144 \
  --sudo \
  --ask-sudo-password
```

The old `root@...` remote deploy flow is only suitable before SSH hardening; the active config sets `PermitRootLogin = "no"`.
If you prefer not to use remote sudo prompting, SSH to the host with a TTY, become root interactively, and run `nixos-rebuild test` / `switch` locally there instead.

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

The stack provisions these OIDC clients in Kanidm:

- `immich-web`
- `paperless-web`
- `abs-web`
- `oauth2-proxy`

All four clients above are provisioned automatically from the NixOS config and
their agenix-managed secrets. Treat them as Nix-managed state rather than
editing them manually in the Kanidm UI after deploy.

The config also provisions a `fileshare_users` Kanidm group for the public
fileshare flow. Add users to that group if they should be allowed through
`oauth2-proxy`. Membership is intentionally not overwritten by provisioning, so
day-to-day access control stays a group-management task.

Copyparty itself is not a direct OIDC client in the current design. The public
`fileshare.<domain>` flow authenticates at `oauth2-proxy`, which then forwards
the authenticated request to Copyparty.

Kanidm provisioning now targets the local `https://localhost:8443` listener
during activation so it does not depend on the public `id.<domain>` route being
up mid-switch. The public `https://id.<domain>` path still needs to be checked
separately after deploy for browser-facing certificate and routing correctness.

Use redirect/callback URLs expected by each module.

For the current public routing model, `oauth2-proxy` and the public `fileshare` flow depend on `https://id.<domain>` remaining reachable from the internet.

From a non-NetBird external network, only `https://id.<domain>` and `https://fileshare.<domain>` should resolve/respond publicly; internal app hostnames should not be publicly published.

The NetBird peer should enroll automatically from `netbirdSetupKey` during
startup. A brief `Disconnected` state while `netbird-main-login` runs is
expected; the peer is healthy once `nb0` exists and the service reports a
NetBird IP.

---

## 7) DNS and redundancy note (DietPi companion)

This companion setup is optional and should only be treated as active when `enableDietPiCompanion = true` in `vars.nix`.

You can run a separate Raspberry Pi (DietPi) for Home page, AdGuard Home, Unbound, DHCP, and power scripts **alongside** this server.

Recommended pattern:

- Keep this Nix server as app/identity/storage host.
- Put DHCP + primary LAN DNS filtering (AdGuard Home) on DietPi.
- Run Unbound on both hosts for resolver redundancy only if you intentionally mirror the same private records and NetBird reachability model there.

Avoid split-brain by making one source authoritative for local overrides:

- Either keep local DNS rewrites centrally in AdGuard and forward them to the server over NetBird,
- or keep authoritative local records on one resolver and replicate changes deliberately.

If this server is periodically powered down, make DietPi the primary always-on resolver and keep the server resolver as secondary/failover.

Current private-DNS model:

- The server Unbound instance is authoritative for the private app records under `<domain>`.
- Those private records resolve to the server NetBird address from `vars.nbIP`, not the LAN address.
- `id.<domain>` and `fileshare.<domain>` are intentionally not overridden in Unbound, so they recurse to the public Cloudflare Tunnel records.
- The firewall only exposes DNS on `nb0`, so private name resolution is expected to happen through NetBird rather than by pointing the LAN router directly at the server.
- Devices that are not enrolled in NetBird will only be able to use the public tunnel hostnames.

Quick checks:

```bash
nmcli dev show | sed -n '/IP4.DNS/p;/IP4.DOMAIN/p'
nix shell nixpkgs#bind --command dig +short @100.72.113.237 paperless.sydneybasiniot.org
nix shell nixpkgs#bind --command dig +short @100.72.113.237 photoshare.sydneybasiniot.org
nix shell nixpkgs#bind --command dig +short @100.72.113.237 audiobookshelf.sydneybasiniot.org
nix shell nixpkgs#bind --command dig +short @100.72.113.237 kavita.sydneybasiniot.org
nix shell nixpkgs#bind --command dig +short @100.72.113.237 jellyfin.sydneybasiniot.org
nix shell nixpkgs#bind --command dig +short @100.72.113.237 jellyseerr.sydneybasiniot.org
nix shell nixpkgs#bind --command dig +short @100.72.113.237 id.sydneybasiniot.org
nix shell nixpkgs#bind --command dig +short @100.72.113.237 fileshare.sydneybasiniot.org
```

For NetBird peers, DNS still has to be distributed from the NetBird management plane. The local server config already permits DNS on `nb0`, but peers will not use it until a nameserver is configured in NetBird. If `netbird-main status` shows `Nameservers: 0/0 Available`, mesh DNS is not configured yet.

Recommended NetBird setup:

- Find the server NetBird IP:

```bash
ip -brief addr show nb0
```

- In NetBird admin:
  - add a nameserver using the server NetBird IP
  - assign it to the peer group(s) that should resolve the home-server domain
  - make it the primary resolver for those peers so the same `<domain>` lookups behave consistently on and off the home LAN
- Reconnect or restart NetBird on affected clients after applying the DNS change

The simplest stable model is:

- Enrolled clients: NetBird hands out the server `nb0` address as DNS
- The home LAN router does not need split-DNS awareness for the private app names
- Public internet: only `id.<domain>` and `fileshare.<domain>` remain publicly reachable through Cloudflare Tunnel

---

## 8) Post-switch verification checklist

After `nixos-rebuild switch` completes on the target host, verify the runtime
state before treating the deploy as complete.

Access checks:

- Confirm SSH login works for the seeded non-root admin user (`dsaw`) with the configured public key.
- Confirm root SSH login is rejected.
- Confirm password and keyboard-interactive SSH auth are rejected.

Service health:

```bash
systemctl status caddy kanidm oauth2-proxy cloudflared unbound paperless-web paperless-scheduler paperless-task-queue netbird-main
systemctl --failed
journalctl -b -u caddy -u kanidm -u oauth2-proxy -u cloudflared -u unbound -u paperless-web -u netbird-main
```

Networking and exposure:

- Confirm the intended globally reachable service ports are `22/tcp` for SSH and the configured NetBird/WireGuard UDP port.
- Confirm DNS (`53`) and private HTTPS (`443`) are reachable only over the NetBird interface.
- Confirm `id.<domain>` and `fileshare.<domain>` are the only publicly exposed Cloudflare endpoints.
- Confirm `paperless.<domain>`, `photoshare.<domain>`, and `audiobookshelf.<domain>` remain NetBird-only.
- Confirm `kavita.<domain>`, `jellyfin.<domain>`, and `jellyseerr.<domain>` also remain NetBird-only.

Identity and app routing:

- Open `https://id.<domain>` and confirm Kanidm loads with a valid certificate chain.
- Test the public `fileshare.<domain>` OAuth2 Proxy flow end to end.
- Test Paperless OIDC login at `https://paperless.<domain>`.
- Confirm Immich is only served at `https://photoshare.<domain>`.
- Confirm Kavita is only served at `https://kavita.<domain>`.
- Confirm Jellyfin is only served at `https://jellyfin.<domain>`.
- Confirm Jellyseerr is only served at `https://jellyseerr.<domain>`.
- Confirm there are no lingering redirects or references to `immich.<domain>`.

DNS, mesh, and secrets:

```bash
systemctl status netbird-main
ip addr show nb0
ls -l /run/agenix
```

- Confirm Unbound returns the expected local records over NetBird.
- Confirm private hostnames resolve to the server NetBird IP and `id.<domain>` / `fileshare.<domain>` recurse to Cloudflare.
- Confirm the NetBird peer enrolls and gets the expected mesh IP.
- Confirm required agenix secrets are mounted under `/run/agenix`.
- If you generated secrets locally, ensure `secrets/top/` is empty afterwards.
