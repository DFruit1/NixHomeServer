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
- downloaded mail lives under `/mnt/data/mail-archive/users/<user>/accounts/<account-id>/`
- mailbox credentials are not stored in agenix
- temporary sync material lives only under `/run/mail-archive-ui`

Operational checks:

```bash
systemctl status mail-archive-ui mail-archive-oauth2-proxy mail-archive-sync.timer
sudo systemctl start mail-archive-sync.service
curl -fsS http://127.0.0.1:9011/healthz
```

Functional scope:
- stores mailbox credentials encrypted at rest
- generates `mbsync` config on demand
- updates per-account `notmuch` indexes
- exposes metadata-only search results
- is intentionally not a webmail frontend

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
