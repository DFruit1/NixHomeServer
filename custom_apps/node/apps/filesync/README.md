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
**Browse server files** opens a read-only browser over the same libraries.
Folders navigate in place. Hold a file or folder to start selecting, then tap
other rows to add them; checkboxes also support mouse and keyboard selection.
The selection bar offers **Share**, **Download**, and **Clear**. Single files
also keep their row actions. Navigation clears the selection.
**Download** asks for a destination folder once, then saves individual files,
preserving subfolders and using numbered copies for existing names. It never
replaces existing files. **Share** opens the Android share sheet with one file,
or a standard DEFLATE ZIP for multiple files or folders. Android's built-in ZIP
writer handles compression alongside the native share sheet, avoiding another
archive dependency. Files stream through private app cache; transfers are bounded
by available cache space. Failed downloads report how many files were saved.
The browser never writes to the server. Linux supports downloads into a chosen
folder; native sharing is Android-only. Shared payloads expire from private cache
after one hour, with abandoned copies swept after one day.
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

Run `pnpm build:android` (or `pnpm release:android`) from this app directory
for each distributable rebuild. The command selects an Android version code
above the live F-Droid version, so the display version can remain unchanged
during development. It builds and tests the ARM64 APK, signs it with the existing
Android debug keystore, checks the app identity, version code, and signing
certificate against the live F-Droid index, then uploads it to the server's
watched File Sync path. It waits until both the F-Droid index and IPFS mirror
serve the new APK. Use `pnpm build:android --build-only` to create a local
APK without publishing it. The same signing key is required for in-place
updates; back it up before releasing from another workstation.

Add the existing F-Droid repository URL
(`https://fdroid.<your-domain>/fdroid/repo`) to the F-Droid client. The IPFS
mirror serves the same signed index and APK content.

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

Release minification is disabled while Android startup is being verified on a
device. The release command checks the APK automatically. For a manual release
build, check that the APK contains the native commands that Tauri calls by name:

```sh
cargo tauri android build --apk --target aarch64 --ci
pnpm test:android-release
```

The Android release check reads the APK. Saved-pair startup tests run with
`pnpm test`. A connected Android device is still needed
to verify launch, Kanidm sign-in, SAF folder access, and an actual transfer.

For a repeatable startup check on an x86_64 server with `/dev/kvm`, run the
published ARM64 APK in the headless Android 11 Google APIs emulator:

```sh
nix develop .#filesync-android-emulator --command \
  scripts/android/test-filesync-apk.sh /path/to/filesync.apk /var/tmp/filesync-test-results
```

The runner installs and launches the APK, checks that its process stays alive,
and saves a screenshot and crash log in the result directory. It stops the
emulator afterward. The Android 11 Google APIs x86_64 image translates ARM64
app code; this smoke test still cannot verify phone-specific SAF providers or
background scheduling.

The user-facing sync service is an optional NixOS module named `filesync`. It
provides the authenticated API at `https://filesync-api.<domain>` and registers
the public Kanidm client `filesync-native`. The Android release default is
derived from the declarative NixOS domain in `vars.domain`; users can change the
address in Settings when connecting to another server. Sign-in opens in the
system browser and returns to the app through the `filesync://` callback.
The app saves the session after verifying Kanidm's identity token and uses its
`preferred_username` claim to complete sign-in. Loading folders from the private
sync API happens afterward, so an API connection failure keeps the sign-in and
saved folders available. Syncing still requires working LAN or NetBird access.
