# Custom App Development

This repo has two browser custom app surfaces:

- `mail-archive-ui`: Rust/Axum server-rendered pages with Qwik islands for browser interactivity.
- `youtube-downloader`: Qwik/Vite client app with a Node server.

## Server Build Cache

The server's bounded Nix post-build hook uploads newly built outputs to the
loopback-only `nixhomeserver` Attic cache. The cache skips paths already signed
by `cache.nixos.org`, so it concentrates on custom applications and other
outputs that are not available from the upstream cache. Guarded deploys using
the default remote build mode benefit automatically on later builds.

Inspect the initialized cache and service:

```bash
sudo env XDG_CONFIG_HOME=/run/attic-client attic cache info nixhomeserver
systemctl status atticd.service attic-cache-bootstrap.service
journalctl -u atticd.service -n 100 --no-pager
```

Workstations can use the same bounded post-build approach through an SSH
tunnel, as documented in the operations guide, without publishing the cache on
the LAN or keeping a store watcher resident.

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
`youtube-downloader` with `fetchPnpmDeps`, and `mail-archive-ui` follows that
same reproducible path.

For NixOS 26.05 and newer, do not use `node2nix`, `pkgs.nodePackages`, or
Corepack-dependent builds for new custom apps. Package pnpm projects with
top-level `fetchPnpmDeps`, `pnpmConfigHook`, and an explicit `pnpm` entry in
`nativeBuildInputs`. The default `nodejs` package is Node 24 LTS, so pin a
specific `nodejs_*` only when upstream cannot run on Node 24.

Do not add Bun unless a future app has a specific Bun-only requirement.
