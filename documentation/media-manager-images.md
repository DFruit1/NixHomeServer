# Images in Media Manager

Media Manager automatically analyzes each connected user's Immich photos with
EYE and saves tags, confidence values and aesthetic, keeper and cover scores in
its own SQLite database. **Immich and image files are read-only**: no Immich tag
updates, database writes, original downloads, EXIF changes or sidecars occur in
the analysis and search paths. Timeline and archived photos are indexed; locked,
hidden, trashed and non-image assets are excluded.

## Connect and use

1. Sign into Photos with Kanidm once if your Immich account does not yet exist.
   The existing local provisioner connects your linked account within a few
   minutes. You do not need to copy an API key.
2. Background indexing starts for every connected account when the provider
   broker runs, even if the user never opens Media Manager. Open **Images** to
   see discovered/analyzed counts and any retry notice. **Refresh results** reads
   current progress. The initial pass can take time for large libraries.
3. Search by filename and/or comma-separated EYE tags, such as `beach, people`.
   Choose **All tags** or **Any tag**; spaces within a tag become underscores.
   **Minimum scores and confidence** sets three independent score thresholds
   (0–100) and the minimum tag confidence (default 50%).
4. Sort by date taken, an individual score, tag confidence, or **Combined scores**.
   Combined ranking uses the weighted average of aesthetic, keeper and cover;
   weights default to 1 each. Set a weight to 0 to ignore that score; at least one
   must remain positive. Tag sorting uses the specified tag's confidence, treating
   an absent tag as 0. Choose ascending or descending order.
5. Sorting and filtering apply to the whole index before 48-photo pagination.
   Photos not yet analyzed appear in date order but are excluded from score/tag
   sorting and positive score/tag filters. Select a photo to inspect saved
   analysis; choose **Analyze again** to replace only its Media Manager analysis.
   Selecting a saved tag searches for that tag with the current other filters.

The **View** selector offers Detailed list, Simple list and 1–4 tiles per row.
Detailed rows show the capture date, saved scores and a short tag summary;
simple rows show filenames. Music has the same selector for albums and tracks.
The two selections are saved independently in this browser, keyed by the signed-in
account's stable ID. Other users on a shared device do not inherit your choice,
and another device/browser profile can use a different layout. Clearing site data
resets these preferences. If browser storage is blocked, the chosen view still
works for the current visit. Both pages default to three tiles per row.

Scores are relative model judgments, not personal-value decisions. The app never
deletes a photo or modifies Immich based on a prediction. The legacy tag-write
endpoint returns 403, including for editors with mutations enabled.

## Runtime, persistence and isolation

Rust owns upstream authentication, background scheduling, search and storage.
Analysis and scan checkpoints share
`/var/lib/media-manager-provider/provider-accounts.sqlite3`, already covered by
central persistence and the provider database backup. New `image_assets`,
`image_tags` and `image_scans` tables are additive; existing encrypted credentials
are unchanged. Every index partition includes the stable identity subject,
configured Immich origin and a credential fingerprint. A username reuse or
credential change cannot inherit another library's cached metadata.

The worker processes one bounded page per account per round, with serialized
inference and a brief gap between photos. Interactive reanalysis reports busy
while background inference holds the shared gate, avoiding proxy timeouts. Checkpoints survive broker restarts;
completed analysis is reused. Completed libraries rescan after 30 minutes for
new/removed photos. Individual failed photos are retried on a subsequent sweep;
service failures pause the page and retry after a minute. A completed sweep
removes stale derived records only; it cannot delete photos. A large initial
library pass can delay the next full sweep.

Every indexed result and selected-photo read is reauthorized through the user's
current Immich API access before cached metadata is returned. Deleted, locked or
trashed photos are omitted immediately from search responses; lost Photos group
membership blocks HTTP access. Cached counts describe the private index and can
lag upstream changes until a sweep completes. Credential/account removal makes
that partition inaccessible but does not erase backups or historical partitions.

The fixed loopback Immich endpoint refuses redirects. Responses and previews are
bounded. Neither upstream filesystem paths nor secret values reach the browser.
The existing credential provisioner remains separate and unchanged: it manages
least-privilege keys for linked accounts using the exact Kanidm UUID/Immich
`oauthId`, never name or email matching. Indexing never invokes provisioning or
requests an administrator credential.

The Node helper uses Desert Ant's official native Linux LiteRT SDK; the Rust
broker sends only preview bytes over `/run/media-manager-eye/eye.sock`, without
Immich credentials. The helper retains its existing memory ceiling, image/decode
bounds and request deadline. Photos are not sent to a cloud inference service.
Pinned weights live under `/data/eye/models`; the model loads for analysis and
is released after five idle minutes. Health probes do not keep it loaded.
Disabling Immich removes the integration and EYE services while retaining weights
and derived database state.

## Operations and validation

After an explicitly authorized deployment, inspect:

```bash
systemctl status media-manager-provider-broker media-manager-eye-model-prepare media-manager-eye media-manager-immich-provision
journalctl -u media-manager-eye -u media-manager-provider-broker -n 50 --no-pager
```

`image_index_retry` and `image_accounts_unavailable` log fixed diagnostics and
request IDs, without filenames, tags, subjects, photo contents or credentials.
Search returns persisted results during indexing; unavailable Immich authorization
fails closed. Other metadata providers remain independent of EYE.

Focused boundary regressions in `tests/immich_images.rs` cover private-photo and
credential disclosure, per-subject saved analysis and refusal of legacy writes.
Use local fixture libraries to check full-library pagination, filtering, ranking,
background progress and restart reuse without touching a real Immich instance.

## Upstream contracts

- [Immich 3.1 API contract](https://github.com/immich-app/immich/blob/v3.1.0/open-api/immich-openapi-specs.json)
- [EYE SDK usage and scores](https://desertant.com/docs/eye/)
- [EYE SDK model pin](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.2.3/Sources/Eye/Catalog.swift)
- [Desert Ant model/SDK license](https://license.desertant.com/)
