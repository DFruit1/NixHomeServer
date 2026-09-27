# File Sync prototype

File Sync uses Kanidm OpenID Connect with authorization code + PKCE. The app
stores the refresh token in Android Keystore-backed encrypted preferences on
Android and the desktop keyring on Linux. It sends bearer access tokens to the
per-user HTTPS API; this app does not use SFTP or SFTP keys.

The current prototype supports one-way copies between an Android SAF tree or
Linux folder and the signed-in user's enabled server libraries. Android runs
saved pairs in the background with WorkManager; Linux sync remains manual. After
Kanidm sign-in, the server supplies only presets for enabled services whose
personal folder exists for that account. Service cards lead to preset choices;
**Enable and sync** opens the native folder picker, saves a pair, and starts its
first copy. If the copy fails, the pair stays available for a manual retry. The personal music
preset copies `_Music` into `_My Music` within the chosen local folder. Manual
pairs can browse the same server libraries and choose a different folder or
direction.
Offline Media also offers its configured personal video folders when present.
Choose the direction when creating a pair, then use **Sync now**. It copies
files in that direction, creates missing parent folders, replaces same-name
destination files, and never propagates deletions. SHA-256 comparison avoids
transferring unchanged files, at the cost of reading the selected files during
each scan. Android also checks saved pairs with WorkManager about every 15
minutes on unmetered networks. Android may defer checks; active transfers show
a system notification and use the selected SAF tree grant. Two-way conflict
handling is not implemented. Android transfers stage
one file at a time in private app cache before/after streaming it, and require
the selected SAF provider to support safe rename when replacing an existing
file. Folder selection is recorded in native secure storage; removing the pair
forgets that authorization and releases Android's persisted URI grant.
Pairs are tied to the Kanidm username that created them; switching accounts
requires separate pairs. Older unbound prototype pairs must be recreated. The
24-hour settings authorization is separate from the saved sync session. Background
sync continues while Kanidm accepts the refresh token, but Kanidm's token/session
expiry and revocation still apply; this does not create a permanent credential.

The server API runs as a dedicated unprivileged account. While it is running,
systemd grants that account ACL access to the enabled personal library trees; the
service removes those temporary ACL entries when it stops. It validates
Kanidm bearer-token signature, issuer, audience, expiry, and username before
opening a capability-rooted per-user directory. The server chooses the allowed
root from its own preset configuration; clients cannot supply an absolute path.

## Publishing the Android prototype

When the `filesync`, `fdroid`, and `ipfs` modules are enabled, the server watches
`/var/lib/fdroidserver/incoming/filesync.apk`. Copy a signed APK there to add or
replace File Sync in the private F-Droid repository. The watcher runs
`fdroid-publish` and the F-Droid reindex success hook pins the updated repository
to IPFS. Add the existing F-Droid repository URL (`https://fdroid.<your-domain>/fdroid/repo`)
to the F-Droid client; the repository's configured IPFS mirror serves the
immutable index and APK content. The initial prototype APK is debug-signed, so
future updates must use the same signing certificate for Android to accept them
as in-place upgrades.

## Development

From the repository root:

```sh
nix develop .#filesync-tauri
cd custom_apps/node/apps/filesync
pnpm install
cargo tauri android init
pnpm run dev:tauri
```

For Android, connect a device with USB debugging enabled and run:

```sh
cargo tauri android dev --open
```

The user-facing sync service is an optional NixOS module named `filesync`. It
provides the authenticated API at `https://filesync-api.<domain>` and registers
the public Kanidm client `filesync-native`. The app uses the API address shown
in the connection field; it must be an HTTPS origin.
