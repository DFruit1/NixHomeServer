# Mail Archive UI

This app provides the private `emails.<domain>` control plane for mailbox
configuration, sync, and metadata-only search.

## Operator Notes

Access model:
- `mail-archive-users` gates browser access
- the UI is private-only
- users should reach `https://emails.<domain>` over NetBird or on the LAN through the split-DNS path

Storage model:
- app state and the app-local encryption key live under `/persist/appdata/mail-archive-ui`
- downloaded mail lives under `/mnt/data/users/<user>/emails/accounts/<account-id>/`
- mailbox credentials are not stored in agenix
- temporary sync material lives only under `/run/mail-archive-ui`

Operational checks:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz | jq .
```

Functional scope:
- stores mailbox credentials encrypted at rest
- generates `mbsync` config on demand
- updates or repairs per-account `notmuch` indexes
- optionally extracts qualifying document attachments and hands them to Paperless through the filesystem consume flow
- indexes supported document attachment text for search, including `pdf`, `doc`, `docx`, `odt`, `rtf`, and `text/plain`
- exposes metadata-only search results
- supports mailbox edit, schedule toggle, manual sync, and reindex actions
- persists per-user search defaults for query and mailbox filter
- is intentionally not a webmail frontend

Health behavior:
- `/healthz` returns JSON
- `200 OK` means the DB, writable runtime paths, store root, and tool discovery checks passed
- `503` means the app is degraded before mailbox traffic is attempted

Paperless filing model:
- filing stays opt-in per mailbox through the UI checkbox
- the first run after enabling Paperless filing backfills already-downloaded mail for that mailbox
- later runs only inspect messages that have not been marked with the internal `paperless-reviewed` notmuch tag
- extracted attachments are deduplicated by SHA-256 before they are moved into `Paperless` under `documents/inbox/mail-archive/`
- internal `paperless-*` notmuch tags are hidden from the search UI

## Development

Common commands from the repo root:

```bash
nix develop .#mail-archive-ui
cargo fmt
cargo clippy --all-targets -- -D warnings
cargo nextest run
cargo run
```

CLI sync mode:

```bash
cargo run -- sync-due
```

Repo validation:

```bash
nix flake check --no-build
scripts/check-repo.sh
```

`scripts/check-repo.sh` now builds and runs the packaged mail UI test derivation in addition to the shell policy suite.
