These fixtures reproduce observed capture fidelity and profile-isolation failures.
All content, cookies and storage are synthetic; no credentials are required.
Python uses the pinned crawler image's existing standard-library HTTP server,
so the backend and production runtime gain no dependencies.

Mount this directory read-only at `/archive-test-fixtures` and an empty task
scratch directory at `/crawls`. With an already cached, approved image, run:

```sh
podman run --pull=never --rm --network=none --shm-size=1g \
  -v "$PWD/tests/fixtures:/archive-test-fixtures:ro" \
  -v "$TASK_SCRATCH:/crawls" \
  --entrypoint=/bin/bash \
  docker.io/webrecorder/browsertrix-crawler:1.14.3@sha256:7f9d5e20e0f6efea2e9e257aa37e536495ac9f33422ab886e446dabf1065af2c \
  /archive-test-fixtures/run-capture.sh
```

Run from the app directory with an absolute `$TASK_SCRATCH`. The HTTP server
exists only inside the network-isolated capture container and stops afterward.
The generated WACZ has three HTML pages, including a deep extensionless route,
a warm-captured JSON API, a valid favicon, and menu/tab panels initially hidden.
The ad response is generated from a short repeated string. No generated archives,
screenshots, browser state or other bulk artifacts belong in Git.

Pass the generated WACZ plus an isolated Podman wrapper to the explicit ignored
`worker_browser_qa_observes_offline_replay_in_pinned_runtime` test through
`WEB_ARCHIVES_FIXTURE`, `WEB_ARCHIVES_PODMAN`, `WEB_ARCHIVES_IMAGE` and optionally
`WEB_ARCHIVES_QA_ALL=1`, `WEB_ARCHIVES_EXPECT_RESOURCES=pass`. QA runs with
`--network=none`; the original fixture server is no longer available.

`profile_browser` uses `create-profile.mjs` to create Alice/Bob synthetic persistent
cookies and local storage with the image's own Puppeteer and Chromium. Its
`profile-capture-wrapper.py` maps the checked public test host to a server inside
that same `--network=none` container. This is test-only fixture injection;
production URL and egress validation are unchanged. It verifies sequential
Alice/Bob/unprofiled captures and queued revocation/expiry rejection. Run only
with the approved isolated runtime via `WEB_ARCHIVES_PODMAN` and
`WEB_ARCHIVES_IMAGE`, with `TMPDIR` inside the task scratch directory.

The ignored `capture_resume` test uses `WEB_ARCHIVES_BASE_PODMAN` for that same
wrapper and `WEB_ARCHIVES_FIXTURE_MODE=site`. It creates an actual native
one-page partial capture, extends its page budget by two, resumes the retained
native YAML/WARCs, and checks the complete three-page version plus unchanged
partial-file hash and immutable parent identity. Both capture attempts use fresh
browser state. Private PID namespaces ensure image Redis/browser descendants
exit with the container; do not add `--pid=host` to these checks.

`measured_stored_forecast_accounts_for_assets_and_unattributed_overhead` accepts
the same real WACZ fixture without needing a browser runtime. It checks that
stored assets and uncertain unattributed/package overhead are represented in a
bounded forecast. Set `WEB_ARCHIVES_OMIT_FAVICON=1` and
`WEB_ARCHIVES_EXPECT_RESOURCES=fail` on the QA test to retain the negative
missing-resource case; it must remain distinct from a captured HTTP 404.
