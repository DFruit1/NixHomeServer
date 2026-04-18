# Mail Archive UI

This app provides the private `emails.<domain>` control plane for mailbox
configuration, sync, and search.

It is intentionally not a webmail frontend. The UI:

- stores mailbox credentials encrypted at rest
- generates `mbsync` config on demand
- updates per-account `notmuch` indexes
- exposes metadata-only search results

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
