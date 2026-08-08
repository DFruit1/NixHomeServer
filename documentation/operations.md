# Operations

Use this as the maintained day-2 operations guide for validation, guarded deploys, rollback, service health, SMART monitoring, and first-response troubleshooting.

## Service Access Canary

`canary-user` is a non-privileged Kanidm person used by the Homepage admin
service-access test. It belongs to normal application groups and receives
monitoring access only when Beszel is selected, but never to the backup groups, `app-admin`,
`domain_admins`, `system_admins`, or delegated `idm_*` groups.

`kanidm-canary-bootstrap.service` automatically provisions the generated
`canaryUserPassword`, enrolls a Kanidm-generated SHA-256 TOTP credential, and
verifies a real password-plus-TOTP login. The root-only TOTP seed is persisted
at `/var/lib/homepage-canary-credentials/kanidm-totp-seed`; it is synthetic
operational state and does not need to be staged by an operator.

```bash
systemctl status kanidm-canary-bootstrap.service
journalctl -u kanidm-canary-bootstrap.service -n 100 --no-pager
```

The bootstrap is idempotent: a normal boot verifies the existing credentials
and leaves them unchanged. If the persisted seed is missing, corrupt, or no
longer matches Kanidm, it replaces the synthetic account credentials and
publishes a new root-only seed without printing secret material to the journal.
No browser enrollment or reset-token handoff is required.

The suite verifies unauthenticated blocking, Kanidm login, expected application
content, and visually blank pages even when the server returned HTTP 200.
Jellyfin is checked through native OIDC plus a separate Quick Connect exchange
that verifies the expected user and revokes the canary token. Vaultwarden has a
native login; Kopia and Beszel add native login after SSO. Those remaining
services are reported as boundary-only checks and no app-local credentials are
stored.

Guarded deploys run the suite after public-route checks and return nonzero on a
failure. A failing health gate immediately restores the previous live
generation; the target-side rollback timer remains the backstop if immediate
recovery cannot complete. Failure JSON is stored under
`/var/lib/homepage-canary/failures` for 14 days; it contains statuses and render
metrics but no screenshots, HTML, cookies, or passwords.

```bash
sudo systemctl start homepage-canary.service
sudo homepage-canary-assert
sudo journalctl -u homepage-canary.service -n 100 --no-pager
```

Normal day-2 builds run on the server, but the administrator's workstation still
needs the `nix` command. The deploy wrapper uses it for local flake/hostname
validation before staging the repository over SSH; the server performs the
resource-intensive NixOS evaluation, build, activation, and secret generation.
Use the Nix-capable workstation prepared in the quickstart for both bootstrap
and routine deploys.

## After Bootstrap

A first install is complete when the host accepts SSH for `vars.localAdminUser`,
the agenix key is installed at `/persist/etc/agenix/age.key` (and visible at
`/etc/agenix/age.key` through impermanence after boot), the storage mounts are
present, and a guarded test deploy passes:

```bash
./scripts/deploy.sh --debug --action test
```

After that point, do not return to installer-time disk provisioning for normal
work. Routine changes use the guarded deploy path:

```bash
./scripts/deploy.sh --action test
./scripts/deploy.sh --action switch
```

Once homepage and SSO are reachable, use the homepage "For Admins" page for
live app configuration, user onboarding commands, and common server-management
reminders.

## Failure Alerts

Important backup, snapshot-freshness, SMART, offsite-sync, and authenticated
canary failures always create a `daemon.alert` journal event through
`nixhomeserver-failure-alert@.service`.

To deliver those events externally, stage and encrypt the optional manifest
secret containing the full HTTPS webhook URL:

```bash
install -d -m 0700 secrets/unencrypted
install -m 0600 /path/to/webhook-url secrets/unencrypted/failureAlertWebhookUrl
nix run .#generate-secrets -- \
--replace-external failureAlertWebhookUrl \
--identity /path/to/current/age.key
rm -f secrets/unencrypted/failureAlertWebhookUrl
rmdir secrets/unencrypted 2>/dev/null || true
git add secrets/failureAlertWebhookUrl.age
```

The default webhook body is JSON. For a full ntfy topic URL, set this in host
configuration and deploy:

```nix
repo.monitoring.failureAlerts.format = "ntfy";
```

Test the local delivery path without breaking a production service:

```bash
sudo systemd-run --unit=nixhomeserver-alert-test \
--property='OnFailure=nixhomeserver-failure-alert@%n.service' \
/bin/false
sudo journalctl -t nixhomeserver-failure-alert -n 20 --no-pager
```

## Disabling Optional Applications

Application modules are independent and opt-in per host. Add or remove catalog
names in `applications.enabled` in that host's settings file. An omitted module
is not imported, so its packages, services, secrets, and app-specific checks do
not enter a routine rebuild. Keep its `modules/catalog.nix` entry: the catalog
is the repository-wide inventory used by `--all-apps` validation. Integrations
are cataloged separately and detect absent application options as no-ops. The
exhaustive regression suite evaluates Core-only, every optional module removed
independently, and a targeted single-app topology.

The following imported modules also have a convenient active-feature switch.
Setting one to `false` removes its services, routes, DNS, configured identity
surfaces, app-owned secret materialization/requirements, backup registrations,
and integrations while leaving centrally managed persistence in place:

```nix
repo.groundwaterLogger.enable = false;
repo.bonsai.enable = false;
repo.kiwix.enable = false;
repo.prowlarr.enable = false;
repo.qbittorrent.enable = false;
repo.radarr.enable = false;
repo.seerr.enable = false;
repo.sonarr.enable = false;
services.mail-archive-ui.enable = false;
```

Seerr already defaults to disabled. Offline Media uses
`offlineMedia.enable = false` in `vars.nix`; its cleanup unit revokes generated
Syncthing runtime configuration without deleting persisted application data.
Do not remove application paths from the central impermanence inventory merely
because an app is disabled. After changing imports or flags, run a guarded test
deploy before switching. Kanidm automatic deletion is intentionally disabled,
so identity objects provisioned by an earlier generation may remain inert until
an administrator explicitly retires them; the Homepage admin guide documents
that separate cleanup workflow.

## Local-Console Administrator Recovery

The generated `serverBootstrapSudoPassword` is reconciled as the password for
`vars.localAdminUser`. It is a local-console recovery path if the administrator's
SSH key is unavailable; it does not enable password login over the network.
OpenSSH password and keyboard-interactive authentication both remain disabled.

On a trusted machine with the repository and private age identity, decrypt the
recovery value and use it only at the server's physical or virtual console:

```bash
age --decrypt --identity /path/to/age.key \
secrets/serverBootstrapSudoPassword.age
```

On the running server, root can read the same value from
`/run/agenix/serverBootstrapSudoPassword` if an interactive sudo prompt is
unavoidable. Treat the output as a password: do not paste it into chat, tickets,
command arguments, or shell history.

## Common Commands

- Remote validation gate: `./scripts/deploy.sh --debug --action test`
- Local validation gate: `nix flake check --no-build` then `scripts/validate-repo.sh`
- Flake-inclusive local gate: `scripts/validate-repo.sh --run-flake-check`
- Full local gate: `scripts/validate-repo.sh --full`
- Exhaustive catalog gate: `scripts/validate-repo.sh --full --all-apps`
- Human config summary: `nix run .#show-config-summary`
- Machine-readable inventory: `nix run .#export-inventory`
- Guarded deploy: `./scripts/deploy.sh --action test`
- Full guarded deploy: `./scripts/deploy.sh --action test --debug`
- Guarded switch: `./scripts/deploy.sh --action switch`
- Local-build deploy: `./scripts/deploy.sh --build-locally --action test`
- Server-side secret verification: `ssh <admin>@<hostname> 'cd /path/to/repo && nix run .#generate-secrets -- --identity /persist/etc/agenix/age.key'`
- Service health: `sudo systemctl --failed --no-pager`
- List/retrieve one-time Jellyfin credentials: `sudo jellyfin-initial-credential [USERNAME]`
- Reconcile Jellyfin OIDC and Quick Connect: `sudo systemctl start jellyfin-oidc-bootstrap-v1.service`
- SMART sweep: `sudo systemctl start storage-smart-short.service`
- Local encrypted backup repository: `/mnt/data/backups/kopia`
- External USB media auto-mount root: `/mnt/external-usb/` (drives mount on insertion; shared `_USB` view at `/mnt/usb-access-view` is gated to `usb-access`)

## Nix Store Capacity Garbage Collection

`nixhomeserver-nix-gc.timer` checks the Nix store hourly. It starts collection
when `/nix/store` reaches 90% of `system.nixStoreMaxSizeGiB` or when the
filesystem containing the store reaches 90% usage. The shared maintenance lock
prevents it from overlapping Nix store optimisation.

`system.nixGcRetentionDays` defaults to 45. The collector passes that value to
`nix-collect-garbage --delete-older-than`, which deletes profile generations
older than the retention period before collecting all unreachable store paths.
The active generation is retained, but deleted generations can no longer be
used for rollback. Unreachable paths themselves are not filtered by age.

Every check emits a structured `nix_store_gc_check` journal event containing
the measured store bytes, exact filesystem used/total bytes, threshold,
decision, and trigger reason. A pressured check that cannot obtain the shared
maintenance lock emits `nix_store_gc_deferred`; the next hourly run checks
again. Collection adds `nix_store_gc_recheck`, `nix_store_gc_started`, and
`nix_store_gc_completed`; completion records before/after sizes and freed
bytes. Failures emit `nix_store_gc_failed` and use the normal systemd failure
alert path. Collector failures include the final 8 KiB of diagnostic output as
base64 in `collector_output_base64`; decode it with
`jq -r .collector_output_base64 | base64 -d`.

```bash
systemctl status nixhomeserver-nix-gc.timer
journalctl -u nixhomeserver-nix-gc.service --output=cat
sudo systemctl start nixhomeserver-nix-gc.service
```

## Workstation Nix Store Garbage Collection

The capacity collector above only covers the deployed server; the workstation
that evaluates and builds deploys has no equivalent timer. Set
`system.localNixGCMode` in `vars.nix` to `"never"`, `"capacity"`, or `"always"`.
Capacity mode runs the existing threshold helper against the local
`/nix/store`, using `system.nixStoreMaxSizeGiB`,
`system.nixGcRetentionDays`, and a user-writable maintenance lock. It skips
collection while both the store and its filesystem remain below their
configured pressure thresholds. Always mode preserves the former unconditional
`nix-store --gc` behavior; never mode performs no deploy-time local collection.

For compatibility, `system.localNixGC = true` maps to `"always"` and `false`
maps to `"never"` when `localNixGCMode` is absent. An explicit mode takes
precedence. Generation-based cleanup on the workstation remains the
responsibility of the workstation's own Nix configuration.

```bash
nix-store --gc
```

`/mnt/data` is the configured data root for both storage profiles. On
`zfs-mirror` it is a ZFS pool mountpoint; on `single-disk-ext4` it is a normal
directory on the root filesystem.

## App Hostnames

Immich uses separate private and public hostnames on purpose. Show evaluated
URLs for a site with `nix run .#show-config-summary -- --host <host>`.

- Private Immich app: `https://<photos-domain>`
- Public Immich share links: `https://<share-photos-domain>`
- Authenticated Filestash browser UI: `https://<files-domain>/`
- LAN-only direct SFTP: `sftp://<username>@<server-lan-host>:<filesSftp-port>/`
- Private Vaultwarden: `https://<passwords-domain>`
- Local Kopia backup management UI: `https://<kopia-domain>/`

Use the private photos hostname for the owner's normal Immich login on LAN or
NetBird. Use the public share hostname only for public album or photo links sent
to other people.

### Jellyfin login paths

Jellyfin keeps its existing accounts authoritative, so watch history, personal
preferences, administrator state, and repository-managed library policies stay
attached to the same exact username.

1. In a browser, choose **Sign in with Kanidm**. The confidential `jellyfin-web`
   client permits only members of `jellyfin-users`, and the plugin matches the
   validated `preferred_username` to an existing Jellyfin account. It does not
   create users or apply role mappings.
2. On a TV or native app, initiate ordinary Jellyfin Quick Connect. Authorize
   the six-digit code from an existing Jellyfin browser session or open
   `https://videos.<domain>/sso/OIDC/QuickConnect/kanidm` and sign in to Kanidm.
   The server publishes this instruction as a plain-text login disclaimer so
   clients such as Fladder can display it without leaking browser-only HTML.
3. If a client cannot use either path, use the native username/password
   fallback. List available usernames with `sudo jellyfin-initial-credential`,
   retrieve one with `sudo jellyfin-initial-credential USERNAME`, then change it
   after the first login. A native client password field accepts this Jellyfin
   password, not the user's Kanidm password.

The root-only password handoff files live under
`/var/lib/jellyfin/.nixos-managed/initial-credentials/`; reconciliation never
overwrites a password after its durable initialization marker is recorded.
Native password authentication is intentionally enabled for client
compatibility.

Jellyfin OIDC is pinned to locally built `jellyfin-plugin-oidc` 1.0.8.0 with
automatic plugin updates disabled. Its immutable assemblies are read-only bound
into Jellyfin from the Nix store. The provider uses
`https://videos.<domain>` only for OIDC redirects; Jellyfin has no global
published-server URL override, so LAN discovery continues advertising its
direct address on TCP 8096 after a UDP 7359 discovery response.

Useful diagnostics:

```bash
sudo systemctl status jellyfin.service jellyfin-oidc-bootstrap-v1.service --no-pager
sudo journalctl -u jellyfin.service -u jellyfin-oidc-bootstrap-v1.service --since today
curl -fsS https://videos.<domain>/QuickConnect/Enabled
curl -fsS https://videos.<domain>/sso/OIDC/Providers
sudo stat -c '%U:%G %a %n' /var/lib/jellyfin/plugins/configurations/Jellyfin.Plugin.OIDC.xml
```

### Jellyfin and Fladder LAN discovery

Fladder binds a temporary IPv4 UDP port, broadcasts `Who is JellyfinServer?` to
`255.255.255.255:7359`, and waits for replies. Jellyfin returns a unicast packet
from UDP source port `7359` to the client’s temporary UDP port, followed by a
normal connection to the advertised TCP 8096 address. This limited broadcast
does not cross routers or VLANs. Keep the client on the same IPv4 broadcast
network as the server and disable guest-Wi-Fi, AP, or client isolation. These
details follow [Fladder's discovery implementation](https://github.com/DonutWare/Fladder/blob/ffe16aac73db1fdc41c8badea5c7e70b4c44be58/lib/providers/discovery_provider.dart)
and [Jellyfin's documented UDP 7359 discovery port](https://jellyfin.org/docs/general/installation/container/?method=docker-compose).

Before adding a rule, reproduce the problem while watching the client firewall
log or a packet capture. If the reply reaches the client interface but the app
does not receive it, allow only UDP packets from `<SERVER_LAN_IP>` source port
7359; do not open a fixed destination port because the client chooses a new
temporary port for each probe. The examples below are alternatives—use only the
firewall manager that owns the client ruleset.

On a raw nftables client, inspect the live table and chain names first. The
example assumes `inet filter input`; adapt it and persist the equivalent in the
distribution's ruleset:

```bash
sudo nft list ruleset
sudo nft insert rule inet filter input \
  iifname "<CLIENT_LAN_INTERFACE>" ip saddr <SERVER_LAN_IP> \
  udp sport 7359 counter accept comment "Jellyfin discovery replies"
```

For UFW or firewalld clients, use one of these narrower persistent rules. Check
that the firewalld LAN interface is actually assigned to the `home` zone before
using that example:

```bash
sudo ufw allow in on <CLIENT_LAN_INTERFACE> proto udp \
  from <SERVER_LAN_IP> port 7359 to any comment 'Jellyfin discovery replies'

sudo firewall-cmd --get-active-zones
sudo firewall-cmd --permanent --zone=home \
  --add-rich-rule='rule family="ipv4" source address="<SERVER_LAN_IP>/32" source-port port="7359" protocol="udp" accept'
sudo firewall-cmd --reload
```

The syntax and rule placement are documented by the
[nftables rule guide](https://wiki.nftables.org/wiki-nftables/index.php/Simple_rule_management),
[Ubuntu's UFW guide](https://documentation.ubuntu.com/server/how-to/security/firewalls/),
and [firewalld's rich-rule reference](https://firewalld.org/documentation/man-pages/firewalld.richlanguage.html).

On a Windows client whose LAN is classified **Private**, run Administrator
PowerShell:

```powershell
New-NetFirewallRule -DisplayName "Jellyfin discovery replies" `
  -Direction Inbound -Action Allow -Protocol UDP `
  -RemoteAddress <SERVER_LAN_IP> -RemotePort 7359 -Profile Private
```

`RemoteAddress` and `RemotePort` match the Jellyfin server side of the inbound
packet; see Microsoft's
[`New-NetFirewallRule` reference](https://learn.microsoft.com/en-us/powershell/module/netsecurity/new-netfirewallrule?view=windowsserver2025-ps).

On macOS, open **System Settings → Privacy & Security → Local Network** and
allow Fladder. Then open **Network → Firewall → Options**, ensure **Block all
incoming connections** is off, and allow incoming connections for Fladder if
it is listed. On iPhone or iPad, enable Fladder under **Settings → Privacy &
Security → Local Network**. Apple documents the
[local-network privacy control](https://support.apple.com/en-au/guide/mac-help/mchla4f49138/mac)
and [macOS application firewall options](https://support.apple.com/guide/mac-help/change-firewall-settings-on-mac-mh11783/mac).

If the broadcast remains unavailable because the client is on another VLAN or
an isolated SSID, enter `http://<SERVER_LAN_IP>:8096` manually. Do not set a
global Jellyfin published-server URL merely to work around discovery: that can
cause every client to receive an address inappropriate for its current network.

The bootstrap journal deliberately omits API keys, tokens, client secrets, and
complete provider JSON. A malformed managed branding marker makes
reconciliation fail closed instead of overwriting unrelated administrator
branding.

To roll back, use the guarded deployment helper to select the previous NixOS
generation. The plugin bind mount then disappears. The persistent CSS hides the
manual web form only while the plugin adds the
`nixhomeserver-oidc-ready` root class, so a missing or rolled-back plugin
automatically exposes the normal password login again.

Use the files hostname for browser access. For large transfers, use the
dedicated OpenSSH SFTP endpoint on the configured `filesSftp` port over LAN.

Use the passwords hostname only on LAN or NetBird paths. The canonical operator
workflow for invites, break-glass local admin handling, and the standard
credential-item pattern lives in [Vaultwarden Guide](./vaultwarden.md).

Use the kopia hostname for local Kopia backup management. Browser access is gated by
Kanidm through OAuth2 Proxy and requires membership in the fixed `backup-admin`
group. Repository browsing is a separate permission granted by the fixed
`backup-storage-users` group. Both memberships are managed directly in Kanidm;
add an administrator to both groups when they also need repository browsing.
After OAuth2 succeeds, Kopia still requires its native `kopia-admin` password
from the generated `kopiaServerPassword` secret. The managed repository is a
local encrypted Kopia filesystem repository at `/mnt/data/backups/kopia`.
`backup-prepare.service` first creates integrity-checked SQLite dumps and an
Immich PostgreSQL custom-format dump under
`/persist/appdata/backup-metadata/current`; successful logical dumps are published
as immutable generations and this symlink is replaced atomically;
`kopia-persist-snapshot.timer`
then snapshots `/persist` and `/mnt/data/paperless` daily. On
`single-disk-ext4`, both paths live on the same root filesystem, so an external
or offsite backup remains important.

The MEGA remote and regular Kopia offsite sync are managed declaratively; there
is no persistent Rclone web service:

1. Set `offsiteBackup.enable = true` and set `offsiteBackup.email` in `vars.nix`.
2. From the repository, evaluate and confirm the exact destination:
```bash
mega_destination="$(nix eval --raw \
     ".#lib.nixhomeserverSettings.<vars.hostname>.rcloneMega.destination")"
printf 'MEGA mirror destination: %s\n' "$mega_destination"
```
Never point it at an unverified or shared remote directory: the job is a
mirror and intentionally deletes remote files that are absent locally.
3. Stage the MEGA password locally:
```bash
install -d -m 0700 secrets/unencrypted
install -m 0600 /path/to/mega-password-file secrets/unencrypted/rcloneMegaPassword
nix run .#generate-secrets -- \
--replace-external rcloneMegaPassword \
--identity /path/to/current/age.key
rm -f secrets/unencrypted/rcloneMegaPassword
rmdir secrets/unencrypted 2>/dev/null || true
```
4. Deploy the host. Activation renders `/run/rclone/rclone.conf` from the
agenix secret and keeps the plaintext password out of the Nix store and repo.
5. Confirm the timer is enabled, then start an immediate upload and wait for it:
```bash
sudo systemctl is-enabled rclone-mega-kopia-sync.timer
sudo systemctl start rclone-mega-kopia-sync.service
sudo systemctl status rclone-mega-kopia-sync.service --no-pager
```
6. Do not treat an upload attempt as a backup. The service independently runs
`rclone check` after the mirror completes and publishes
`/var/lib/rclone/last-mega-sync-success.json` only after verification:
```bash
mega_destination="$(nix eval --raw \
     ".#lib.nixhomeserverSettings.<vars.hostname>.rcloneMega.destination")"
sudo jq . /var/lib/rclone/last-mega-sync-success.json
sudo -u rclone rclone lsf --config /run/rclone/rclone.conf \
--max-depth 2 "$mega_destination"
```

The scheduled oneshot job syncs `/mnt/data/backups/kopia` directly to the
configured MEGA destination. No Rclone daemon or web UI remains running between
jobs.
Check status with `systemctl status rclone-mega-kopia-sync.timer`,
`systemctl status rclone-mega-kopia-sync.service`, or
`journalctl -u rclone-mega-kopia-sync.service`.
Test a restore to a temporary directory at least quarterly; see
[Restore and Recovery](./restore-and-recovery.md). Never test a restore directly
over live `/persist` or `/mnt/data`.

Filestash and SFTP file roots:

- Filestash authenticates through OAuth2 Proxy and connects to the local SFTP endpoint as that Unix user with the managed Filestash SFTP key.
- `files-personal-users` is the base browser-workspace grant. Membership in
`usb-access`, `files-shared-users`, or `backup-storage-users` only adds a view to an
existing workspace and does not independently grant Filestash login.
- Filestash opens a single normal-user source, `Files`, rooted at the user's SFTP chroot.
- Direct SFTP opens the same personal root at `sftp://<username>@server.internal:<filesSftp-port>/`, currently port `2222`, and authenticates with the user's SSH key. Grant `files-sftp-users` for direct-only access; browser users receive the same chroot because Filestash itself uses SFTP as its backend.
- Direct SFTP password and keyboard-interactive login are disabled. Eligible
users add a device public key from Homepage's SFTP setup page; the root-owned
files under `/persist/appdata/files-sftp-authorized-keys/<username>` are the
administrator recovery/audit surface, not something users edit directly.
- Port `22` is reserved for normal SSH administration and does not expose an SFTP subsystem.
- Users in `files-shared-users` also see `_Shared` at the top of that root.
- Users in `usb-access` also see `_USB`, backed by `/mnt/external-usb`. USB
  storage auto-mounts on insertion under that root (one folder per drive, named
  from its label/partition-label/UUID), and the `_USB` shared view is gated to
  `usb-access` members. Drives are unmounted and their folders removed when the
  device is detached.
- Users in `backup-storage-users` also see read-only `_Backups`, backed by
`/mnt/data/backups`. This role is independent of `backup-admin`.
- GID `2005` is the fixed on-disk identity of `backup-storage-users`. It is
  intentionally derived outside `vars.nix`; changing it requires a deliberate
  ownership and ACL migration.
- `_Shared` is a delete-protected shared view. Reads, writes, edits, and same-folder renames affect the real shared storage immediately; deletes through `_Shared` should fail. Admin deletes are done directly against the real shared path.

Useful file-access checks:

```bash
kanidm group get files-personal-users
kanidm group get files-sftp-users
kanidm group get files-shared-users
kanidm group get usb-access
kanidm group get backup-admin
kanidm group get backup-storage-users

systemctl status 'files-shared-bindfs@<user>.service'
systemctl status 'files-backups-bindfs@<user>.service'
systemctl status files-usb-shared-view
systemctl status files-usb-shared-link
findmnt /mnt/data || test -d /mnt/data
findmnt /mnt/data/users/<user>/_Shared || mountpoint /mnt/data/users/<user>/_Shared
findmnt /mnt/data/users/<user>/_Backups || mountpoint /mnt/data/users/<user>/_Backups
findmnt /mnt/usb-access-view || mountpoint /mnt/usb-access-view

sudo -u filestash sh -lc 'probe=/mnt/data/users/<user>/_Shared/.write-probe && : >"$probe" && test -f "$probe"'
sudo -u filestash rm /mnt/data/users/<user>/_Shared/.write-probe
sudo rm /mnt/data/shared/.write-probe
```

The `rm` through `_Shared` is expected to fail with permission denied. The final admin delete against the real shared path should remove the probe from every `_Shared` view.

### Automatic DVD ISO conversion

Every personal file root and the shared file root contain an `_ISO` directory.
Only ISOs placed in `_Shared/_ISO/_DVDs` are watched; personal `_ISO` folders
are storage only. An unchanged `.iso` is picked up after approximately one
minute and converted serially into the shared Jellyfin `_Movies` or `_Shows`
library with the balanced H.264/AAC-plus-original-audio profile.

The converter uses the ISO label for its initial media name and performs a
conservative TVmaze lookup for series and episode names. A uniform set of at
least three episode-length titles is treated as TV even when TVmaze has no
listing. If metadata is unavailable or the match is weak, conversion continues
with safe names derived from the ISO and DVD title numbers. Name TV images
descriptively, for example `The_Wire_S03_Disc_2.iso`, to improve automatic
season, disc, and metadata matching.

The final MKV does not retain HandBrake's encode timestamp as a media release
date. Jellyfin can still use a year returned by its metadata providers or a
year supplied in a descriptive ISO name, but an unmatched title remains without
a release year instead of being labelled with the conversion year.

If one title accounts for at least 85% of the substantial runtime, only that
feature is converted. Otherwise every title of at least five minutes is
converted, excluding an obvious play-all duplicate. Completed source ISOs are
preserved in `_Shared/_ISO/_DVDs/_Processed`. After three failed attempts an ISO
is preserved in `_Failed` beside an `.error.txt` file.

While an encode runs, the partially written MKV is staged in
`_Shared/.mkvmaker-staging` outside the Jellyfin library so the library never
scans an incomplete file; the finished MKV is published into
`_Shared/_Videos/_Movies` or `_Shared/_Videos/_Shows` with a single atomic
rename once it passes validation. ISOs added to the inbox during an active
encode are re-read from the inbox for each public progress update and appear in
natural order under the active conversion queue.

Useful checks and controls:

```bash
systemctl status mkvmaker-import.timer mkvmaker-import.service
journalctl -u mkvmaker-import.service
sudo systemctl start mkvmaker-import.service
```

The queue and detailed HandBrake job logs live under `/var/lib/mkvmaker`.
Change `repo.mkvmaker.dominantTitleRatio`, `minimumTitleSeconds`, `audioProfile`,
or `videoPreset` declaratively if the defaults need adjustment.

### Media Manager

Media Manager is an always-present core application at
`https://media.<domain>`. It is private-DNS-only and uses the shared OAuth2
Proxy gateway. Every authenticated `users` member can inspect registered
shared and personal libraries and conversion progress. Only members of
`media-manager-editors` can scan, preview, or confirm changes:

```bash
kanidm group get media-manager-editors
kanidm group add-members media-manager-editors USERNAME
kanidm group remove-members media-manager-editors USERNAME
```

Every authenticated user can request one of the fixed application refresh
adapters from **App refresh**. The page follows each request from queued to
running and then to a durable success or failure result; an in-flight request
for the same application is coalesced. The adapters follow Jellyfin's media
scan scheduled task, Audiobookshelf's library scan tasks and `lastScan`
timestamps, and Syncthing's folder scan response.

Useful refresh checks are:

```bash
systemctl status media-manager-refresh-dispatch.service
systemctl status media-manager-refresh-jellyfin.service
systemctl status media-manager-refresh-audiobookshelf.service
systemctl status media-manager-refresh-kavita.service
systemctl status media-manager-refresh-syncthing.service
journalctl -u 'media-manager-refresh-*' -n 100 --no-pager
```

The library organizer constructs destinations from typed movie, TV, music,
audiobook, and book fields. It does not accept arbitrary paths. Every change
shows the exact source and destination, expires after 30 minutes, verifies the
original fingerprint, and is applied by a network-isolated broker with
no-overwrite semantics. Movie and TV years remain absent when unknown; the
current/conversion year is never substituted.

Metadata is initially written as Jellyfin NFO or book/audiobook OPF sidecars;
media streams are not rewritten. Subtitle uploads accept UTF-8 SRT, WebVTT,
and ASS files. OpenSubtitles search is optional. It calculates the provider's
movie hash locally and asks for an exact file match before falling back to a
title search; the media file itself is not uploaded. To enable it, create an
OpenSubtitles.com account, then create an application API key under "My
consumers" at https://www.opensubtitles.com/consumers (select the
"OpenSubtitles REST API" API). Prepare a mode-0600 JSON file such as:

```json
{
  "apiKey": "application key",
  "username": "account username",
  "password": "account password",
  "userAgent": "NixHomeServer Media Manager"
}
```

Then stage and encrypt it without committing plaintext:

```bash
install -d -m 0700 secrets/unencrypted
install -m 0600 /path/to/credentials.json secrets/unencrypted/openSubtitlesCredentials
nix run .#generate-secrets -- \
  --replace-external openSubtitlesCredentials \
  --identity /path/to/current/age.key
rm -f secrets/unencrypted/openSubtitlesCredentials
rmdir secrets/unencrypted 2>/dev/null || true
git add secrets/openSubtitlesCredentials.age
```

MusicBrainz Picard-style metadata lookup is available in the **Metadata**
editor for cataloged music files. Search mode queries MusicBrainz directly from
an artist and title and works without any configuration. Fingerprint mode
fingerprints the local audio with `fpcalc` (bundled via the `chromaprint`
package) and resolves it through AcoustID; it needs an AcoustID API key. Auto
mode fingerprints first and falls back to search. Enabling the key makes
fingerprint mode available, otherwise the editor shows the key's absence and
falls back to search. To enable it, register an application API key at
https://acoustid.org/settings, then stage and encrypt it without committing
plaintext (the key lives in a JSON object named `acoustidApiKey`):

```bash
install -d -m 0700 secrets/unencrypted
printf '%s\n' '{"acoustidApiKey":"YOUR_KEY"}' > secrets/unencrypted/acoustidApiKey
nix run .#generate-secrets -- \
  --replace-external acoustidApiKey \
  --identity /path/to/current/age.key
rm -f secrets/unencrypted/acoustidApiKey
rmdir secrets/unencrypted 2>/dev/null || true
git add secrets/acoustidApiKey.age
```

Manual refresh adapters are registered only for installed applications.
Jellyfin, Audiobookshelf, Kavita, and Syncthing have explicit adapters. The
Kavita adapter runs as the unprivileged `kavita` account and mints a five-minute
HS512 service token from Kavita's existing application token key. It sends that
token only to the loopback scan API and follows each registered library's
persisted scan timestamp to completion. This is necessary because OIDC admin
roles are not attached to Kavita auth keys. Kavita does not expose a public
scan-job status endpoint, so the adapter treats those timestamp advances as the
authoritative completion boundary and fails immediately if a library present at
the start disappears. Application-owned watchers and timers continue to run
independently.

Opening a shared or personal library root performs its first catalog scan
automatically, including for viewers. Media Manager records that the root was
scanned even when it was empty, so subsequent reads use SQLite immediately.
Concurrent first reads of the same root share one serialized scan. The
**Conversions** page lists the shared DVD ISO inbox itself: waiting ISOs with
their disc volume labels, sizes, and timestamps beside the `_Processed` and
`_Failed` results, next to the converter's setup steps and live status. The
**Subtitles** page shows the same kind of setup guidance and status for the
optional OpenSubtitles search provider, so neither appears under **App
refresh**. Selecting a file or folder in **Libraries** or an item in
**Metadata** shows title-specific and conventional artwork such as `cover.jpg`,
`poster.jpg`, and Jellyfin-style suffixed images. The lookup checks the item's
directory and nearby parent folders before falling back to embedded artwork in
supported audio and MP4 containers. Folder names select their own metadata;
only the adjacent caret expands or collapses the tree. Selecting a cataloged
image presents a cover-art replacement action instead of a media metadata form.
Confirmation archives the original under a `superseded` child directory and
installs the fully decoded replacement through one recoverable, no-overwrite
broker operation.

```bash
systemctl status media-manager.service media-manager-broker.timer
journalctl -u media-manager.service -u media-manager-broker.service
systemctl status media-manager-refresh-dispatch.service
```

Kavita-managed book roots are aligned to the same simpler taxonomy used by
the rest of the stack: `_Ebooks`, `_Comics`, and `_Manga`. The old `other`
category is no longer part of the managed layout.

Current installs are expected to already use the underscore-prefixed content
layout. The repo no longer carries automatic migration helpers for old paths
such as `videos`, `books`, or `audiobooks`; restore or migration work from an
older layout should be handled deliberately before deploy.

Do not guess share hostnames manually; use the evaluated share hostname from
`nix run .#show-config-summary` or `vars.nix`.

Immich sharing flow:

1. Open Immich at the private photos hostname.
2. Create an album or photo share link
3. Send the generated public share URL to recipients.

## Mail Archive Operations

The mail archive UI stays private. `mail-archive-users` grants browser access to
the UI only. The archived sync payload stays in each user's hidden
`.internal-sync` tree, while the user-visible mailbox mirror is exposed as
hard-linked `.eml` files under that user's `_Emails/` root.

Normal checks and manual actions:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz | jq .
```

Use the dashboard `Sync now` and `Reindex` actions when you need to repair or
refresh one mailbox without waiting for the timer. Use the mail archive
`/search` and `/attachments` routes with structured GET parameters such as
`sender_address`, `sender_name`, `sender_domain`, `subject`, `body_text`,
`date_from`, `date_to`, and `has_attachments`. Attachment search also accepts
`attachment_name`, `extension`, `mime_type`, `min_size`, `max_size`,
`min_attachments`, and `max_attachments`, so future tooling can scrape stable
URLs without browser automation.

Attachment downloads are backed by content-addressed blobs in each mailbox's
hidden `.internal-sync` tree. ZIP downloads include a `manifest.json` that maps
each file back to its mailbox, message, MIME type, size, and SHA-256. Inline
artifacts and `ripmime` body fragments such as `textfile0` are hidden by default
in the UI and can be included with the body-parts filter. ZIP contents are laid
out as `<mailbox>/<yyyy-mm-dd> - <subject>/<filename>`, and duplicate filenames
are suffixed as `file (1).ext`.

Attachment rows can be selected with normal click, Ctrl/Cmd-click, and
Shift-click conventions. Selected attachments can be downloaded locally as a ZIP
or copied into the configured Paperless consume inbox. The Paperless handoff is
recorded per user and attachment after the consume-file rename succeeds;
Paperless ownership and post-processing follow the normal Paperless consumer
behavior.

Saved attachment-filter presets can also be enabled as automatic Paperless
exports. Each task can run daily at a local time or at a repeating interval,
limit the number of new documents handled per run, and enable or disable
automatic retries. The scheduler polls every configured
`services.mail-archive-ui.paperlessTaskPollInterval` (five minutes by default).
Failed and partially successful runs use capped exponential retry delays; files
already published during a partial run are skipped safely on retry. An expiring
task lease prevents concurrent scheduler processes from running the same task.

Routine status and a manual scheduler run are available with:

```bash
systemctl status mail-archive-paperless-tasks.timer mail-archive-paperless-tasks.service
sudo systemctl start mail-archive-paperless-tasks.service
journalctl -u mail-archive-paperless-tasks.service --since today
```

Task configuration, counters, retry state, and the per-run
`attachment_paperless_task_runs` history are stored in the backed-up Mail
Archive SQLite database. Handoffs are staged and synced before an atomic publish
to the consume folder. A batch scans pending consume files once and reuses the
application and Paperless database connections, so large batches do not repeat
the same directory and connection work for every attachment.

To verify attachment backup readiness manually:

```bash
sudo -u mail-archive-ui env \
MAIL_ARCHIVE_UI_DATA_DIR=/persist/appdata/mail-archive-ui \
MAIL_ARCHIVE_UI_STORE_ROOT=/mnt/data/users \
MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT=/persist/appdata/mail-archive-ui/accounts \
MAIL_ARCHIVE_UI_RUNTIME_DIR=/run/mail-archive-ui \
MAIL_ARCHIVE_UI_LOCK_DIR=/persist/appdata/mail-archive-ui/locks \
TMPDIR=/run/mail-archive-ui \
SQLITE_TMPDIR=/run/mail-archive-ui \
mail-archive-ui verify-attachments --repair --report /tmp/mail-archive-attachments.json
```

This repair command is intentionally manual and is not run by routine backup
preparation. Mail payload bytes remain on the mirrored
`/mnt/data/users` pool unless an operator intentionally adds those paths to a
Kopia policy.

## Validation Gate

The documented day-2 validation path runs resource-intensive checks on the
remote server. The local wrapper still needs `nix` for its lightweight flake and
target validation:

```bash
./scripts/deploy.sh --debug --action test
```

That stages the current repo archive on the server and runs the full repository
gate there. A fresh remote validation stamp is reused by guarded deploys to
skip repeated repo checks for unchanged archive content.

Optional local validation remains available when you intentionally want to check
the repository before staging it on the server:

Run the flake check first.

```bash
nix flake check --no-build
```

Run the repo gate second.

```bash
scripts/validate-repo.sh
```

Default local `scripts/validate-repo.sh` behavior:
- runs the lean script suite through `scripts/tests/run-script-tests.sh`
- scopes optional-app tests to `applications.enabled`
- does not rerun `nix flake check --no-build`
- does not run Rust derivation checks

To include flake checks in the same pass:

```bash
scripts/validate-repo.sh --run-flake-check
```

For the full local gate:

```bash
scripts/validate-repo.sh --full
```

To run the repository-wide optional-module matrix and build every custom app:

```bash
scripts/validate-repo.sh --full --all-apps
```

Full mode runs:
- `nix flake check --no-build` unless `--skip-flake-check` is used
- the host-scoped flake derivations in one aggregate `nix build`, followed by
  script tests
- Homepage end-to-end checks when Homepage is selected

After every gate passes, the host-scoped output set replaces the indirect roots
under
`${XDG_STATE_HOME:-$HOME/.local/state}/nixhomeserver/validation-roots/current`.
Pending roots are removed on failure, leaving the previous passing set warm.
The exhaustive `--all-apps` form deliberately does not update these roots.
Repeat `scripts/validate-repo.sh --full` to reproduce a warm-cache measurement;
Nix should report that no derivations need building or fetching while those
roots exist.

Adding `--all-apps` swaps in the repository-wide derivation and script-test
worklists. CI uses that exhaustive form.

To reproduce custom-app timing measurements, use three equivalent source edits
per scenario, capture GNU `time` wall, CPU, and peak-RSS fields around the
single aggregate `nix build` (for example with
`nix shell nixpkgs#time -c time -v nix build ...`), and record
`nix path-info -Sh` plus
`nix path-info --json` for closure and NAR sizes. Keep generated benchmark data
outside the checkout. For build allocation comparisons, repeat the same edit
set with each one-shot `--build-mode` value and compare scenario medians; do not
activate a result while benchmarking.

Kanidm checks use the native `kanidm` CLI. They do not rely on the old custom
helper package that was also named `kanidm-admin`; that package name is separate
from the configured `identity.adminUser` account name.

## Guarded Deploy

```bash
./scripts/deploy.sh --action test
```

That path resolves the target from `vars.localAdminUser` and `vars.serverLanIP`,
refuses untracked files that have not been reviewed, and stages the current repo
archive on that host. By default, all Nix evaluation, builds, activation, and
validation happen on the server, so the server also carries the resulting
`/nix/store` churn.

Run deploys from a real Git checkout. A copied directory or source ZIP is
rejected because it has no trustworthy tracked-file manifest; broadly archiving
such a tree could otherwise include ignored plaintext secrets, dependency
caches, or other host-local files in the build host's Nix store.

The test action checks free space on both the build host and target, builds and
copies the closure without activating it, then activates that exact closure
through the guarded target-side test unit without changing the boot default. It
then checks failed systemd units, public routes, and the authenticated Homepage
canary when that module is enabled. Only after every gate passes does it record
a root-only stamp containing the exact repository hash and NixOS closure. That
closure is also kept alive with a dedicated GC root.

Only switch after the guarded test path passes.

```bash
./scripts/deploy.sh --action switch
```

The switch action does not rebuild a possibly different result. It refuses to
continue if any archived repository content changed after the passing test,
reactivates the exact stamped closure, repeats the health gates, and only then
makes that closure the boot default. If you edit, stage, or remove a file after
`--action test`, run the test action again before switching.

Deploys are serialized with a per-host lock. A failed transaction restores both
the previous live generation and previous boot profile immediately. `SIGHUP`,
`SIGINT`, and `SIGTERM` trigger that same immediate recovery before the deploy
process exits. Building and copying happen before the rollback timer is armed
and do not mutate the live generation. The later activation atomically verifies
the transaction owner and recovery barriers as it starts; recovery stops that
unique target-side unit and refuses to mutate generations unless it can prove
the activation is no longer running. A target-side timer remains armed during
activation as a backstop for an abruptly killed process or lost SSH session,
and is cancelled only after the transaction completes. If an immediate rollback
itself fails, leave the timer and lock in place and inspect them instead of
starting a competing deploy:

```bash
sudo systemctl list-timers 'nixhomeserver-deploy-*'
sudo systemctl status 'nixhomeserver-deploy-rollback-*'
```

A completed target-side rollback retains a `recovery-complete` barrier under
`/run/lock/nixhomeserver-deploy-<host>/` so a stalled executor cannot resume and
commit stale work. If that executor resumes, it repeats recovery, cancels the
finished timer, and removes the barrier before exiting; otherwise the ordinary
stale-lock expiry removes a successful barrier. A failed delayed rollback writes
`recovery-failed` instead, and stale-lock expiry deliberately refuses to remove
it. Inspect the rollback service and restore a known-good live and boot
generation before manually clearing that failed-recovery lock.

For the slower full validation gate:

```bash
./scripts/deploy.sh --action test --debug
```

`--debug` keeps the transactional deploy ordering but adds the full repository
validation gate before rebuilding. Use it for broad changes or suspicious
failures; routine deploys can use the focused fast path.

The regular deploy path stays intentionally focused. It evaluates the target,
checks build and target capacity, uses the build allocation selected in
`vars.nix`, and runs the runtime health gates described above.

## Build Allocation

Set `system.buildMode` in `vars.nix` to choose where guarded test deployments
build:

| Value | Workstation slots | Server slots | Cores requested per job |
| --- | ---: | ---: | ---: |
| `"local"` | all available (`auto`) | 0 | all available (`0`) |
| `"remote"` | 0 | all available (`auto`) | all available (`0`) |
| `"balanced"` | 2 | 2 | 1 |
| `"maximum-effort"` | all available (`auto`) | all available | all available (`0`) |

The deployed server limit is written through the native
`nix.settings.max-jobs` NixOS option. In `local` mode the server daemon remains
build-capable so a later mode change cannot deadlock, but the deploy omits it
from the builders list and therefore sends it no build work. For `balanced` and
`maximum-effort`, the workstation coordinates a native Nix distributed build
and registers the target server as an `ssh-ng` builder. The server's processor
count and advertised Nix system features are detected over the same SSH
connection used by the guarded deploy.

Because the workstation's multi-user Nix daemon opens the builder connection as
root, combined modes require a passphrase-free private key file in the
workstation user's effective SSH `IdentityFile` list. Its public key must match
`identity.sshPublicKey` in `vars.nix`. The deploy helper passes that exact
identity path to Nix and pins the server's Ed25519 host key after retrieving it
through the already-authenticated operator SSH connection. Agent-only or
passphrase-protected identities cannot be used by the daemon; the helper fails
before building with an actionable diagnostic instead of silently falling back
to one host.

`balanced` sets Nix's advisory `cores = 1` hint as well as limiting each host to
two simultaneous jobs. Nixpkgs builders that honor `NIX_BUILD_CORES` therefore
stay near two busy cores per host; derivations that ignore the hint may still
use more CPU.

Preview a configured allocation without building:

```bash
DEPLOY_DRY_RUN=1 ./scripts/deploy.sh --action test
```

Use `--build-mode <value>` for a one-shot override. The older
`--build-locally` flag remains an alias for `--build-mode local`.

## Fast Remote Deploy

With `system.buildMode = "remote"`, run:

```bash
./scripts/deploy.sh
```

This resolves the SSH target from `vars.localAdminUser` and `vars.serverLanIP`,
stages the current repo archive, runs the build/copy-only `nixos-rebuild build`,
and activates the returned closure through the guarded target-side test unit. It
intentionally skips the full repository and flake-check suite, but it still
evaluates the host, checks capacity, verifies failed units and public routes,
runs the authenticated canary when enabled, and records the exact passing
source/closure pair.

Use `--action switch` only after the test path passes without subsequent repo
changes and you want to commit that exact tested closure as the boot default:

```bash
./scripts/deploy.sh --action switch
```

Use `--build-locally` when you intentionally want a one-shot workstation-only
build and then activate the evaluated target over SSH:

```bash
./scripts/deploy.sh --build-locally --action test
```

## Attic Build Cache

Attic is fixed platform behavior whenever its application module is present and
listens only on
`127.0.0.1:8080`. It is not opened in the firewall or published through Caddy.
The server's Nix daemon uses the public `nixhomeserver` cache at that loopback
endpoint, while a root-only Attic client token permits a bounded Nix post-build
hook to upload newly built outputs. Attic's default upstream filter avoids
duplicating paths already signed by `cache.nixos.org`.

The Nix daemon also always uses the official `cache.nixos.org` cache and the
community `nix-community.cachix.org` cache. These are platform defaults rather
than `vars.nix` settings.

On first activation, `attic-cache-bootstrap.service` creates or reconciles the
cache, sets a six-month retention period, learns the cache signing public key,
and restarts the Nix daemon only when that key changes. The client token lives
under `/run`; Attic's database and cache live under `/var/lib/atticd`.
Impermanence retains that directory across root rollback and module removal,
but Kopia deliberately excludes it because all cached content is reproducible.

Check the service chain and cache:

```bash
systemctl status atticd.service attic-cache-bootstrap.service
sudo env XDG_CONFIG_HOME=/run/attic-client attic cache info nixhomeserver
curl --fail http://127.0.0.1:8080/nixhomeserver/nix-cache-info
journalctl -u atticd.service -n 100 --no-pager
sudo du -sh /var/lib/atticd/storage
```

The server Nix daemon uses a serialized `attic push --no-closure --jobs 1`
post-build hook with a five-minute timeout. Failures are logged without failing
the completed Nix build. This avoids the known unbounded memory growth of a
long-lived `attic watch-store` process. `atticd` uses conservative glibc
allocator thresholds and systemd memory/swap limits so upload buffers are
returned promptly and a cache fault cannot exhaust the host.

The administrator's Void desktop is also configured with an XDG-autostarted,
user-level SSH tunnel from local port 8080 to the server's loopback port, the
cache public key in `~/.config/nix/nix.conf`, and a Nix post-build hook that
runs a serialized `attic push --no-closure --jobs 1`. Consequently, local build
outputs are uploaded without exposing Attic on the LAN or keeping a
memory-intensive desktop store watcher resident. Upload failures are logged but
do not fail an otherwise successful build. The desktop token is a
pull/push-only token stored with mode `0600`; it cannot create or reconfigure
caches. If the tunnel is unavailable, Nix falls back to the official and
community caches.

Desktop-side checks:

```bash
curl --fail http://127.0.0.1:8080/nixhomeserver/nix-cache-info
attic cache info nixhomeserver
pgrep -af 'nixhomeserver-attic-tunnel'
nix config show | grep -E '^(substituters|trusted-public-keys|post-build-hook) ='
```

For server-side secrets generation after local staging or edits:

```bash
ssh <admin>@<hostname> \
'cd /path/to/repo && nix run .#generate-secrets -- --identity /persist/etc/agenix/age.key'
```

## Service Validation

```bash
sudo systemctl --failed --no-pager
./scripts/deploy.sh --debug --action test
```


Private-host troubleshooting note:
- if the passwords hostname does not resolve from a workstation browser, do not assume Vaultwarden is down
- verify the private edge directly with:

```bash
curl -kI --resolve <passwords-domain>:443:<server-lan-ip> https://<passwords-domain>/
```

- if the forced-resolution check succeeds while normal resolution fails, troubleshoot workstation DNS, LAN resolver reachability, or NetBird instead of changing Vaultwarden exposure

Storage monitoring now discovers disks live at runtime from an evaluated JSON
inventory embedded in the system generation; smartd startup does not evaluate
Nix or read the repository checkout:
- `system` is the static `vars.mainDisk`
- `dataN` are the current live `data` pool members discovered from ZFS
- `otherN` are every other attached non-system disk, including retired disks that are still physically attached

## Backup Media

Kopia uses a managed encrypted filesystem repository at
`/mnt/data/backups/kopia`. The `kopia-persist-snapshot.timer` creates daily
snapshots of `/persist` and `/mnt/data/paperless` after consistent logical
database preparation.

Rclone is a scheduled, short-lived synchronizer for offsite copies of that
encrypted repository. The MEGA remote is rendered from `vars.rcloneMega` and the
`rcloneMegaPassword` agenix secret at activation time. Full Kopia maintenance
runs daily between 01:00 and 02:00, and `rclone-mega-kopia-sync.timer` checks
and repairs the encrypted MEGA mirror at approximately 04:30 and 16:30.

Deleting individual repository objects or the entire dedicated destination on
MEGA is repaired from the authoritative local repository on the next sync. A
non-empty destination whose ownership marker was deleted is adopted only when
its immutable Kopia repository identity still matches; ambiguous or mismatched
remote content fails closed. Before any destructive sync, a read-only rclone
plan measures missing/changed uploads and destination-only packs, then checks
that both the final projected account usage and the temporary replacement space
fit the live MEGA quota below the 19 GiB safety ceiling.

Each mirror attempt atomically updates
`/var/lib/rclone/last-mega-sync-status.json` and emits the same structured event
under the `backup-offsite` journal identifier. The state distinguishes normal
completion from a capacity block, a retryable transport problem, an unsafe
remote identity, and a broken local repository prerequisite:

- Exit 75 is transient. Systemd retries after 30 minutes, up to six attempts in
  six hours, without sending an alert for every intermediate attempt.
- Exit 76 is a capacity block. It is recorded as `blocked`, does not retry, and
  does not trigger the generic service-failure alert; the capacity checker owns
  its rate-limited warning path.
- Exit 77 is a safety or identity mismatch. It stops immediately and alerts.
- Exit 78 is a non-retryable repository or remote failure. It stops immediately
  and alerts.
- Exit 64 means a managed helper, its arguments, or structured status
  persistence failed. It stops immediately and alerts rather than reporting an
  unobservable success.

The Kopia UI is restarted after every attempt, including retryable and blocked
ones, so the retry delay does not leave local backup administration offline.
Inspect the latest decision and its stable reason code with:

```bash
sudo jq . /var/lib/rclone/last-mega-sync-status.json
sudo journalctl -t backup-offsite -n 50 --output=cat --no-pager
sudo systemctl status rclone-mega-kopia-sync.service --no-pager
```

MEGA does not expose modification times or server-side hashes to rclone, so
equal-sized files cannot be distinguished by the normal sync comparison. Kopia
uses unique immutable names for bulk packs and indexes; the small fixed-name
repository control objects are therefore force-copied on every run and then
byte-compared by downloading only that control set. This avoids a full
multi-gigabyte verification download while still refreshing mutable maintenance
state.

Kopia's safe full maintenance may need multiple cycles before unreachable packs
are physically deleted. Do not automate `--safety=none`; it disables Kopia's
concurrency and storage-consistency safeguards. See
[Kopia maintenance safety](https://kopia.io/docs/advanced/maintenance/#maintenance-safety).

The Kopia policy is deliberately bounded to 7 latest, 14 daily, 4 weekly, and
2 monthly snapshots (with no hourly or annual tier). Runtime caches, application
logs, retired Restic/pool-migration copies, and reproducible download/cache data
under `/persist` are excluded from the offsite snapshot. In particular, only
`/persist/var/lib/bonsai/models` and `/persist/var/lib/atticd/storage` are
excluded for Bonsai and Attic; their databases, metadata, configuration, and key
material remain backed up. The managed `/persist` policy is cleared and rebuilt
by an active-exited reconciliation unit on activation. Because NixOS restarts
that unit when its generated policy changes, enabling, disabling, removing, or
re-adding a module cannot leave a stale exclusion behind.

MEGA synchronization uses permanent, delete-before semantics for this dedicated
Kopia mirror. This is important because the MEGA backend otherwise puts deleted
packs in its rubbish bin, where they continue consuming quota. A six-hourly
capacity check evaluates live MEGA usage against MEGA's reported account total
and the local repository against its 19 GiB ceiling. It journals a warning at
80%, marks the state critical at 90%, and marks local usage at or above 19 GiB
as blocked. It also carries forward a projected/transient-space block from the
latest mirror preflight, even when the raw percentages have not yet crossed a
threshold.
Critical, blocked, and quota-query failures trigger the external failure path at
most once per 24 hours while the condition persists; returning below the
critical threshold rearms the alert immediately. Every check still writes its
current state to `/var/lib/rclone/last-mega-capacity.json`, including whether an
external alert was required or suppressed. Inspect it with:

```bash
sudo systemctl status rclone-mega-capacity-check.service --no-pager
sudo journalctl -t backup-capacity -n 50 --no-pager
sudo jq . /var/lib/rclone/last-mega-capacity.json
```

`--mega-hard-delete` only affects future deletions made by this sync. Emptying
the account's existing MEGA rubbish bin is a separate, account-wide destructive
operation and must be performed explicitly after checking that it contains
nothing that should be recovered.

External USB storage is no longer a managed backup target. If an operator wants
to copy backups to a removable SSD, plug it in (it auto-mounts under
`/mnt/external-usb`) and copy or sync the encrypted repository files from
`/mnt/data/backups`.

The previous automatic Restic `system-state` behavior is retired and no Restic
timer or backup service is enabled by this module.

Run safe repository maintenance and then propagate reclaimed packs to MEGA:

```bash
sudo systemctl start kopia-full-maintenance.service
sudo systemctl start rclone-mega-kopia-sync.service
sudo journalctl -u kopia-full-maintenance.service -u rclone-mega-kopia-sync.service -n 200 --no-pager
```

Kopia deletion safety is not overridden. UI-deleted snapshots may remain until
a later full-maintenance cycle. Routine journal retention is 14 days/256 MiB;
Kopia file logs are removed after 14 days. Caddy keeps five 25 MiB rolled access
logs for at most 30 days.

## Local ZFS Snapshots

The ZFS profile retains 24 hourly, 7 daily, and 4 weekly snapshots. The backup
and upload-staging datasets are excluded. Inspect usage with:

```bash
sudo zfs list -t snapshot -o name,creation,used -s creation -r data
sudo systemctl status zfs-snapshot-health.service --no-pager
```

`orphan-state-report.service` reports preserved legacy paths and datasets under
`/persist/appdata/backup-metadata/metadata/orphan-state.json`; it never deletes
them.

## Shared Authentication Logout

Proxy-protected applications use the shared `auth.<domain>` gateway and one
domain cookie. Signing out there signs out every gateway-protected application.
Native OIDC applications keep independent sessions because Kanidm does not
advertise an end-session, front-channel logout, or back-channel logout endpoint.

## SMART Monitoring

The retained storage monitoring workflow is:
- `systemctl --failed`
- `scripts/helpers/storage-health-common.sh`
- `scripts/discover-storage-devices.sh`
- `scripts/generate-smartd-config.sh`
- `scripts/run-storage-smart-sweep.sh`

The scheduled SMART jobs are now discovery sweeps:
- `storage-smart-short.timer`
- `storage-smart-long.timer`

Attached retired disks will keep appearing in SMART checks until they are
physically detached from the server.

Use these checks first on the target host:

```bash
sudo systemctl --failed --no-pager
systemctl status storage-smart-short.timer
systemctl status storage-smart-long.timer
```

To inspect scheduled SMART self-test activity:

```bash
journalctl -u storage-smart-short -n 100 --no-pager
journalctl -u storage-smart-long -n 100 --no-pager
```
