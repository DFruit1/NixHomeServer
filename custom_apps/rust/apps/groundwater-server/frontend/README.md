# Groundwater frontend

Qwik 1.16 CSR SPA, with the pinned mail-archive-ui toolchain and default
segment chunking. `pnpm install --frozen-lockfile` then `pnpm run check` runs
only this frontend's format, type, regression and production build checks.

Rust serves `dist/index.html` at `/` and the complete `dist/` tree from
`GROUNDWATER_FRONTEND_DIR`. Keep `/assets/*` filenames unchanged and apply
immutable caching to content-hashed assets; revalidate HTML. Routes use hashes,
so Rust does not need per-device fallback routes. Authentication and permission
enforcement stay on the API; unknown session roles expose no write controls.

`pnpm dev` proxies `/api` to `127.0.0.1:8091`. For isolated UI review, run
`node dev/fixture-api.mjs`, then
`GROUNDWATER_DEV_API=http://127.0.0.1:5188 pnpm dev` in another terminal.
Fixtures are development tooling and are never imported by production source.
`http://127.0.0.1:5188/__fixture?role=viewer&mode=normal` changes the fixture
session; modes `empty` and `error` exercise the corresponding states.

Configuration validation follows firmware `8278b61` and the server's
`commands.rs`: eleven ordered string keys, extraction simulation, 150-byte
limit, bounded intervals/integers, two-digit calibration fractions with
negative `.00` only. Fields start empty. The operator explicitly types DANGER
for project settings and danger commands. Project settings have no firmware
acknowledgement. The last full project payload is displayed separately from
historical requested toggles/received echoes. Device capabilities expose only
implemented actions (self-test and V2.x Reboot); stub toggles/wipes cannot be
queued. Full settings preserve the commissioned UTC offset because zoneless
SD records cannot establish a clock transition.

SSE uses native EventSource reconnect. Messages and `resync` schedule a refetch
after 300 ms. Active requests finish while further events coalesce into one
pending refresh; unavailable/reconnecting streams poll every 30 seconds.
Recent ranges roll on refresh; explicit ranges stay fixed. Resource requests
are aborted on selection changes and late responses are discarded.
Charts use plausible UTC device time, with local browser labels, configured
threshold bands, alert-opening markers and line breaks for missing intervals.
The table exposes exact plotted values; CSV exports underlying observations.
The header's operator-only raw-delivery view includes unattributed quarantines;
the device log links to that same view and filter implementation.

Hardware wake-window delivery, gateway roles and real ingest require the
parent's integrated backend checks; fixture rendering does not prove them.
