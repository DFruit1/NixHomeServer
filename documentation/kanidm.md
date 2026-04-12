# Kanidm Guide

Use this guide to bootstrap people, groups, and app access for this stack.

## Operator identities

This repository now assumes two human operator identities:

- `admindsaw`: privileged admin identity for infrastructure and app administration
- `dsaw`: normal day-to-day identity with no global admin rights by default

Break-glass directory admins still exist separately:

- `admin`
- `idm_admin`

Do not use the break-glass accounts for daily work.

The Nix config seeds `admindsaw` into the baseline `users` group, the public
`fileshare_users` group, and the app-admin groups for the current OIDC apps so
the operator account stays functional after rebuilds.

## What Kanidm controls here

- user identity: accounts, passwords, reset tokens
- group-based app access
- OIDC clients and callback URLs
- access policy for Immich, Paperless, Audiobookshelf, Kavita, and files

Kanidm does **not** automatically pre-create downstream app users unless that
application supports just-in-time creation on first OIDC login.

## Access groups used in this repo

| Group | Purpose |
|---|---|
| `users` | baseline identity group only; does not grant app access by itself |
| `fileshare_users` | access to `https://files.<domain>` through OAuth2 Proxy |
| `immich-users` | login access to `https://photos.<domain>` |
| `immich-admin` | intended Immich admins; also grants login |
| `paperless-users` | login access to `https://paperless.<domain>` |
| `paperless-admin` | intended Paperless admins; also grants login |
| `audiobookshelf-users` | login access to `https://audiobooks.<domain>` |
| `audiobookshelf-admin` | intended Audiobookshelf admins; also grants login |
| `kavita-login` | login access to `https://books.<domain>` |
| `kavita-admin` | Kavita admin role mapping; also grants login |
| `idm_admins` | delegated directory administration inside Kanidm |

## App auth model

| App | Sign-in URL | Auth model | First login behavior | Admin model |
|---|---|---|---|---|
| Copyparty | `https://files.<domain>` | Kanidm via OAuth2 Proxy | no separate app bootstrap here | app-local / server-side |
| Immich | `https://photos.<domain>` | Kanidm OIDC | user row is created on first successful OIDC login | `immich-admin` is the intended admin group; promotion may still require app-local follow-up |
| Paperless | `https://paperless.<domain>` | Kanidm OIDC | user row is created or linked on first successful OIDC login | `paperless-admin` is the intended admin group; keep one local recovery superuser |
| Audiobookshelf | `https://audiobooks.<domain>` | Kanidm OIDC | user row is created or linked on first successful OIDC login | `audiobookshelf-admin` is the intended admin group; keep root bootstrap as break-glass |
| Kavita | `https://books.<domain>` | Kanidm OIDC | account is provisioned on first successful OIDC login | `kavita-admin` maps through OIDC group claims |
| Jellyfin | `https://video.<domain>` | local app auth | local users only | local admin only |
| Jellyseerr | `https://jellyseerr.<domain>` | Jellyfin-backed auth | bootstrap through Jellyfin | local/Jellyfin-backed admin |

## First login

```bash
nix shell nixpkgs#kanidm_1_9 --impure
kanidm login --url https://id.<domain> --name <delegated-admin-user>
```

Use your delegated admin identity for this workflow, normally `admindsaw`.

## New user workflow

1. create the person in Kanidm
2. add them to `users`
3. add them to the app-specific `*-users` groups they should access
4. optionally add them to app-specific `*-admin` groups
5. have them sign into the target app
6. let the app create or link the local user row on first successful OIDC login

## Create a new user (copy/paste)

```bash
export KANIDM_URL='https://id.<domain>'
export ADMIN_USER='<delegated-admin-user>'
export NEW_USER='<account-id>'
export NEW_NAME='<display-name>'
export NEW_EMAIL='<email@example.com>'

kanidm person create "$NEW_USER" "$NEW_NAME" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm person update "$NEW_USER" --mail "$NEW_EMAIL" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

## App access grants

```bash
# Public files access
kanidm group add-members fileshare_users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"

# Immich
kanidm group add-members immich-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members immich-admin "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"

# Paperless
kanidm group add-members paperless-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members paperless-admin "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"

# Audiobookshelf
kanidm group add-members audiobookshelf-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members audiobookshelf-admin "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"

# Kavita
kanidm group add-members kavita-login "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
kanidm group add-members kavita-admin "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

Only grant the `*-admin` groups when the user should actually administer that
application.

## Important behavior notes

- `users` is now a baseline identity group only. It does not grant app access
  by itself.
- `admindsaw` is the intended privileged operator identity.
- `dsaw` is the intended normal daily-use identity.
- Jellyfin and Jellyseerr remain local-auth exceptions in the current stack.
- Immich, Paperless, and Audiobookshelf may still require one local recovery
  admin or one-time admin promotion step even when Kanidm handles login.
- OIDC clients are provisioned by Nix config; avoid manual drift in the Kanidm
  UI.

## Easier interactive admin

Run `kanidm-user-tui` on the server.

Full CLI examples: [Kanidm CLI Reference](./kanidm_cli.md).
