# File Sync prototype

File Sync uses Kanidm OpenID Connect with authorization code + PKCE to sign
in, then exchanges the Kanidm access token for a permanent per-device sync key
issued by the per-user HTTPS API. The app stores that key in Android
Keystore-backed encrypted preferences on Android and the desktop keyring on
Linux, and sends it as the bearer token for syncing, manual resyncs and
browsing. The Kanidm session is revoked as soon as the key is issued. This app
does not use SFTP or SFTP keys.

Kanidm cannot keep a native client signed in indefinitely: every OAuth2 refresh
session belongs to the browser login that created it and ends with the account
policy's auth-session expiry. The device key removes that limit for syncing.
Changing sync settings (adding or enabling folders, the server address) still
needs a fresh Kanidm sign-in, which unlocks settings on that device for 24 hours
and keeps the existing device key when the account matches. Removing a folder
does not need a sign-in.

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
files in that direction, creates missing parent folders, and replaces same-name
destination files. File Sync compares metadata and uses SHA-256 where needed
to avoid transferring unchanged files. Android checks saved pairs on unmetered
networks, with the delay growing from 15 minutes to two hours while idle.
Android may defer checks based on battery, storage, and network conditions.
Active transfers show a system notification and use the selected SAF tree
grant. Android stages uploads in private app cache and streams sync downloads
to a temporary file in the destination folder. The SAF provider must support
safe rename to replace an existing file. Folder selection is recorded in
native secure storage. Removing the pair forgets that authorization and
releases Android's persisted URI grant.

Deletions never propagate in either direction by design. A file deleted on the
server stays on the phone, and a file deleted on the phone stays on the server.

Pairs are tied to the Kanidm username that created them; switching accounts
requires separate pairs. Older unbound prototype pairs must be recreated.
Installs signed in before device keys existed upgrade their Kanidm session to a
device key the next time the app opens with the sync API reachable.

Device keys never expire. **Sign out** revokes the device's key on the server.
The server stores only SHA-256 digests of keys in
`/var/lib/filesync-api/devices.json` (kept 16 per account, oldest dropped).
Disabling a Kanidm account does not revoke its device keys: to revoke a lost
device, stop `filesync-api`, remove its entries from that file, then start the
service again (the running service rewrites the file on every key change). A
revoked key stops background sync and asks the user to sign in again. The app
forgets a key only when the server reports it revoked, so other rejections
(such as a server rolled back to before device keys) leave it in place. The
key is never copied out of secure storage into the WebView session backup.

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

## Launcher icon

`src-tauri/icons/filesync-mark.svg` is the editable sync mark. Run
`bash scripts/generate-icons.sh` from this app directory with ImageMagick installed
to regenerate the full-bleed SVG/512px RGBA icon, favicon, service logos and Android
density assets. The adaptive launcher uses a separate chartreuse background and a
transparent foreground within the 66dp safe circle; retain the adaptive XML and
monochrome resources when regenerating. Android applies the launcher shape.
