# File Sync uses Kanidm and platform-native file access

- Status: accepted
- Date: 2026-09-26

## Context

The Android and Linux client needs to keep one shared Tauri UI while using each
platform's reliable folder access. Android users select provider-backed trees
through SAF, while Linux can use ordinary paths. SFTP keys would add a second
identity lifecycle and make Android file access unrelated to its native
storage model. Kanidm login is already the user identity for the server.

## Decision

The client authenticates with Kanidm OpenID Connect authorization code flow
and PKCE. It calls a dedicated HTTPS API with bearer access tokens. The API
validates signature, issuer, audience, expiry, and username, then resolves
paths beneath a server-advertised personal library root for that user. Roots
are fixed by the enabled NixOS modules; the client can select a root ID and a
relative path but cannot provide an absolute server path. The API has no SFTP listener or
key management.

The API runs as a dedicated unprivileged account. While it runs, root-owned
systemd pre-start and post-stop helpers grant and remove ACL access to enabled
personal library trees. Rust filesystem operations are anchored to per-user directory
capabilities. Android keeps the SAF tree grant and transfers through private
cache files; Linux uses native filesystem paths and the system keyring. Tokens
and the pending PKCE transaction stay out of the webview.

The client supports one-way copies. A copy may replace a same-name destination
file, creates missing destination folders, and does not delete files. Android
stores saved pair configuration in the app's encrypted native store and uses
WorkManager to check pairs periodically, with an unmetered network required.
The periodic interval is 15 minutes, the WorkManager minimum; Android may defer
individual runs. A foreground data-sync notification is shown while a worker is
active so larger transfers can outlast a short worker window. The Kotlin worker
uses the same persisted SAF tree grants and encrypted Kanidm session as manual
sync. Linux keeps explicit manual sync. Two-way conflict resolution remains
deferred.

The authenticated `/api/v1/presets` endpoint advertises only enabled services
with an existing personal folder for the signed-in user. Each preset includes
the root ID, title, direction, server path, and suggested local subfolder.
Selecting a service card and pressing Enable and sync opens the platform folder picker,
saves a pair, and starts the first copy. The music preset reads personal `_Music` and places files in
`_My Music` below the chosen local folder. Manual pairs may browse the same
advertised roots and select another relative path or direction.

## Alternatives Considered

### SFTP key authentication

Rejected for this app because Kanidm already supplies the user's identity and
an SFTP key would require separate provisioning and revocation. Personal SFTP
connections remain a separate server feature.

### Tauri filesystem plugins for both platforms

Rejected because Android SAF grants are provider-backed URI trees rather than
ordinary paths. Keeping Android access in a native adapter preserves persisted
URI permissions and avoids routing file contents through the webview.

### Native Kotlin app for the complete client

Deferred because the shared UI, account flow, and pair configuration can stay
in Tauri; only folder selection and file operations need platform-specific
implementations.

## Consequences

- The API and Kanidm OAuth2 client are optional pieces owned by the `filesync`
  NixOS module.
- Revoking Kanidm sessions or disabling the OAuth client stops API access; no
  SFTP key needs to be revoked for this app.
- Android background sync can be delayed by system scheduling, network state,
  force-stop behavior, or revoked SAF/Kanidm access. It is not a guaranteed
  real-time transfer service. Linux remains manual, and two-way conflict
  handling is not implemented.
- The system account can access every enabled personal library tree while the service
  is running. Application authorization still maps each request to one user;
  the limited ACL scope reduces the impact of a service compromise compared
  with running the API as root.

## Validation

The Vite bundle and Linux Tauri crate compile; Android Kotlin compilation and
an arm64 debug APK build succeed. Device behavior, OAuth login, SAF provider
behavior, Linux keyring behavior, and per-user API isolation still need
validation before regular use.
