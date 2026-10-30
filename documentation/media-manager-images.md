# Images in Media Manager

Media Manager's **Images** page browses the connected user's Immich timeline.
Immich remains the owner of every image and tag association. The integration
uses the supported Immich API, with no direct database, original-file, EXIF or
sidecar writes. Archived, trashed and locked photos are excluded.

## Connect and use

1. In Immich, open User settings → API keys and create a key named Media Manager.
   Grant `asset.read`, `asset.view`, `user.read`, `tag.read`, `tag.create` and
   `tag.asset`. Each person should use their own key and retain a recovery copy
   in their password manager. Original-download and deletion scopes are unused.
2. In Media Manager → Metadata sources → Immich, save the key and test it.
   The existing provider broker encrypts the key for that authenticated subject;
   saved values cannot be read back in the browser.
3. Open **Images**, browse or search by filename, and choose a photo. **Load more
   photos** retrieves another bounded page rather than loading the whole library.
4. Choose **Analyze photo**, review EYE's tag suggestions and relative aesthetic,
   keeper and cover scores, then select up to 32 tags and add them to Immich.
   The predictions use Immich's preview, not the full-resolution original.

Adding tags requires Media Manager editor access, enabled mutations, and
permission to modify the asset in Immich. Tags are added under `EYE/` through
Immich's upsert and bulk-tag APIs. Existing tags are retained, and retries are
idempotent. **Refresh tags** reads the current state from Immich after another
client changes it or a request fails partway through. Analysis is shown for the
current selection; it is not a background library scan or a persisted score index.

## Runtime and boundaries

The catalog integration is imported only with Immich enabled. Disabling Immich
removes this integration and the EYE services, retaining all downloaded weights.
The Images page then reports that its integration is unavailable.

Rust owns the authenticated API and talks to the fixed, configuration-owned
loopback Immich endpoint. Redirects are refused, responses and previews are
bounded, and neither upstream filesystem paths nor secret values are returned.
No new public route, host, credential manifest entry or storage mount is added.

The small Node helper is intentional: Desert Ant's official EYE SDK provides its
native Linux LiteRT implementation through Node, Swift and Kotlin, without a Rust
SDK. The Rust broker sends only preview bytes over
`/run/media-manager-eye/eye.sock`; Immich credentials never cross that socket.
The helper accepts one analysis at a time, rejects concurrent work for retry,
limits image bytes and decoded dimensions, and has a 3 GiB memory ceiling. Its
private cache is disposable. Photo inference runs locally; the SDK retains its
upstream licensing behavior. No photos are sent to a cloud inference provider.

The npm dependency graph is locked and the EYE SDK is pinned to `4.2.3`. The
model-prepare unit verifies SHA-256 hashes for `eye.tflite` and `eye_meta.json`
from the immutable model revision `22f84595225252153fc8e11e7f5fba152fe13718`.
Weights and the SDK's offline manifest live under `${dataRoot}/eye/models`.
Inference reads these files; only preparation may replace downloaded artifacts.

Inspect the affected units after an authorized deployment:

```bash
systemctl status media-manager-provider-broker media-manager-eye-model-prepare media-manager-eye
journalctl -u media-manager-eye -u media-manager-provider-broker -n 50 --no-pager
```

An `immich_tags_added` event records the request ID and tag count, without photo
contents, filenames, tags or API keys. If EYE is unavailable, normal photo
browsing and other metadata providers remain available.

The focused boundary regressions in `tests/immich_images.rs` address the concrete
risk of private-photo or credential disclosure: subject isolation, redirection,
credentials excluded from EYE, same-origin/editor/read-only write gates, and
additive tag updates. UI work uses existing checks and direct rendered checks.

## Upstream contracts

- [Immich 3.1 API contract](https://github.com/immich-app/immich/blob/v3.1.0/open-api/immich-openapi-specs.json)
- [Immich tag operations](https://github.com/immich-app/immich/blob/v3.1.0/server/src/services/tag.service.ts)
- [EYE SDK usage and scores](https://desertant.com/docs/eye/)
- [EYE SDK model pin](https://github.com/Desert-Ant-Labs/desert-ant-core/blob/v4.2.3/Sources/Eye/Catalog.swift)
- [Desert Ant model/SDK license](https://license.desertant.com/)
