# Kanidm Guide

Use this as the single operator guide for:
- admin identities
- access groups
- first admin session workflow
- user onboarding
- CLI and TUI commands

Validation, service health, DNS checks, and guarded deploys live in [Operations](./operations.md).

## 1. Operator Identities

Intended identities:
- `admindsaw`: delegated operator identity
- `dsaw`: normal day-to-day identity
- `admin` and `idm_admin`: break-glass accounts only

Operational rule:
- `users` means the person exists
- app access comes from app-specific groups
- admin intent is tracked separately from login access

## 2. Access Groups

Login access groups:
- `fileshare_users`
- `mail-archive-users`
- `immich-users`
- `paperless-users`
- `audiobookshelf-users`
- `kavita-login`

Admin intent groups:
- `immich-admin`
- `paperless-admin`
- `audiobookshelf-admin`
- `kavita-admin`

## 3. First Admin Session

Log into Kanidm as the delegated operator:

```bash
nix shell nixpkgs#kanidm_1_9 --impure
kanidm login --url https://id.<domain> --name admindsaw
kanidm reauth --url https://id.<domain> --name admindsaw
```

If the web UI looks limited, that is expected. The reliable admin path is the
CLI or `kanidm-user-tui`.

## 4. Create And Grant A User

Preferred interactive path on the server:

```bash
kanidm-user-tui
```

CLI flow:

```bash
export KANIDM_URL='https://id.<domain>'
export ADMIN_USER='admindsaw'
export NEW_USER='newuser'
export EMAIL='newuser@example.test'

kanidm person create "$NEW_USER" --displayname "$NEW_USER" --mail "$EMAIL" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members immich-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Normal onboarding sequence:
1. Create the person.
2. Add them to `users`.
3. Add only the app-specific login groups they need.
4. Add `*-admin` groups only when they should administer that app.
5. Have them sign into the target app so first-login provisioning can happen.

## 5. App-Specific First Login Notes

- `files.<domain>`: browser access is enforced by OAuth2 Proxy and `fileshare_users`.
- `emails.<domain>`: private-only access is enforced by `mail-archive-users`.
- Immich: first successful OIDC login creates the local user row.
- Paperless: first successful OIDC login creates or links the local user row.
- Audiobookshelf: OIDC is configured, but the local bootstrap/root flow still exists.
- Kavita: OIDC handles auth and provisioning, but admin roles remain app-local.
- Jellyfin is an intentional local-auth exception.

## 6. Useful CLI Commands

Read-only inspection:

```bash
kanidm group list --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person list --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group get immich-users --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Grant or remove access:

```bash
kanidm group add-members paperless-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group remove-members paperless-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Reset, disable, or re-enable a user:

```bash
kanidm person credential update "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person disable "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person enable "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Delete a user:

```bash
kanidm person delete "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

## 7. After Identity Changes

After changing users or groups:
- re-run `kanidm reauth`
- test the app login with the intended user
- confirm the user lands in the expected app role
- use [Operations](./operations.md) if the issue looks like DNS, routing, or service health instead of identity data
