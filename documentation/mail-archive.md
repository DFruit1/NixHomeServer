# Mail Archive

This feature provides private mailbox sync and metadata-only search through:

- `mbsync` for IMAP download
- `notmuch` for local indexing and query
- `https://emails.<domain>` as the browser UI

It is designed for:

- regularly pulling mail from providers such as Gmail over IMAP
- retaining local Maildir-backed message files even if you later leave the provider
- searching historical mail without turning this server into webmail

It is not designed for:

- realtime sync
- provider OAuth token brokerage
- public internet exposure
- in-browser message-body rendering

## Access model

The mail archive feature is opt-in.

Required Kanidm group:

- `mail-archive-users`

Grant access with:

```bash
export KANIDM_URL='https://id.<domain>'
export ADMIN_USER='<delegated-admin-user>'
export ACCOUNT_ID='<account-id>'

kanidm group add-members mail-archive-users "$ACCOUNT_ID" --url "$KANIDM_URL" --name "$ADMIN_USER"
```

The UI is private-only. Users must reach `https://emails.<domain>` over
NetBird, or on the LAN when split-horizon DNS is enabled.

## What the UI does

After login, a user can:

- add multiple mailbox connections
- choose a Gmail preset or generic IMAP
- store the mailbox password or app password encrypted at rest
- run an immediate sync
- search local indexed mail through `notmuch`

The frontend is server-rendered HTML. It is intentionally a control plane and
search surface, not a full mail client.

## Mailbox presets

Supported presets:

- Gmail
  - host `imap.gmail.com`
  - port `993`
  - append-only default archive folders
- Generic IMAP
  - operator-supplied host and username
  - port `993`
  - editable folder patterns

Authentication in this phase is app password or IMAP password only. There is no
built-in provider OAuth2 token broker.

## On-disk layout

App-owned state:

```text
/mnt/data/appdata/mail-archive-ui
```

This contains:

- sqlite metadata
- the app-local encryption key
- sync locks

Downloaded mail:

```text
/mnt/data/mail-archive/users/<user>/accounts/<account-id>/
```

Per account:

- `maildir/`
- `state/notmuch-config`
- `state/mbsync-state/`

This data is intentionally outside the Copyparty and SMB-exposed workspace
paths.

## Secret handling

Mailbox credentials are not stored in agenix.

Instead:

- the UI encrypts them before writing them to sqlite
- the app-local master key lives under `/mnt/data/appdata/mail-archive-ui`
- sync writes a temporary secret file only under `/run/mail-archive-ui`
- temporary sync secrets are removed immediately after use

This keeps mailbox secrets in runtime/app state, not in repo-managed Nix
configuration.

## Sync behavior

- manual sync runs from the browser and blocks until completion or failure
- scheduled sync runs through `mail-archive-sync.timer`
- per-account locks prevent overlapping syncs
- each sync generates `mbsync` config on demand and then runs `notmuch new`

The retention model remains append-only:

- new mail is pulled locally
- flag updates are indexed locally
- remote deletions are not propagated into the local Maildir copy

That means the local archive remains useful even after provider cleanup or
account closure.

## Search behavior

Search runs through `notmuch` and returns metadata only:

- mailbox name
- date
- sender
- subject
- tags

Message bodies are not rendered in the browser in this phase.

## Operator checks

Relevant units:

- `mail-archive-ui.service`
- `mail-archive-oauth2-proxy.service`
- `mail-archive-sync.service`
- `mail-archive-sync.timer`

Useful commands:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz
```

## Backup scope note

The current restic backup-disk scaffold includes:

- `/mnt/data/appdata`

That means mail archive app state is included:

- sqlite metadata
- encrypted mailbox credentials
- the app-local encryption key

Downloaded Maildir data is not included, because it lives under:

```text
/mnt/data/mail-archive
```

So the current policy is:

- app config and encrypted credentials are backed up
- downloaded mail remains local to the server
