# Browsertrix Downloader

Browsertrix Downloader is a first-party queue and archive interface around the
published Browsertrix Crawler container. The crawler and ReplayWeb.page remain
upstream components; the Rust API, queue worker, Qwik interface, authentication
boundary, storage layout, and NixOS services are repository-owned code.

## Runtime layout

The module deliberately splits request handling from crawling:

- `browsertrix-downloader.service` serves the authenticated API, frontend, and
  WACZ byte ranges. It can write SQLite state and only read completed archives.
- `browsertrix-downloader-worker.service` claims queued jobs and launches one
  rootless Podman crawl at a time. Its separate system user owns the rootless
  container state and has an automatically allocated subordinate UID/GID range.
- `browsertrix-downloader-egress-policy.service` rejects crawler traffic to
  local, private, link-local, NetBird, multicast, documentation, and reserved
  address ranges. The crawler uses rootless `slirp4netns`, not host networking.
- `browsertrix-downloader-oauth2-proxy.service` admits members of the Kanidm
  `web-archive-users` group and supplies the trusted identity headers.

The crawler image must use an immutable `sha256` manifest digest. When updating
it, verify the published version and multi-architecture digest, update
`repo.browsertrixDownloader.crawlerImage`, and rerun the package and module
checks.

## Data and recovery

Persistent queue state and rootless container storage live under
`/var/lib/browsertrix-downloader`. Crawl scratch data lives under
`/var/cache/browsertrix-downloader` and is intentionally disposable. Completed
archives are stored in the data pool at `_Shared/_WebArchives` and remain there
if the application module is disabled or removed.

The central backup registry includes a logical SQLite dump plus the state and
WACZ payload roots. A worker restart marks only `starting`, `running`, or
`cancelling` jobs as failed; queued jobs remain available for the restarted
worker.

## Useful checks

```bash
systemctl status browsertrix-downloader browsertrix-downloader-worker
journalctl -u browsertrix-downloader -u browsertrix-downloader-worker --since today
scripts/tests/test-browsertrix-downloader-module.sh
cargo test --manifest-path custom_apps/Cargo.toml -p browsertrix-downloader
```

The worker pulls the pinned image on first start, so initial startup can take
several minutes and requires roughly 1 GB of compressed download capacity.
