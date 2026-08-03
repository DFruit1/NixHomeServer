# NixHomeServer

NixHomeServer is a reproducible NixOS home-server for identity, private app
access, files, photos, documents, media, monitoring, and encrypted backups. It
is built around guarded deployment, impermanent system state, explicit
persistence, and application modules that can be removed independently.

## Start Here

Choose the guide that matches what you are doing:

- [First installation](documentation/quickstart.md) — hardware discovery,
secrets, destructive disk provisioning, installation, and first boot.
- [Routine operations](documentation/operations.md) — guarded deploys,
validation, service checks, users, backups, Mail Archive, and maintenance.
- [Restore and recovery](documentation/restore-and-recovery.md) — system-disk,
ZFS mirror, local Kopia, offsite, and application-state recovery.
- [Kanidm](documentation/kanidm.md) — identity and group administration.
- [Vaultwarden](documentation/vaultwarden.md) — password-manager setup and
recovery boundaries.
- [Bonsai Local AI](documentation/bonsai.md) — model/runtime compatibility,
memory sizing, local OpenAI API, and vision requests.
- [Paperless-ngx v3 readiness](documentation/paperless-v3.md) — guarded
  unstable-package switch, migration checks, and local Bonsai AI configuration.
- [Custom app development](documentation/custom-app-development.md) — package,
module, and test conventions.

The [Quickstart](documentation/quickstart.md) is the authoritative bootstrap
procedure. It intentionally contains the exact destructive commands and safety
checks in one place; do not assemble an install procedure from README snippets.

For a new host, begin with:

```bash
cp vars.example.nix vars.nix
$EDITOR vars.nix
nix run .#show-config-summary
```

Then follow the Quickstart from “Discover Target Hardware.” Never run Disko
until its readiness gate is clean and every selected disk has been independently
verified from `/dev/disk/by-id`.

## Hosted Applications

The application catalog currently includes:

- Immich, Paperless, Filestash, Mail Archive, and Vaultwarden.
- Jellyfin, automated DVD ISO conversion, Audiobookshelf, Kavita, Kiwix, and offline media sync.
- Sonarr, Radarr, Prowlarr, qBittorrent, Seerr, and YouTube Downloader.
- Bonsai Local AI, Homepage, Groundwater Logger, and the supporting monitoring
surfaces.
- Attic, providing a loopback-only binary cache for custom applications built
  on the server.

Core services provide Kanidm, Caddy, Cloudflared, NetBird, Unbound, failure
alerts, Kopia, storage layout, backups, and impermanence. Beszel is an optional
application module. Application metadata and
integration imports live in [`modules/catalog.nix`](modules/catalog.nix), so a
new app has one catalog entry for its module, secrets, and removal guards.

## Configuration Model

Normal operator values live near the top of [`vars.nix`](vars.nix). Shared
compatibility and derived values live in
[`lib/derive-vars.nix`](lib/derive-vars.nix), preventing the real and example
configurations from drifting apart.

`applications.enabled` is the per-host application allowlist. Only names in
that list are imported into the NixOS configuration and included in routine
custom-app checks. The catalog remains the repository-wide inventory; omitting
an app from a host does not remove its source or exhaustive CI coverage.

[`hosts.nix`](hosts.nix) is the host catalog. Its key must match each settings
file's `network.hostname`; an early typed boundary rejects malformed platform,
storage, user-list, GID, and port values before building a NixOS system. Add a
second settings import there when managing another host from the same flake.

`system.buildMode` controls guarded-deploy build allocation: `local` uses all
workstation slots, `remote` uses all server slots, `balanced` uses two slots on
each with a best-effort one-core-per-job hint, and `maximum-effort` uses every
available slot on both. See
[Build Allocation](documentation/operations.md#build-allocation) for the native
Nix settings and one-shot overrides.

Encrypted values use the manifest-driven agenix flow:

```bash
nix run .#generate-secrets
nix run .#validate-config-readiness -- --allow-unverified-secrets
```

Plaintext staging under `secrets/unencrypted/` is deliberately ignored and must
be empty before installation or deployment. Do not commit plaintext secrets.

## Safe Deployment

Use the guarded deploy app for normal changes:

```bash
nix run .#deploy
```

It evaluates and builds before switching, checks critical routes and units, and
restores the previous live and boot generations when health verification fails.
Direct `nixos-rebuild switch` is reserved for documented console recovery.

Routine validation is:

```bash
scripts/validate-repo.sh
```

Before merging a broad or risky change, run:

```bash
scripts/validate-repo.sh --full
```

That full gate remains scoped to `applications.enabled`. To validate and build
the entire application catalog, including apps disabled for this host, run:

```bash
scripts/validate-repo.sh --full --all-apps
```

The flake also exposes lint, Rust, frontend, module-removal, encrypted restore
round-trip, Disko evaluation, and NixOS VM checks. CI runs the lean gate on
pushes and pull requests, plus the exhaustive all-app gate on a weekly schedule.

## Reliability and Recovery Boundaries

- ZFS mirroring protects against a member disk failure; it is not a backup.
- Kopia stores encrypted snapshots locally, and the optional Rclone job mirrors
the encrypted repository offsite.
- The restore check creates a fresh encrypted repository, reconnects with a new
client state, restores mixed file types, and compares the result.
- Backup, snapshot-health, SMART, offsite-sync, and authenticated-canary
failures trigger a consolidated systemd alert handler.
- To enable external alerts, encrypt the optional
`failureAlertWebhookUrl` manifest secret. Set
`repo.monitoring.failureAlerts.format = "ntfy"` for a full ntfy topic URL;
the default sends JSON to a generic HTTPS webhook.
- Mail Archive reads a consistent Paperless database snapshot and fails closed
when duplicate detection is stale or unavailable. Per-attachment locks make
repeated UI/timer handoffs idempotent.

See [Restore and recovery](documentation/restore-and-recovery.md) before
changing disks or restoring data. Restore into a separate path first; preserve
the failed state until the recovered data has been inspected.

## Repository Layout

```text
configuration.nix       top-level module assembly from the app catalog
hosts.nix               deployable host catalog
vars.nix                operator settings for the current host
lib/derive-vars.nix     shared derived and compatibility settings
modules/catalog.nix     apps, integrations, owned secrets, removal guards
modules/Core_Modules/   always-present platform services
modules/<app>/          independently removable application modules
custom_apps/            first-party Rust and Node applications
scripts/                deployment, administration, and regression checks
documentation/          install, operations, and recovery runbooks
```

New files must be tracked before Nix evaluation because flakes only see tracked
source files. Build artifacts, caches, and plaintext secrets must remain
untracked.
