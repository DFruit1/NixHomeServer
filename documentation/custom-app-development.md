# Custom App Development

This repo has two browser custom app surfaces:

- `mail-archive-ui`: Rust/Axum server-rendered pages with Qwik islands for browser interactivity.
- `youtube-downloader`: Qwik/Vite client app with a Node server.

`kanidm-admin` is a terminal TUI and does not have browser hot reload.

## Mail Archive UI

Production deploys build the Qwik/Vite frontend and copy the output into the
Rust package at:

```text
$out/share/mail-archive-ui/frontend
```

The NixOS service sets:

```text
MAIL_ARCHIVE_UI_FRONTEND_MODE=production
MAIL_ARCHIVE_UI_FRONTEND_DIST_DIR=<package>/share/mail-archive-ui/frontend
```

For frontend hot reload, use two terminals.

Terminal 1:

```bash
cd custom_apps/rust/apps/mail-archive-ui/frontend
pnpm install
pnpm run dev
```

Terminal 2:

```bash
cd custom_apps/rust/apps/mail-archive-ui
MAIL_ARCHIVE_UI_FRONTEND_MODE=vite \
MAIL_ARCHIVE_UI_VITE_ORIGIN=http://127.0.0.1:5173 \
cargo run
```

Qwik island and CSS edits hot reload through Vite. Rust-rendered HTML, routes,
database behavior, and API changes still require restarting the Rust process.

Frontend checks:

```bash
cd custom_apps/rust/apps/mail-archive-ui/frontend
pnpm run check
```

Nix check:

```bash
nix build .#checks.x86_64-linux.mail-archive-ui-frontend --no-link --print-build-logs
```

## Package Manager

Use `pnpm` for custom frontend apps. The repo already packages
`youtube-downloader` with `pnpm.fetchDeps`, and `mail-archive-ui` follows that
same reproducible path. Do not add Bun unless a future app has a specific
Bun-only requirement.
