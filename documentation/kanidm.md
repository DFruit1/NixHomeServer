# Kanidm Guide

Use this as the single operator guide for:
- delegated operator sessions
- user creation and lifecycle changes
- live group discovery and membership changes
- OAuth2 client inspection and runtime tuning
- reset tokens
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
1. Open `Sessions`.
2. Run `Login`.
3. Run `Status` if you want to confirm the session state.

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

The TUI covers:
- session login, reauthentication, and logout
- user creation, inspection, disable, enable, delete, and reset-token flows
- live group inspection
- authoritative membership editing backed by live group discovery
- OAuth2 client inspection plus selected runtime toggles
- group account-policy inspection plus auth-expiry and privilege-expiry changes

Expected result:
- the interactive tool shows the user, group, membership, client, and policy workflows you need without using break-glass credentials
- live discovery is used for selectable groups and OAuth2 clients
- unsafe authoritative writes are blocked when discovery is partial or malformed

## User Lifecycle

Create a user:

```bash
kanidm-admin user create "$NEW_USER" --display-name "$NEW_USER" --email "$EMAIL"
```

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

Create a password reset token:

```bash
kanidm-admin user reset-token "$NEW_USER" --ttl 3600
```

Reset-token note:
- `kanidm-admin user reset-token` always preserves the raw backend output.
- If the wrapper cannot parse a reset URL or token cleanly, it emits warnings instead of pretending the structured fields are complete.

## Membership Management

Read-only inspection:

```bash
kanidm-admin group list
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
- `user-files` is required separately for personal Copyparty and SMB access.
- `shared-files-ro` grants read-only access to `/shared/*`.
- `shared-files-rw` grants shared-write access through Samba only.
- `shared-files-ro` and `shared-files-rw` do not imply `user-files`.

Expected result:
- `membership add` and `membership remove` work against live-discovered groups instead of a hardcoded Rust list
- `membership set` makes the exact direct-group set explicit instead of relying on repeated incremental changes
- omitting every group requires `--allow-empty` so you do not accidentally strip all direct memberships

Normal onboarding sequence:
1. Create the person.
2. Add them to `users`.
3. Add only the live groups they need for file, app, or admin access.
4. For personal file access, add `user-files` explicitly.
5. Add `shared-files-ro` or `shared-files-rw` only if they need `/shared/*` access.
6. Have them sign into the target app so first-login provisioning can happen.

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
kanidm-admin client redirect add files "https://files.<domain>/oauth2/callback"
kanidm-admin client redirect remove files "https://files.<domain>/oauth2/callback"
kanidm-admin client pkce enable files
kanidm-admin client pkce disable files
kanidm-admin client consent enable files
kanidm-admin client consent disable files
```

Expected result:
- OAuth2 clients are discovered live from Kanidm
- `client show` exposes redirect URLs, scope maps, claim maps, and referenced groups when the backend returns them
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
- repo-backed variables such as `vars.nix` are not edited by this tool

## App-Specific First Login Notes

- `files.<domain>`: browser access is enforced by OAuth2 Proxy. Personal roots require `user-files`; shared roots require `shared-files-ro` or `shared-files-rw`.
- `emails.<domain>`: browser access is enforced by `mail-archive-users`.
- `wiki.<domain>`: baseline `users` membership is sufficient.
- `ytdownload.<domain>`: browser access is enforced by `metube-users`.
- Immich: first successful OIDC login creates the local user row.
- Paperless: first successful OIDC login creates or links the local user row.
- Audiobookshelf: OIDC is configured, but the local bootstrap or root flow still exists.
- Kavita: OIDC handles auth and provisioning, non-admin local password login is disabled, and admin recovery remains app-local.
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
