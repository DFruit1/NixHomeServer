# Kanidm CLI Reference

This file is a practical command reference for day-to-day Kanidm user
administration on this server.

For an interactive terminal workflow on the server itself, you can also run:

```bash
kanidm-user-tui
```

That wrapper launches [`scripts/kanidm-create-user.sh`](/home/dsaw/Projects/NixOS/scripts/kanidm-create-user.sh),
which now provides a `whiptail`-based guided UI with:

- a main menu ordered around the normal workflow
- an automatic prompt to authenticate when an action needs a Kanidm CLI session
- an automatic prompt to reauthenticate when a privileged admin action needs it
- an explicit typed confirmation before a user is created
- automatic clearing of validity restrictions so new users do not expire by default

It also supports:

- authenticating the Kanidm CLI session
- checking whether the current admin CLI session is still valid
- creating users
- listing users in a readable table
- inspecting users, including validity dates and managed access groups
- creating a password reset token for a selected user

Use the password reset action when an account exists but cannot log in because it
has no credential yet. The generated token can be given to the user so they can
set or replace their password.

The TUI reads these defaults from `vars.nix`:

- `kanidmAdminUser`
- `kanidmAdminEmail`
- `kanidmBaseUrl`

It is written to be safe to copy and edit:

- every mutating command uses placeholder values such as `__SET_ACCOUNT_ID__`
- the helper guards below abort immediately if any placeholder is still present
- if you paste the blocks unchanged, they should stop before modifying state

These examples assume:

- the Kanidm server is `https://id.<domain>`
- you are using your delegated admin person account, normally `admindsaw`
- you have already added that person to `idm_admins`
- you are running Kanidm CLI `1.9`

## 1. Start a safe admin shell

```bash
nix shell nixpkgs#kanidm_1_9 --impure

SERVER_URL='https://id.<domain>'
ADMIN_NAME='__SET_ADMIN_ACCOUNT__'
ACCOUNT_ID='__SET_ACCOUNT_ID__'
DISPLAY_NAME='__SET_DISPLAY_NAME__'
PRIMARY_EMAIL='__SET_PRIMARY_EMAIL__'
GROUP_NAME='__SET_GROUP_NAME__'
RFC3339_TIME='__SET_RFC3339_TIME__'

require_replaced() {
  case "$1" in
    ''|__SET_*)
      echo "Replace all __SET_* placeholders before running this command."
      return 1
      ;;
  esac
}
```

What each placeholder means:

- `ADMIN_NAME`: the Kanidm person you log in as
- `ACCOUNT_ID`: the Kanidm username for the person you are managing, for example
  `alice`
- `DISPLAY_NAME`: the human-readable name shown in the UI, for example
  `Alice Example`
- `PRIMARY_EMAIL`: the primary email address for that person
- `GROUP_NAME`: a Kanidm group such as `users`, `immich-users`,
  `paperless-users`, `audiobookshelf-users`, `fileshare_users`, or
  `idm_admins`
- `RFC3339_TIME`: a timestamp like `2026-04-12T17:30:00+10:00`

## 2. Log in and elevate privileges

```bash
require_replaced "$ADMIN_NAME" &&
kanidm login --url "$SERVER_URL" --name "$ADMIN_NAME"

require_replaced "$ADMIN_NAME" &&
kanidm reauth --url "$SERVER_URL" --name "$ADMIN_NAME"
```

How this works:

- `kanidm login` creates your local CLI session
- `kanidm reauth` performs privileged reauthentication for sensitive admin
  operations such as managing people and groups
- if the browser admin UI looks read-only, this CLI path is the reliable admin
  workflow

## 3. Read-only inspection

List all people:

```bash
kanidm person list --url "$SERVER_URL" --name "$ADMIN_NAME"
```

Search by username fragment or display-name fragment:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person search "$ACCOUNT_ID" --url "$SERVER_URL" --name "$ADMIN_NAME"
```

Show one person in detail:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person get "$ACCOUNT_ID" --url "$SERVER_URL" --name "$ADMIN_NAME"
```

Show a group's current membership:

```bash
require_replaced "$GROUP_NAME" &&
kanidm group list-members "$GROUP_NAME" --url "$SERVER_URL" --name "$ADMIN_NAME"
```

## 4. Create a new user

```bash
require_replaced "$ACCOUNT_ID" &&
require_replaced "$DISPLAY_NAME" &&
kanidm person create "$ACCOUNT_ID" "$DISPLAY_NAME" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Then add their primary email:

```bash
require_replaced "$ACCOUNT_ID" &&
require_replaced "$PRIMARY_EMAIL" &&
kanidm person update "$ACCOUNT_ID" \
  --mail "$PRIMARY_EMAIL" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Typical baseline follow-up group assignment:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm group add-members users "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Optional private files access:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm group add-members fileshare_users "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Optional delegated directory admin rights:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm group add-members idm_admins "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Per-app access grants:

```bash
require_replaced "$ACCOUNT_ID" &&
for group in \
  immich-users \
  paperless-users \
  audiobookshelf-users \
  kavita-login
do
  kanidm group add-members "$group" "$ACCOUNT_ID" \
    --url "$SERVER_URL" \
    --name "$ADMIN_NAME"
done
```

Per-app admin grants:

```bash
require_replaced "$ACCOUNT_ID" &&
for group in \
  immich-admin \
  paperless-admin \
  audiobookshelf-admin \
  kavita-admin
do
  kanidm group add-members "$group" "$ACCOUNT_ID" \
    --url "$SERVER_URL" \
    --name "$ADMIN_NAME"
done
```

What to expect:

- creating a Kanidm person does not pre-create users inside Immich, Paperless,
  or other apps
- app-side user rows are usually created or linked on first successful OIDC
  login
- `users` is only the baseline identity group in this stack
- app access is granted by app-specific groups such as `immich-users`,
  `paperless-users`, `audiobookshelf-users`, `kavita-login`, and
  `fileshare_users`
- `fileshare_users` controls access through `oauth2-proxy` on
  `files.<domain>`

## 5. Update an existing user

Change username:

```bash
require_replaced "$ACCOUNT_ID" &&
NEW_ACCOUNT_ID='__SET_NEW_ACCOUNT_ID__' &&
require_replaced "$NEW_ACCOUNT_ID" &&
kanidm person update "$ACCOUNT_ID" \
  --newname "$NEW_ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Change display name:

```bash
require_replaced "$ACCOUNT_ID" &&
require_replaced "$DISPLAY_NAME" &&
kanidm person update "$ACCOUNT_ID" \
  --displayname "$DISPLAY_NAME" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Change primary email:

```bash
require_replaced "$ACCOUNT_ID" &&
require_replaced "$PRIMARY_EMAIL" &&
kanidm person update "$ACCOUNT_ID" \
  --mail "$PRIMARY_EMAIL" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Notes:

- `--mail` sets the listed addresses for the person
- the first email you pass is the primary email
- renaming the Kanidm username changes the value many OIDC clients see as the
  preferred username

## 6. Add or remove group membership

Add a user to a group:

```bash
require_replaced "$GROUP_NAME" &&
require_replaced "$ACCOUNT_ID" &&
kanidm group add-members "$GROUP_NAME" "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Remove a user from a group:

```bash
require_replaced "$GROUP_NAME" &&
require_replaced "$ACCOUNT_ID" &&
kanidm group remove-members "$GROUP_NAME" "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Useful groups in this repo:

- `users`: baseline identity only
- `immich-users` / `immich-admin`: Immich login and intended admin access
- `paperless-users` / `paperless-admin`: Paperless login and intended admin access
- `audiobookshelf-users` / `audiobookshelf-admin`: Audiobookshelf login and intended admin access
- `kavita-login` / `kavita-admin`: Kavita login and admin role mapping
- `fileshare_users`: access through public files OAuth2 Proxy
- `idm_admins`: delegated people/group admin

## 7. Let a user set or reset their own password

Generate a reset token:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person credential create-reset-token "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

With explicit short expiry, for example 15 minutes:

```bash
require_replaced "$ACCOUNT_ID" &&
RESET_TOKEN_TTL_SECONDS='900' &&
kanidm person credential create-reset-token "$ACCOUNT_ID" "$RESET_TOKEN_TTL_SECONDS" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

How this works:

- Kanidm prints a reset token or URL
- give that to the user through a channel you trust
- the user then chooses their own password

## 8. Temporarily disable or re-enable a user

Show the current validity window:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person validity show "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Expire immediately:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person validity expire-at "$ACCOUNT_ID" now \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Clear the expiry to re-enable:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person validity expire-at "$ACCOUNT_ID" clear \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Set a future start time:

```bash
require_replaced "$ACCOUNT_ID" &&
require_replaced "$RFC3339_TIME" &&
kanidm person validity begin-from "$ACCOUNT_ID" "$RFC3339_TIME" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Clear the start restriction:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person validity begin-from "$ACCOUNT_ID" clear \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

## 9. Delete a user

Read the user first:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person get "$ACCOUNT_ID" --url "$SERVER_URL" --name "$ADMIN_NAME"
```

Then delete:

```bash
require_replaced "$ACCOUNT_ID" &&
kanidm person delete "$ACCOUNT_ID" \
  --url "$SERVER_URL" \
  --name "$ADMIN_NAME"
```

Be careful:

- this deletes the Kanidm person itself
- any app accounts previously created through OIDC may still exist in those app
  databases until removed there as well
- if the user only needs to lose access temporarily, use account expiry instead
  of deletion

## 10. Practical examples

Create a normal user for private apps only:

```bash
ADMIN_NAME='__SET_ADMIN_ACCOUNT__'
ACCOUNT_ID='alice'
DISPLAY_NAME='Alice Example'
PRIMARY_EMAIL='alice@example.com'

require_replaced "$ADMIN_NAME" &&
require_replaced "$ACCOUNT_ID" &&
require_replaced "$DISPLAY_NAME" &&
require_replaced "$PRIMARY_EMAIL" &&
kanidm person create "$ACCOUNT_ID" "$DISPLAY_NAME" --url "$SERVER_URL" --name "$ADMIN_NAME" &&
kanidm person update "$ACCOUNT_ID" --mail "$PRIMARY_EMAIL" --url "$SERVER_URL" --name "$ADMIN_NAME" &&
kanidm group add-members users "$ACCOUNT_ID" --url "$SERVER_URL" --name "$ADMIN_NAME"
```

Create a user who should also access files:

```bash
ADMIN_NAME='__SET_ADMIN_ACCOUNT__'
ACCOUNT_ID='bob'
DISPLAY_NAME='Bob Example'
PRIMARY_EMAIL='bob@example.com'

require_replaced "$ADMIN_NAME" &&
require_replaced "$ACCOUNT_ID" &&
require_replaced "$DISPLAY_NAME" &&
require_replaced "$PRIMARY_EMAIL" &&
kanidm person create "$ACCOUNT_ID" "$DISPLAY_NAME" --url "$SERVER_URL" --name "$ADMIN_NAME" &&
kanidm person update "$ACCOUNT_ID" --mail "$PRIMARY_EMAIL" --url "$SERVER_URL" --name "$ADMIN_NAME" &&
kanidm group add-members users "$ACCOUNT_ID" --url "$SERVER_URL" --name "$ADMIN_NAME" &&
kanidm group add-members fileshare_users "$ACCOUNT_ID" --url "$SERVER_URL" --name "$ADMIN_NAME"
```
