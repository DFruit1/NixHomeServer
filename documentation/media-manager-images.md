# Images in Media Manager

Media Manager automatically analyzes each connected user's Immich photos with
EYE and saves tags, confidence values and aesthetic, keeper and cover scores in
its own SQLite database. **Analysis, search and image files are read-only**: no
Immich tag updates, database writes, original downloads, EXIF changes or
sidecars occur in the analysis and search paths. The only Immich write is the
opt-in category question adding the assessed photo to a named album. Timeline
and archived photos are indexed; locked, hidden, trashed and non-image assets
are excluded.

## Connect and use

1. Sign into Photos with Kanidm once if your Immich account does not yet exist.
   The existing local provisioner connects your linked account within a few
   minutes. You do not need to copy an API key.
2. Background indexing starts for every connected account when the provider
   broker runs, even if the user never opens Media Manager. Open **Images** to
   see discovered/analyzed counts and any retry notice. **Refresh results** reads
   current progress. The initial pass can take time for large libraries.
3. Search by filename and/or comma-separated EYE tags, such as `beach, people`.
   Choose **All tags** or **Any tag**. Tags match their saved spelling, including
   spaces and case; EYE tags use lowercase identifiers such as `computer_screen`.
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
deletes a photo or changes Immich tags or originals based on a prediction. The
only Immich mutation is adding the assessed photo to an album named by an
enabled category question. The legacy tag-write endpoint returns 403, including
for editors with mutations enabled.

## Saved decision questions

Open **Images → Decision questions** to add and save up to 16 personal
questions and at most 24 total d1 propositions (one per yes/no question and one
per album name). A **Yes or no** question can choose **Add tag** or **Leave
unchanged** separately for Yes and No. For example, ask “Is the photo a computer
screen or code?”, add `to be deleted` for Yes, and leave No unchanged. This is a
tag only: nothing is deleted or moved.

A **Categorise into albums** question lists two to twelve unique album names and
defaults to “Based on the photo's contents and tags, which category does it
belong to?”. d1 answers once per album name using that question, and the most
probable category at 50% or higher adds the assessed photo to the Immich album
with exactly that name. The album is created in the caller's own library when it
does not exist; shared albums with the same name are never modified. No other
photo and no original file is changed. Album writes need `album.read`,
`album.create` and `albumAsset.create` on the connected Immich API key;
connected Kanidm accounts receive these with the managed key. Per-photo
insertion errors are reported even when Immich returns HTTP success. Failed
album assignments remain queued for the background sweep, preserving the saved
inference and tags; retrying does not run d1 again. Editing or removing the
question cancels obsolete pending assignments.

Each question can also set optional **EYE score bounds** for aesthetic, keeper
and cover (0–100%). The question is skipped, with the reason shown, when any set
minimum or maximum is unmet. Bounds need saved EYE analysis; assessing an Immich
photo analyzes it first when necessary, and text uploads skip bounded questions.

**Assess selected photo** uses all saved questions. For a yes/no question, Yes
means a d1 probability of at least 50%; the result shows the answer and
probability. Every successful assessment also adds `auto-tagged yyyyMMdd HH:mm`
using the server's local time, including when the chosen action is Leave
unchanged. Failed inference applies no tags. Editing an assessed question while inference
is running prevents stale actions from being applied. Tags are additive: editing or
removing a question retains previous tags, albums and timestamps. EYE reanalysis also
preserves them. Select a decision tag to filter the photo library by that tag;
confidence thresholds apply to EYE suggestions, not already-applied decision tags.

Enable **Automatically assess my photo library** on each question that should
run in the background. This defaults off. The existing library sweep assesses
new photos and changed questions once, reuses saved decisions after restart,
and retries failed assessments on subsequent sweeps. A completed library sweeps
every 30 minutes; a large initial pass can take longer. Decision failures have
separate backoff and do not stop EYE indexing. The broker logs fixed
`decision_assessment_retry` events without private contents.

**Assess another file** accepts JPEG/PNG/WebP images up to 16 MiB and UTF-8 text
up to 16 KiB, using all saved questions. PDFs, office documents and other binary
files are unsupported. A connected Photos account is currently required.
Contents go only to local d1 and are not retained. Uploads have no Immich asset,
so category questions report the chosen category without adding an album. Tags
are saved by content hash in the same private account partition; upload the same
file again to reassess and recover earlier tags. This does not alter the local
file or create sidecars. Automatic assessment currently covers the Immich photo
library only.

The official [LiquidAI/d1-2B GGUF model](https://huggingface.co/LiquidAI/d1-2B-GGUF)
and vision projector are pinned at revision
`4a181094d1b6addfaa3a0956f78e7ab2aa406a0c`. Q8_0 model weights and the F16
projector live at `${dataRoot}/media-manager-decision/models` (normally
`/mnt/data/media-manager-decision/models`), outside the system SSD and Nix store.
Preparation verifies their SHA-256 checksums and downloads only missing or
invalid artifacts. Disabling Immich retains both weights and saved metadata.
The new inference service uses the existing pinned mainline llama.cpp runtime,
CPU inference with one request at a time, a private Unix socket at
`/run/media-manager-decision/d1.sock`, a 6 GiB memory ceiling, and sleep after
five idle minutes. It exposes no browser/network host and uses no cloud API.

Rules, results, retry checkpoints, album IDs and tags live in additive
`decision_*` tables in the existing provider SQLite database and inherit its
persistence/backups. They use the same subject/origin/credential partition as
EYE. These new services are staged in configuration and start on the next
authorized config switch; editing the source or downloading weights does not
start them.

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
Pinned weights live under `${dataRoot}/eye/models`; the model loads for analysis and
is released after five idle minutes. Health probes do not keep it loaded.
Disabling Immich removes the integration and EYE services while retaining weights
and derived database state.

## Operations and validation

After an explicitly authorized deployment, inspect:

```bash
systemctl status media-manager-provider-broker media-manager-eye-model-prepare media-manager-eye media-manager-immich-provision
systemctl status media-manager-decision-model-prepare media-manager-decision
journalctl -u media-manager-eye -u media-manager-provider-broker -n 50 --no-pager
```

`image_index_retry` and `image_accounts_unavailable` log fixed diagnostics and
request IDs, without filenames, tags, subjects, photo contents or credentials.
Search returns persisted results during indexing; unavailable Immich authorization
fails closed. Other metadata providers remain independent of EYE.

Focused boundary regressions in `tests/immich_images.rs` cover private-photo and
credential disclosure, per-subject saved analysis, refusal of legacy writes, and
single-photo category album assignment with score-bound skips. Use local fixture
libraries to check full-library pagination, filtering, ranking, background
progress and restart reuse without touching a real Immich instance.

## Upstream contracts

- [Immich 3.1 API contract](https://github.com/immich-app/immich/blob/v3.1.0/open-api/immich-openapi-specs.json)
- [EYE SDK usage and scores](https://desertant.com/docs/eye/)
- [EYE SDK model pin](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.2.3/Sources/Eye/Catalog.swift)
- [Desert Ant model/SDK license](https://license.desertant.com/)
- [d1 local inference contract and supported llama.cpp version](https://huggingface.co/LiquidAI/d1-2B-GGUF/blob/4a181094d1b6addfaa3a0956f78e7ab2aa406a0c/README.md)
