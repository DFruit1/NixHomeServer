# Kanidm Guide

Use this as the single operator guide for:
- admin identities
- access groups
- first admin session workflow
- user onboarding
- interactive and CLI identity commands
- app access troubleshooting after sign-in

Validation, service health, DNS checks, and guarded deploys live in [Operations](./operations.md).

## When To Use This Guide

Use this guide when any of these are true:
- you need a delegated operator login for Kanidm
- you are creating a user or granting app access
- a user can reach the identity flow but an app still denies access
- you need reset tokens, group inspection, or access explanations

If the problem is DNS, routing, TLS, or a dead service, start with [Operations](./operations.md#shared-troubleshooting-matrix) instead.

## Conventions

- Placeholders such as `<domain>`, `KANIDM_URL`, `ADMIN_USER`, `NEW_USER`, and `EMAIL` are examples. Replace them with the actual operator values before running commands.
- Group names such as `users`, `immich-users`, `paperless-users`, `fileshare_users`, and `*-admin` are literal names managed by this repo. Do not rename them in commands.
- Command blocks use the same context format:
  - Run from: where to execute the commands
  - Privileges: whether `sudo` is required
  - Environment: whether a plain shell or a specific `nix shell` is expected

## Operator Identities

Intended identities:
- `admindsaw`: delegated operator identity
- `dsaw`: normal day-to-day identity
- `admin` and `idm_admin`: break-glass accounts only

Operational rule:
- `users` means the person exists
- app access comes from app-specific groups
- admin intent is tracked separately from login access

## Access Groups

Login access groups:
- `fileshare_users`
- `mail-archive-users`
- `immich-users`
- `paperless-users`
- `audiobookshelf-users`
- `kavita-login`
- `jellyfin-users`

Admin intent groups:
- `immich-admin`
- `paperless-admin`
- `audiobookshelf-admin`
- `kavita-admin`
- `jellyfin-admin`

## First Admin Session

Log into Kanidm as the delegated operator.

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `nix shell nixpkgs#kanidm_1_9 --impure`

```bash
kanidm login --url https://id.<domain> --name admindsaw
kanidm reauth --url https://id.<domain> --name admindsaw
```

Expected result:
- the login flow completes for `admindsaw`
- `kanidm reauth` refreshes the session without needing a break-glass account
- you can continue with group and user operations as the delegated operator

If the web UI looks limited, that is expected. The reliable admin path is the CLI.

## Create And Grant A User

Preferred operator path on the server:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
kanidm-admin interactive
```

The interactive flow covers:
- login and reauthentication guidance
- create user
- list users
- inspect a user
- edit repo-managed access groups when the backend group inventory is complete
- create password reset tokens

Expected result:
- the interactive tool shows the user and access workflows you need without using break-glass credentials
- the new user can be inspected immediately after creation

Direct server-side CLI path:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
kanidm-admin users create "$NEW_USER" --display-name "$NEW_USER" --email "$EMAIL"
kanidm-admin access grant "$NEW_USER" users
kanidm-admin access grant "$NEW_USER" immich-users
```

Expected result:
- the person exists after `users create`
- `users` grant marks the person as an allowed user
- the app-specific grant makes the user eligible for the target app's first-login provisioning

CLI path from a workstation shell:

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `nix shell nixpkgs#kanidm_1_9 --impure`

```bash
export KANIDM_URL='https://id.<domain>'
export ADMIN_USER='admindsaw'
export NEW_USER='newuser'
export EMAIL='newuser@example.test'

kanidm person create "$NEW_USER" --displayname "$NEW_USER" --mail "$EMAIL" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members immich-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Expected result:
- `kanidm person create` returns success for the new person
- `users` membership exists immediately after the group update
- the app-specific group membership appears when you inspect the user or group

Normal onboarding sequence:
1. Create the person.
2. Add them to `users`.
3. Add only the app-specific login groups they need.
4. Add `*-admin` groups only when they should administer that app.
5. Have them sign into the target app so first-login provisioning can happen.

## App-Specific First Login Notes

- `files.<domain>`: browser access is enforced by OAuth2 Proxy and `fileshare_users`.
- `emails.<domain>`: private-only access is enforced by `mail-archive-users`.
- `wiki.<domain>`: browser access is enforced by OAuth2 Proxy; baseline `users` membership is sufficient.
- Immich: first successful OIDC login creates the local user row.
- Paperless: first successful OIDC login creates or links the local user row.
- Audiobookshelf: OIDC is configured, but the local bootstrap or root flow still exists.
- Kavita: OIDC handles auth and provisioning, but admin roles remain app-local.
- Jellyfin is an intentional local-auth exception. `jellyfin-users` and `jellyfin-admin` still drive local-account reconciliation, but the Jellyfin password stays separate from Kanidm.

Expected result after first login:
- the user reaches the app instead of looping back to the login flow
- the app creates or links the expected local user row on first successful OIDC login
- the user lands with the correct access scope for the granted group set

If the user authenticates but still lacks access, continue in [Troubleshooting Flow](#troubleshooting-flow).

Useful `kanidm-admin` examples:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
kanidm-admin auth login
kanidm-admin auth reauth
kanidm-admin auth status
kanidm-admin config show
kanidm-admin users show dsaw
kanidm-admin users disable dsaw
kanidm-admin users enable dsaw
kanidm-admin users delete dsaw --confirm dsaw
kanidm-admin users reset-token dsaw --ttl 3600
kanidm-admin access show dsaw
kanidm-admin access grant dsaw mail-archive-users
kanidm-admin access revoke dsaw mail-archive-users
kanidm-admin access set dsaw --group users --group mail-archive-users
kanidm-admin access why-denied --app mail-archive --user dsaw
sudo env JELLYFIN_PASSWORD='replace-me' kanidm-admin jellyfin set-password dsaw --password-env JELLYFIN_PASSWORD
```

Auth command safety notes:

- `kanidm-admin auth login` and `kanidm-admin auth reauth` are terminal-only commands. They require `--format human` and an attached TTY on stdin and stdout.
- Non-interactive `kanidm-admin` backend calls use a fixed internal timeout. A hung `kanidm` or `nix eval` subprocess now fails explicitly instead of waiting forever.

## Useful CLI Commands

Read-only inspection:

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `nix shell nixpkgs#kanidm_1_9 --impure`

```bash
kanidm group list --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person list --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group get immich-users --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Grant or remove access:

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `nix shell nixpkgs#kanidm_1_9 --impure`

```bash
kanidm group add-members paperless-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group remove-members paperless-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Expected result:
- the user either appears in or disappears from the target group immediately
- the next app login reflects the membership change after normal OIDC reauthentication
- for Jellyfin, group membership alone is not enough; set or rotate the local Jellyfin password separately

Authoritative managed-group convergence:

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
kanidm-admin access set "$NEW_USER" --group users --group paperless-users
kanidm-admin access set "$NEW_USER" --allow-empty
```

Expected result:
- `access set` makes the repo-managed group set explicit instead of relying on multiple grant or revoke calls
- omitting every `--group` requires `--allow-empty` so you do not accidentally strip all managed access
- the interactive authoritative group editor refuses to continue if the Kanidm group inventory is incomplete or partially parsed, because partial inventory is unsafe for authoritative mutation

Reset, disable, or re-enable a user:

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `nix shell nixpkgs#kanidm_1_9 --impure`

```bash
kanidm-admin users reset-token "$NEW_USER" --ttl 3600
kanidm person credential update "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person disable "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person enable "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Reset-token note:

- `kanidm-admin users reset-token` always preserves the raw backend output.
- If the wrapper cannot parse a reset URL or token cleanly, it now emits warnings instead of pretending the structured fields are complete.

Delete a user:

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `nix shell nixpkgs#kanidm_1_9 --impure`

```bash
kanidm person delete "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

## Troubleshooting Flow

Use this order so you do not chase the wrong layer.

1. If `https://id.<domain>` or the target app URL is unreachable, stop here and use [Operations](./operations.md#service-failure-entry-points). This is a DNS, routing, TLS, or service-health problem, not an access-group problem.
2. If the user reaches Kanidm but cannot complete the login or reauthentication flow, re-run the operator session commands and confirm the identity endpoint is healthy before changing groups.

- Run from: `workstation repo root`
- Privileges: `sudo not required`
- Environment: `nix shell nixpkgs#kanidm_1_9 --impure`

```bash
kanidm reauth --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person list --url "$KANIDM_URL" --name "$ADMIN_USER"
```

3. If the user authenticates successfully but the app denies access, inspect group membership and ask why access is denied.

- Run from: `target server shell`
- Privileges: `sudo not required`
- Environment: `plain shell`

```bash
kanidm-admin users show "$NEW_USER"
kanidm-admin access show "$NEW_USER"
kanidm-admin access why-denied --app mail-archive --user "$NEW_USER"
kanidm-admin access why-denied --app jellyfin --user "$NEW_USER"
```

Expected result:
- you can see whether the user exists
- you can confirm whether the required login group is present
- `access why-denied` reports the exact repo-managed checks it performed and explicitly lists what it did not check

4. If group membership looks correct but the app role is still wrong, treat it as an app-local role or admin issue.
   - Immich and Paperless should provision the local account at first successful OIDC login.
   - Audiobookshelf and Kavita can still require app-local admin or bootstrap work after identity is correct.
   - Jellyfin is intentionally local-auth and should not be debugged as an OIDC grant issue. Group membership alone is insufficient; the local Jellyfin password and Jellyfin sync must also converge.

## After Identity Changes

After changing users or groups:
- re-run `kanidm reauth`
- test the app login with the intended user
- confirm the user lands in the expected app role
- use [Operations](./operations.md) if the issue looks like DNS, routing, or service health instead of identity data
