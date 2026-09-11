# New Owner Checklist

Use this checklist when this repository is handed to a **different person who
will run it at a different house**, with their own router, Cloudflare account,
and NetBird network. It is a companion to the [Quickstart](./quickstart.md): the
Quickstart is the authoritative install procedure, and this page highlights the
values and credentials that must **not** be inherited from the previous owner.

The single source of truth for host values is [`vars.nix`](../vars.nix). Secret
material is separate and is re-encrypted to the new owner's age key.

> **Do not reuse the previous owner's age private key.** If you keep the old
> `secrets/pubkeys/age.pub` and its ciphertext, every inherited credential stays
> readable by the previous owner. Start with a **new age keypair** and `--fresh`
> secrets, as described below.

## 0. Start a clean, private copy

- [ ] Fork or clone the repository into the **new owner's** private remote.
- [ ] Confirm `git status --short` is clean and record `git rev-parse HEAD`.
- [ ] Do not copy `secrets/unencrypted/` or any plaintext staging from anywhere.
- [ ] Read the [Quickstart](./quickstart.md) once end to end before touching disks.

## 1. Configure the new host in `vars.nix`

Replace every value that belongs to the previous site. At minimum:

- [ ] `branding.displayName`
- [ ] `applications.enabled` — only the apps this host should run.
- [ ] `identity.adminUser`, `identity.localAdminUser`, `identity.sshPublicKey`
- [ ] `identity.appUsers`, `identity.appAdminUsers`, `identity.appUserEmails`
- [ ] `identity.adminEmail` — must be a real mailbox for ACME and Kanidm.
- [ ] `network.hostname`, `network.domain` (the new owner's Cloudflare zone)
- [ ] `network.lanInterface`, `network.lanIp`, `network.lanPrefixLength`, `network.lanGateway`
- [ ] `network.lanMode` — `"static"` pins the LAN IP; `"dhcp"` leases it, but
      `network.lanIp` must still be the router's reservation (DNS and firewall
      scoping use it).
- [ ] `network.netbirdIp` and `network.netbirdCidr` — set after first enroll, or
      leave a best guess and let first boot adopt the assigned address.
- [ ] `system.hardwareProfile`, `system.cpuVendor`, `system.timeZone`, `system.hostId`
- [ ] `system.buildMode` and the store/cleanup/alert settings
- [ ] `dnsSettings.mode`
- [ ] `edge.cloudflareTunnelName`
- [ ] `storage.profile`, `storage.systemDisk`, `storage.dataPool.*`
- [ ] `offlineMedia.enable`, `offsiteBackup.*`, `staleReferenceCleanup`

Verify the result without changing anything:

```bash
nix run .#bootstrap-host -- check
nix run .#show-config-summary
```

## 2. Regenerate the hardware module on the target

`hardware-configuration.nix` is host-specific. On the **new machine's installer**,
before any disk is erased:

```bash
nixos-generate-config --no-filesystems --show-hardware-config > hardware-configuration.nix
git add hardware-configuration.nix vars.nix
git commit -m "Record target hardware configuration"
```

The readiness gate (below) cross-checks the module against the detected CPU and
blocks a module copied from another vendor.

## 3. Create the new owner's identity (do **not** reuse the old key)

A fork still contains the previous owner's `secrets/pubkeys/age.pub` and
ciphertext, and `bootstrap-host identity --create` deliberately refuses to
replace an existing recipient. Remove the inherited secret material first:

```bash
git rm secrets/pubkeys/age.pub
git rm 'secrets/*.age'   # inherited ciphertext encrypted to the old key
```

Now create the new identity:

```bash
nix run .#bootstrap-host -- identity --create /secure/nixhomeserver-age.age
```

This writes the new recipient to `secrets/pubkeys/age.pub`. Keep the private key
off the repository and back it up to separately mounted durable storage exactly
as the Quickstart requires. `--fresh` in the next step regenerates every
generated secret and re-encrypts the staged external values to the new key.

## 4. Stage the new owner's external secrets

Create `secrets/unencrypted/` (mode 0700) and stage values that belong to the
**new** owner's accounts:

- [ ] `netbirdSetupKey` — a setup key from the new NetBird network.
- [ ] `cfHomeCreds` — Cloudflare Tunnel credentials JSON for the new tunnel.
- [ ] `cfAPIToken` — Cloudflare DNS API token with `DNS:Edit` on the new zone.
- [ ] Optional: `rcloneMegaPassword` (only if `offsiteBackup.enable = true`).
- [ ] Optional: `failureAlertWebhookUrl`, `openSubtitlesCredentials`, `acoustidApiKey`.

Then generate fresh, re-encrypted secrets:

```bash
nix run .#bootstrap-host -- secrets --identity /secure/nixhomeserver-age.age
# or explicitly:
nix run .#generate-secrets -- --fresh --identity /secure/nixhomeserver-age.age
rm -rf secrets/unencrypted
```

`--fresh` replaces every generated credential and requires the new external
values above. It never carries over the previous owner's accounts.

> **Never use `--rekey` to move to a new owner.** Rekey preserves values, so it
> also carries the previous owner's NetBird, Cloudflare, MEGA, and provider
> accounts to the new server (the tool refuses external secrets unless you pass
> `--allow-external-secrets`). Use `--rekey` only to rotate the recipient on the
> **same** installation.

## 5. Point the new owner's edge at the new host

- [ ] The domain is delegated to the new owner's Cloudflare zone.
- [ ] Add every Cloudflare Tunnel ingress hostname from `nix run .#show-config-summary`
      as a Public Hostname (or a proxied CNAME to `<TunnelID>.cfargotunnel.com`).
      Credentials and the API token do not create those DNS records.
- [ ] The NetBird setup key enrolls this server into the new owner's network.
      First boot adopts the assigned peer address into `vars.nix`.

## 6. Install, deploy, and verify

Follow the Quickstart from "Provision Blank Disks." Before any destructive step,
run the full readiness gate on the target with the new identity:

```bash
nix run .#validate-config-readiness -- \
  --host <vars.hostname> --require-local-hardware \
  --identity /secure/nixhomeserver-age.age
```

After installation and first boot, run the guarded test and switch:

```bash
./scripts/deploy.sh --action test
./scripts/deploy.sh --action switch
```

## 7. Ownership and access hygiene

- [ ] Confirm the Kanidm operator, local admin, and app users are the new
      owner's people, not the previous owner's.
- [ ] Confirm `~/.ssh/config` on the admin workstation uses the new server's key.
- [ ] Keep the age key and the MEGA/Cloudflare/NetBird credentials in the new
      owner's password manager; leave nothing in `secrets/unencrypted/`.
- [ ] Move the previous owner's plaintext values out of reach once migration is
      verified.

## Do not do

- Do not reuse the previous owner's age private key or `secrets/pubkeys/age.pub`.
- Do not run `--rekey` from the previous owner's key to the new owner's key.
- Do not copy the previous owner's `vars.nix` values, SSH key, or external secrets.
- Do not point the new server at the previous owner's Cloudflare tunnel or
  NetBird network.
- Do not run Disko before the readiness gate is clean and every disk has been
  verified by `/dev/disk/by-id`.
