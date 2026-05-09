# Kanidm Guide

Use this as the single operator guide for:
- delegated operator sessions
- guided user creation and access assignment
- password-reset help for users
- advanced Kanidm inspection and runtime tuning when needed
- post-login access troubleshooting

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
- The guided access picker intentionally hides internal Kanidm groups such as `idm_*`. Other visible groups keep their explanations in a contextual help pane that updates when the highlighted option changes.
- Picker-style screens support `/` filtering, so you can narrow long user, group, and client lists without leaving the flow.
- `Advanced` contains explicit session tools, raw membership tools, group inspection, OAuth2 clients, group policy, context/doctor, local helpers, and permanent user deletion.
- Advanced group inspection and policy flows now show all live groups, including internal Kanidm groups such as `idm_*`. The guided access-management pickers still hide those internal groups intentionally.

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
- `kanidm-admin user reset-token` always preserves the raw backend output.
- If the wrapper cannot parse a reset URL or token cleanly, it emits warnings instead of pretending the structured fields are complete.
- The TUI now shows the target user and TTL before creating the reset link, then reminds the operator to share the result only through a secure channel.

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
- `user-files` grants access to personal Copyparty uploads and the personal FileBrowser root.
- `shared-files-ro` grants read-only access to `/shared/*` in FileBrowser and WebDAV.
- `shared-files-ro` does not imply `user-files`.
- Human shared-write access is not modeled as a normal Kanidm group anymore.

Expected result:
- `membership add` and `membership remove` work against live-discovered groups instead of a hardcoded Rust list
- `membership add` and `membership remove` require at least one group name
- the TUI defaults to a guided picker for incremental membership changes, with manual group entry kept as an explicit advanced path
- `membership set` makes the exact direct-group set explicit instead of relying on repeated incremental changes
- omitting every group requires `--allow-empty` so you do not accidentally strip all direct memberships
- `group search` matches case-insensitively against both group names and descriptions

Normal onboarding sequence:
1. Create the person.
2. Add them to `users`.
3. Add only the live groups they need for file, app, or admin access.
4. For personal file access, add `user-files` explicitly.
5. Add `shared-files-ro` only if they need read access to `/shared/*`.
6. Add `app-admin` only when they should be an application operator in the apps they already use.
7. Reserve `system_admins` for trusted operators who need high-authority server or shared-files administration.
8. Have them sign into the target app so first-login provisioning can happen.

Interactive guidance note:
- The default `Manage User Access` flow uses an exact-set group picker with a contextual help pane.
- Exact-set membership changes now open a review screen that shows visible selections, preserved hidden groups, and the final direct-group set before any write is applied.
- The list shows only group names; each highlighted group explains what access or authority it grants.
- Low-level `membership add` and `membership remove` style operations remain under `Advanced`, but the TUI still defaults them to a guided picker with a review screen before the write.

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

- `uploads.<domain>`: Copyparty upload access is enforced by OAuth2 Proxy. `user-files` grants access to the signed-in user's own uploads root at `/`.
- `files.<domain>`: FileBrowser UI and WebDAV access require `user-files` for personal roots, `shared-files-ro` for shared read-only access, and `system_admins` for shared administration.
- `emails.<domain>`: browser access is enforced by `mail-archive-users`.
- `wiki.<domain>`: baseline `users` membership is sufficient.
- `ytdownload.<domain>`: browser access is enforced by `metube-users`.
- Immich: `immich-users` grants normal login and `app-admin` adds the admin role when combined with `immich-users`.
- Paperless: `paperless-users` grants normal login and `app-admin` adds the Paperless admin flags when combined with `paperless-users`.
- Audiobookshelf: `audiobookshelf-users` grants normal login and `app-admin` adds the admin role when combined with `audiobookshelf-users`.
- Kavita: `kavita-users` grants normal login and `app-admin` adds the admin role when combined with `kavita-users`.
- Jellyfin is intentionally local-auth and is managed through the local helper only when you need to stage a desired password hash.

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
   - Jellyfin is intentionally local-auth and should be debugged inside Jellyfin itself, not as a Kanidm group or OIDC claim problem.

## After Identity Changes

After changing users, groups, or runtime client policy:
- re-run `kanidm-admin session reauth` if you need fresh privileged access
- test the app login with the intended user
- confirm the user lands in the expected app role
- use [Operations](./operations.md) if the issue looks like DNS, routing, or service health instead of identity data
