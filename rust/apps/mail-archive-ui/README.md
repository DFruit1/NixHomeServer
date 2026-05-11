# Mail Archive UI

This app provides the private `emails.<domain>` control plane for mailbox
configuration, sync, and metadata-only search.

## Operator Notes

Access model:
- `mail-archive-users` gates browser access
- the UI is private-only
- users should reach `https://emails.<domain>` over NetBird or on the LAN through the split-DNS path

Storage model:
- global app state and the app-local encryption key live under `/persist/appdata/mail-archive-ui`
- per-account derived sync and indexing state lives under `/persist/appdata/mail-archive-ui/accounts/<user>/<account-id>/`
- downloaded mail payload lives under `/mnt/data/users/<user>/emails/.internal-sync/<account-hidden-root>/maildir/`
- the user-visible mailbox mirror lives under `/mnt/data/users/<user>/emails/<account-slug>-<mailbox-slug>/YYYY/MM/*.eml`
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
- keeps mailbox payload portable by separating downloaded mail from derived sync and index state
- lets users search, select, and bulk-download archived attachments as a ZIP
- indexes supported document attachment text for search, including `pdf`, `doc`, `docx`, `odt`, `rtf`, and `text/plain`
- exposes metadata-only search results
- supports mailbox edit, schedule toggle, manual sync, and reindex actions
- persists per-user search defaults for query and mailbox filter
- is intentionally not a webmail frontend

Health behavior:
- `/healthz` returns JSON
- `200 OK` means the DB, writable runtime paths, store root, and tool discovery checks passed
- `503` means the app is degraded before mailbox traffic is attempted

Attachment download model:
- `/attachments` searches the indexed attachment catalog and supports per-row selection, page-visible selection, and server-side download of all matching filters
- selected attachments are downloaded as a browser ZIP; no attachment action state is recorded
- local delete/restore tombstones remain available for mail archive maintenance
- downstream document filing is manual and happens outside this app

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
scripts/validate-repo.sh
scripts/validate-repo.sh --full
```

Use `scripts/validate-repo.sh --full` when you want the local validation gate to build and run the packaged `mail-archive-ui-test` derivation in addition to the shell policy suite.
