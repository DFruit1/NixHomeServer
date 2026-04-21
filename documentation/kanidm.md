# Kanidm Guide

Use this guide to bootstrap people, groups, and app access for this stack.

If you are new to the system, read [First Admin Session](./first-admin-session.md)
first and come back here for the identity details.

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
- access policy for Immich, Paperless, Audiobookshelf, Kavita, files, and the mail archive UI
- branding for the Kanidm apps listing page

Kanidm does **not** automatically pre-create downstream app users unless that
application supports just-in-time creation on first OIDC login.

## Access groups used in this repo

| Group | Purpose |
|---|---|
| `users` | baseline identity group only; does not grant app access by itself |
| `fileshare_users` | access to `https://files.<domain>` through OAuth2 Proxy |
| `mail-archive-users` | opt-in access to `https://emails.<domain>` for mailbox sync and search |
| `immich-users` | login access to `https://photos.<domain>` |
| `immich-admin` | intended Immich admins; also grants login |
| `paperless-users` | login access to `https://paperless.<domain>` |
| `paperless-admin` | intended Paperless admins; also grants login |
| `audiobookshelf-users` | login access to `https://audiobooks.<domain>` |
| `audiobookshelf-admin` | intended Audiobookshelf admins; also grants login |
| `kavita-login` | login access to `https://books.<domain>` |
| `kavita-admin` | Kavita login access plus intended admin users; local promotion is still required on the current package |
| `idm_admins` | delegated directory administration inside Kanidm |

## App auth model

| App | Sign-in URL | Auth model | First login behavior | Admin model |
|---|---|---|---|---|
| Copyparty | `https://files.<domain>` | Kanidm via OAuth2 Proxy | `fileshare_users` membership materializes the personal workspace path | app-local / server-side |
| Mail Archive | `https://emails.<domain>` | Kanidm via dedicated OAuth2 Proxy | the user connects one or more IMAP accounts in the UI; the archive is created under app-owned storage on first save | proxy-side group gate plus app-local per-user scoping |
| Immich | `https://photos.<domain>` | Kanidm OIDC | user row is created on first successful OIDC login | `immich-admin` is the intended admin group; promotion may still require app-local follow-up |
| Paperless | `https://paperless.<domain>` | Kanidm OIDC | user row is created or linked on first successful OIDC login, then auto-bound to the local `Users` group for dashboard/UI-settings/saved-view permissions | `paperless-admin` is the intended admin group; keep one local recovery superuser |
| Audiobookshelf | `https://audiobooks.<domain>` | Kanidm OIDC | user row is created or linked on first successful OIDC login | `audiobookshelf-admin` is the intended admin group; keep root bootstrap as break-glass |
| Kavita | `https://books.<domain>` | Kanidm OIDC | fresh databases still require one local admin bootstrap; OIDC is enabled in startup config and synced into Kavita's DB-backed settings, but app-local roles remain authoritative on the current package | `kavita-admin` is admin intent only; promote locally in Kavita |
| Jellyfin | `https://videos.<domain>` | local app auth | local users only | local admin only |
| Jellyseerr | `https://jellyseerr.<domain>` | Jellyfin-backed auth | bootstrap through Jellyfin | local/Jellyfin-backed admin |

## Portal branding

The apps listing is now intentionally branded with clearer service names:

- `Photos`
- `Documents`
- `Audiobooks`
- `Books`
- `Files`
- `Mail Archive`

The branding is applied by `kanidm-branding.service` after Kanidm starts, using
repo-managed assets under `modules/kanidm/assets/`.

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

The important distinction is:

- person exists in Kanidm: they are in `users`
- person may log into an app: they are in that app's login group
- person should administer an app: they are in that app's admin group

Do not collapse those three layers together.

Mail archive access is a separate utility capability:

- the only required app-access group is `mail-archive-users`
- `fileshare_users` is not required for the mail archive UI
- mailbox connections are created in the browser UI at `https://emails.<domain>`
- downloaded mail is stored under the app-owned archive root, not under the fileshare workspace tree

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

# Mail archive UI
kanidm group add-members mail-archive-users "$NEW_USER" --url "$KANIDM_URL" --name "$ADMIN_USER"

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
- `mail-archive-users` is intentionally separate from `fileshare_users`; add
  only the group the user actually needs.
- `admindsaw` is the intended privileged operator identity.
- `dsaw` is the intended normal daily-use identity.
- Jellyfin and Jellyseerr remain local-auth exceptions in the current stack.
- Immich, Paperless, and Audiobookshelf may still require one local recovery
  admin or one-time admin promotion step even when Kanidm handles login.
- OIDC clients are provisioned by Nix config; avoid manual drift in the Kanidm
  UI.
- the Kanidm web UI is not the full admin experience; use `kanidm-user-tui`
  or the CLI for reliable user and group management

## Validation and app follow-up

Use [Runtime Validation](./runtime-validation.md) to verify:

- denial for users outside app groups
- first-login behavior for each app
- which apps still require a local recovery admin or a one-time app-local
  promotion

## Easier interactive admin

Run `kanidm-user-tui` on the server.

Full CLI examples: [Kanidm CLI Reference](./kanidm_cli.md).

## Session grace

The repo applies a default Kanidm auth-session policy to `idm_all_persons`
after startup. The current value comes from `kanidmAuthSessionExpirySeconds` in
[`vars.nix`](/home/dsaw/Projects/NixOS/vars.nix), which is intended to make
same-device browser sign-in less TOTP-heavy without lowering the MFA minimum.
