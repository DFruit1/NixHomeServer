# Kanidm Guide

Use this as the single operator guide for:
- delegated operator sessions
- guided user creation and access assignment
- password-reset help for users
- advanced Kanidm inspection and runtime tuning when needed
- post-login access troubleshooting
- Vaultwarden invite onboarding when a user needs the shared password-manager workflow

Validation, service health, DNS checks, and guarded deploys live in [Operations](./operations.md).

## When To Use This Guide

Use this guide when any of these are true:
- you need a delegated operator login for Kanidm
- you are creating or deleting a user
- you are changing live group membership
- you are inspecting or tuning a live OAuth2 client
- a user can reach the identity flow but an app still denies access

If the problem is DNS, routing, TLS, or a dead service, start with [Operations](./operations.md#shared-troubleshooting-matrix) instead.

## Conventions

- Placeholders such as `<domain>`, `NEW_USER`, `EMAIL`, and `CLIENT` are examples. Replace them with the actual operator values before running commands.
- `kanidm-admin` is now TUI-first and live-discovery-driven. It does not depend on a hardcoded list of repo-managed groups.
- The repo still provides default connection context for `kanidm-admin`: server URL, admin name, and Kanidm binary path.
- The live Kanidm runtime is authoritative for users, groups, OAuth2 clients, and runtime policy values.

## Operator Identities

Intended identities:
- `admindsaw`: delegated operator identity
- `dsaw`: normal day-to-day identity
- `admin` and `idm_admin`: break-glass accounts only

Operational rule:
- `users` means the person exists
- app access comes from live group membership
- app-local admin roles may still exist after OIDC is correct

## First Admin Session

Log into Kanidm as the delegated operator.

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
kanidm-admin
```

Recommended TUI path:
1. Start `kanidm-admin`.
2. If no usable admin session exists yet, accept the startup login prompt.
3. Open `Sessions`.
4. Run `Status` if you want to confirm the session state.

Direct CLI path:

```bash
kanidm-admin session login
kanidm-admin session status
kanidm-admin session reauth
```

Auth command safety notes:
- `kanidm-admin session login` and `kanidm-admin session reauth` are terminal-only commands.
- They require `--output human` and an attached TTY on stdin and stdout.
- Non-interactive backend calls use a fixed internal timeout. A hung `kanidm` or `nix eval` subprocess fails explicitly instead of waiting forever.

## Preferred Operator Path

Preferred server-side path:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
kanidm-admin
```

The default TUI now centers the day-to-day tasks a new admin is most likely to need:
- create a user
- manage that user's normal and admin access groups
- inspect a user and understand their current access
- disable or re-enable a user
- help a user reset their password

Everything more specialized lives under `Advanced`.

Interactive navigation notes:
- `Esc` acts as back/cancel in menu-style screens so you can unwind menus quickly without selecting `Back`.
- The guided access picker intentionally hides protected groups such as `idm_*` and `system_admins`. Other visible groups keep their explanations in a contextual help pane that updates when the highlighted option changes.
- Picker-style screens support `/` filtering, so you can narrow long user, group, and client lists without leaving the flow.
- `Advanced` contains explicit session tools, raw membership tools, group inspection, OAuth2 clients, group policy, context/doctor, local helpers, and permanent user deletion.
- Advanced group inspection and policy flows now show all live groups, including protected groups such as `idm_*` and `system_admins`. The guided access-management pickers still hide those protected groups intentionally.

Expected result:
- the interactive tool keeps the normal workflow focused on user administration instead of general Kanidm internals
- live discovery is used for selectable groups and OAuth2 clients
- unsafe authoritative writes are blocked when discovery is partial or malformed

## User Lifecycle

Create a user:

```bash
kanidm-admin user create "$NEW_USER" --display-name "$NEW_USER" --email "$EMAIL"
```

Exceptional CLI-only path:
- add `--preserve-validity` only when you intentionally need to keep backend validity restrictions instead of clearing them after creation
- the default TUI and CLI path clears validity restrictions after user creation

Inspect a user:

```bash
kanidm-admin user show "$NEW_USER"
kanidm-admin membership show "$NEW_USER"
```

Disable or re-enable a user:

```bash
kanidm-admin user disable "$NEW_USER"
kanidm-admin user enable "$NEW_USER"
```

Delete a user:

```bash
kanidm-admin user delete "$NEW_USER" --confirm "$NEW_USER"
```

Help a user reset their password:

```bash
kanidm-admin user reset-token "$NEW_USER" --ttl 3600
```

Password-reset note:
- `kanidm-admin user reset-token` preserves the raw backend output in the immediate terminal/JSON command result so the operator can recover if parsing is incomplete.
- Persisted operation history redacts reset links, fallback tokens, raw backend output, and backend stdout/stderr for this command.
- If the wrapper cannot parse a reset URL or token cleanly, it emits warnings instead of pretending the structured fields are complete.
- The TUI now shows the target user and TTL before creating the reset link, then reminds the operator to share the result only through a secure channel.
- If older history may contain unredacted reset links or tokens, run `kanidm-admin history redact-sensitive`.
- On deployed hosts, history is stored in `/var/lib/kanidm-admin/history` with private permissions for the local admin account.

## Membership Management

Read-only inspection:

```bash
kanidm-admin group list
kanidm-admin group search storage
kanidm-admin group show users
kanidm-admin group members users
kanidm-admin membership show "$NEW_USER"
```

Incremental changes:

```bash
kanidm-admin membership add "$NEW_USER" users immich-users
kanidm-admin membership remove "$NEW_USER" immich-users
```

Authoritative set:

```bash
kanidm-admin membership set "$NEW_USER" users user-files mail-archive-users
kanidm-admin membership set "$NEW_USER" --allow-empty
```

File-access group model:
- `user-files` grants browser file access through Filestash and provisions a personal file root.
- `files-sftp-users` grants restricted SFTP login into the user's personal file root. File users are POSIX-enabled in Kanidm so OpenSSH can write files as the real Unix user.
- `files-shared-users` adds `_Shared` inside that personal root. `_Shared` is a delete-protected shared view; users can read, write, edit, and rename there, but deletes must be performed by an admin directly against the real shared path.

Expected result:
- `membership add` and `membership remove` work against live-discovered groups instead of a hardcoded Rust list
- `membership add` and `membership remove` require at least one group name
- the TUI defaults to a guided picker for incremental membership changes, with manual group entry kept as an explicit advanced path
- `membership set` makes the exact direct-group set explicit instead of relying on repeated incremental changes
- omitting every group requires `--allow-empty` so you do not accidentally strip all direct memberships
- `group search` matches case-insensitively against both group names and descriptions
- Vaultwarden is local-auth only. Kanidm does not grant Vaultwarden access through a group or OAuth2 client.
- the Vaultwarden local helper uses a live user picker only to resolve the user's primary email, then checks Vaultwarden state before deciding whether to send, resend, or skip an invite.

Normal onboarding sequence:
1. Create the person.
2. Add them to `users`.
3. Add only the live groups they need for file, app, or admin access.
4. For browser file access and a personal root, add `user-files` explicitly.
5. For SFTP login, add `files-sftp-users` explicitly.
6. For SFTP login, set their Kanidm POSIX/UNIX password live with `kanidm-admin user posix-password set "$NEW_USER"`.
7. For the shared `_Shared` folder inside their personal root, add `files-shared-users` explicitly.
8. Add `app-admin` only when they should be an application operator in the apps they already use.
9. Bootstrap `system_admins` manually with the regular `kanidm` CLI only when someone truly needs high-authority server administration.
10. If they should use the shared password manager, invite their Kanidm primary email into Vaultwarden with `kanidm-admin local vaultwarden invite "$NEW_USER"`. This does not grant Kanidm app access.
11. Have them sign into the target app so first-login provisioning can happen.

Interactive guidance note:
- The default `Manage User Access` flow uses an exact-set group picker with a contextual help pane.
- Exact-set membership changes now open a review screen that shows visible selections, preserved hidden groups, and the final direct-group set before any write is applied.
- The list shows only group names; each highlighted group explains what access or authority it grants.
- Low-level `membership add` and `membership remove` style operations remain under `Advanced`, but the TUI still defaults them to a guided picker with a review screen before the write.
- `Advanced -> Local Helpers -> Invite user to Vaultwarden` is the maintained onboarding path for the shared password-vault workflow.

## Files SFTP Access

Direct files SFTP access uses Kanidm identity through PAM/NSS and the user's
Kanidm POSIX/UNIX password. That POSIX password is a separate Kanidm credential
from the normal web/OIDC password or passkey. It does not use per-user SSH
public keys.

Grant direct SFTP access:

```bash
kanidm-admin membership add alice files-sftp-users
kanidm-admin membership add alice files-shared-users
kanidm-admin user posix-password set alice
```

The user can then connect from a local file browser and sign in with their
Kanidm POSIX/UNIX password:

```text
sftp://alice@server.home.arpa:2222/
```

Important:
- `files-sftp-users` controls SFTP login eligibility on the dedicated files SFTP port
- direct SFTP password login requires a Kanidm POSIX/UNIX password set live with `kanidm-admin user posix-password set <username>`
- the POSIX/UNIX password is not declared in NixOS config and is not automatically kept in sync with the user's web/OIDC password or passkey
- `files-shared-users` controls whether `_Shared` appears inside the user's personal root
- `user-files` controls browser file access through Filestash
- the dedicated SFTP endpoint forces `internal-sftp` and does not grant normal SSH shell access
- normal SSH on port `22` is reserved for the local Unix admin account and does not expose SFTP
- admin users that connect to the files SFTP port are still chrooted to their own personal files root; root filesystem access requires normal SSH on port `22`

## OAuth2 Clients

Read-only inspection:

```bash
kanidm-admin client list
kanidm-admin client show files
```

Curated live runtime controls:

```bash
kanidm-admin client secret show files
kanidm-admin client secret reset files
kanidm-admin client redirect add files "https://uploads.<domain>/oauth2/callback"
kanidm-admin client redirect remove files "https://uploads.<domain>/oauth2/callback"
kanidm-admin client pkce enable files
kanidm-admin client pkce disable files
kanidm-admin client consent enable files
kanidm-admin client consent disable files
```

Client-secret note:
- `client secret show` and `client secret reset` intentionally reveal secret material in the immediate command output.
- JSON output marks these responses with `"sensitive": true`.
- Persisted operation history and in-process backend logs redact the secret-bearing raw output.
- If older history may contain unredacted client secrets, run `kanidm-admin history redact-sensitive`.

Expected result:
- OAuth2 clients are discovered live from Kanidm
- `client show` exposes redirect URLs, scope maps, claim maps, and referenced groups when the backend returns them
- redirect add/remove in the TUI now show the current redirect set and skip clean no-op requests before any write
- only runtime-discoverable toggles are mutated here; repo-backed `.nix` settings remain out of scope

## Group Policy

Inspect group account policy:

```bash
kanidm-admin policy group show idm_all_persons
```

Tune auth-expiry and privilege-expiry live:

```bash
kanidm-admin policy group auth-expiry set idm_all_persons 259200
kanidm-admin policy group auth-expiry reset idm_all_persons
kanidm-admin policy group privilege-expiry set idm_all_persons 900
kanidm-admin policy group privilege-expiry reset idm_all_persons
```

Expected result:
- the CLI uses live Kanidm account-policy commands
- write operations use read-after-write verification
- the TUI now reviews current versus requested policy values before running a live write and skips clean no-op resets or re-applies
- repo-backed variables such as `vars.nix` are not edited by this tool

## App-Specific First Login Notes

- `files.<domain>`: Filestash browser access requires `user-files` and connects to the chrooted SFTP endpoint with the managed Filestash SFTP key. Direct SFTP login requires `files-sftp-users` and the user's separate Kanidm POSIX/UNIX password. `files-shared-users` adds `_Shared` to either view; `app-admin` and `system_admins` do not expose shared files there.
- `emails.<domain>`: browser access is enforced by `mail-archive-users`. That group grants access to the private mail-archive UI only; it does not grant direct access to the hidden `.internal-sync` payload tree. User-visible mailbox `.eml` files are exposed through the visible mirror under each personal `_Emails/` root.
- `passwords.<domain>`: Vaultwarden is local-auth only. Use `kanidm-admin local vaultwarden invite "$ACCOUNT_ID"` as an email-resolution helper, then the user signs in with Vaultwarden local credentials. See [Vaultwarden Guide](./vaultwarden.md).
- `wiki.<domain>`: baseline `users` membership is sufficient.
- `ytdownload.<domain>`: browser access is enforced by `downloads-users`.
- Immich: `immich-users` grants normal login and `app-admin` adds the admin role when combined with `immich-users`.
- Paperless: `paperless-users` grants normal login and `app-admin` adds the Paperless admin flags when combined with `paperless-users`.
- Audiobookshelf: `audiobookshelf-users` grants normal login and `app-admin` adds the admin role when combined with `audiobookshelf-users`.
- Kavita: `kavita-users` grants normal login and `app-admin` adds the admin role when combined with `kavita-users`.
- Jellyfin sign-in remains local-auth. `jellyfin-users` is the source of truth for managed Jellyfin local-account and per-library policy; `app-admin` plus `jellyfin-users` grants Jellyfin app-admin/library-wide access only for accounts listed in `jellyfinAdminUsers`. Missing local Jellyfin accounts are created disabled until an operator sets and enables credentials. OAuth2 Proxy is not used to inject Jellyfin passwords.
- Jellyfin manages five video folders for shared and per-user libraries: `_Movies`, `_Shows`, `_Home`, `_Music-videos`, and `_YouTube`. The old `Other Videos` library and Jellyfin YouTube Music library are retired; pure audio with thumbnails belongs in Audiobookshelf.

## Troubleshooting Flow

Use this order so you do not chase the wrong layer.

1. If `https://id.<domain>` or the target app URL is unreachable, stop here and use [Operations](./operations.md#service-failure-entry-points). That is a DNS, routing, TLS, or service-health problem, not a group-membership problem.
2. If the operator session is missing or expired, re-run the Kanidm session commands before changing users or groups.

```bash
kanidm-admin session status
kanidm-admin session login
kanidm-admin session reauth
```

3. If the user authenticates successfully but the app denies access, inspect the live user, group, and client state.

```bash
kanidm-admin user show "$NEW_USER"
kanidm-admin membership show "$NEW_USER"
kanidm-admin client show files
```

4. If the live group state looks correct but the app role is still wrong, treat it as an app-local role or bootstrap issue.
   - Immich and Paperless should provision the local account at first successful OIDC login.
   - Audiobookshelf and Kavita can still require app-local admin or bootstrap work after identity is correct.
   - Jellyfin sign-in is still local-auth, but `jellyfin-users`, `app-admin`, and `jellyfinAdminUsers` drive the managed local-account and library policy reconciler.

## After Identity Changes

After changing users, groups, or runtime client policy:
- re-run `kanidm-admin session reauth` if you need fresh privileged access
- test the app login with the intended user
- confirm the user lands in the expected app role
- use [Operations](./operations.md) if the issue looks like DNS, routing, or service health instead of identity data
