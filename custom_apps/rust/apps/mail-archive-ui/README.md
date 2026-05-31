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
- downloaded mail payload lives under `/mnt/data/users/<user>/_Emails/.internal-sync/<account-hidden-root>/maildir/`
- extracted attachment blobs are materialized content-addressably under `/mnt/data/users/<user>/_Emails/.internal-sync/<account-hidden-root>/attachments/blobs/sha256/`
- the user-visible mailbox mirror lives under `/mnt/data/users/<user>/_Emails/<account-slug>-<mailbox-slug>/YYYY/MM/*.eml`
- mailbox credentials are not stored in agenix
- temporary sync material and generated browser ZIPs live only under `/run/mail-archive-ui`

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
- lets users search, filter, select, and bulk-download archived attachments as a ZIP with an included `manifest.json`
- persists extracted attachment blobs by SHA-256 so browser downloads and backups do not depend on repeated MIME extraction
- verifies source `.eml` files, attachment blobs, and catalog metadata through `mail-archive-ui verify-attachments`
- indexes supported document attachment text for search, including `pdf`, `doc`, `docx`, `odt`, `rtf`, and `text/plain`
- exposes metadata-only search results with URL query parameters for sender address, sender name, sender domain, subject, body text, date range, and attachment presence
- lets users mark sender addresses or exact sender domains as high or low priority for UI-only sorting and filtering
- supports mailbox edit, schedule toggle, manual sync, and reindex actions
- persists per-user search defaults for query and mailbox filter
- is intentionally not a webmail frontend

Health behavior:
- `/healthz` returns JSON
- `200 OK` means the DB, writable runtime paths, store root, and tool discovery checks passed
- `503` means the app is degraded before mailbox traffic is attempted

Attachment download model:
- `/attachments` searches the indexed attachment catalog and supports row selection, page-visible selection, and server-side download of all matching filters
- shared search filters use normal GET parameters: `q`, `sender_address`, `sender_name`, `sender_domain`, `subject`, `body_text`, `date_from`, `date_to`, and `has_attachments`
- attachment-specific GET parameters include `extension`, `attachment_name`, `mime_type`, `min_size`, `max_size`, `min_attachments`, and `max_attachments`
- selected attachments are downloaded as a browser ZIP streamed from runtime storage
- selected attachments can also be copied into the configured Paperless consume inbox; successful handoffs are recorded per user and attachment key
- ZIPs include `manifest.json` with source mailbox, message, filename, MIME type, size, and SHA-256 metadata for every file
- ZIP files are organized as `<optional-subfolder>/<mailbox>/<yyyy-mm-dd> - <subject>/<filename>`, with duplicate filenames written as `file (1).ext`
- original attachment filenames, including Unicode and emoji names, are preserved for browser downloads and ZIP entries except for path separators/control characters
- inline images and body fragments extracted as `textfile0`, `textfile1`, and similar artifacts are hidden by default and can be included with page filters
- attachment rows show a simple file type and message date by default; full MIME detail is optional
- Paperless handoff uses the consume directory; Paperless ownership and post-processing follow the normal Paperless consumer behavior

## Development

Common commands from the repo root:

```bash
nix develop .#ops
cargo fmt
cargo clippy --all-targets -- -D warnings
cargo nextest run
cargo run
```

Frontend commands from `custom_apps/rust/apps/mail-archive-ui/frontend`:

```bash
pnpm install
pnpm run dev
pnpm run check
```

The browser UI is Rust-rendered HTML with Qwik islands for interactive
behavior. Production deploys use the Vite build copied into the Nix package.
For hot reloading during UI work, run the Vite dev server and start Rust with:

```bash
MAIL_ARCHIVE_UI_FRONTEND_MODE=vite \
MAIL_ARCHIVE_UI_VITE_ORIGIN=http://127.0.0.1:5173 \
cargo run
```

CSS and Qwik island changes hot reload through Vite. Rust route, HTML, and API
changes still require restarting `cargo run`. `pnpm` is used to match the
existing `youtube-downloader` frontend and Nix packaging; Bun is intentionally
not part of this app.

CLI sync mode:

```bash
cargo run -- sync-due
```

CLI attachment verification:

```bash
cargo run -- verify-attachments --repair --report /tmp/mail-archive-attachments.json
```

The system-state backup preparation runs the same verifier with `--repair` and
stores the JSON report in the backup metadata directory.

Repo validation:

```bash
nix flake check --no-build
scripts/validate-repo.sh
scripts/validate-repo.sh --full
```

Use `scripts/validate-repo.sh --full` when you want the local validation gate to build and run the packaged `mail-archive-ui-test` derivation in addition to the shell policy suite.
