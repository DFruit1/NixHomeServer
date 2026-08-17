# Paperless-ngx v3 Migration Readiness

Paperless-ngx 3.0.0 was released upstream on 22 July 2026. The repository's
pinned `nixpkgs-unstable` revision now offers a 3.x candidate (currently 3.0.5),
while the production host deliberately remains on the stable 2.20.15 package
and its v2 configuration until the migration is explicitly scheduled and its
operator checks can be observed.

The dormant v3 profile lives in `modules/paperless/v3.nix`. Do not bypass its
version assertion with a hand-built package. Confirm the pinned candidate
before scheduling the migration:

```bash
nix flake update nixpkgs-unstable
nix eval --raw \
  .#nixosConfigurations.server.config.repo.paperless.v3.candidateVersion
```

The output must be `3.x`. The actual migration is still enabled explicitly:

```nix
repo.paperless.v3.enable = true;
```

Until that option is set, Paperless continues to use the stable package and the
v2 consumer settings. Merely updating the unstable input cannot migrate the
database.

## What The Guarded Switch Does

Before the v3 package can run migrations, `paperless-v3-preflight.service`:

1. Requires the installed `src-version` to be exactly `2.20.15`.
2. Runs SQLite's full integrity check.
3. Refuses migration if the legacy database reports any GPG-encrypted
   documents.
4. Creates and verifies
   `/var/lib/paperless/v3-migration-preflight/paperless-v2.20.15.sqlite3`.

The existing Paperless exporter, Kopia application-state backup, data-pool
snapshot, and `/var/lib/paperless` persistence remain in place. The preflight
database is included in the existing application-state backup.

After the NixOS Paperless unit applies Django migrations,
`paperless-v3-post-migrate.service` runs:

```text
paperless-manage document_index reindex --if-needed
paperless-manage document_sanity_checker
```

This handles the incompatible Whoosh-to-Tantivy index migration and validates
document/media references before the consumer, task queue, and web service
start.

The v3 configuration also:

- Replaces the v2 watcher options with `CONSUMER_STABILITY_DELAY` and
  `CONSUMER_POLLING_INTERVAL`.
- Converts the Office-document ignore list from globs to a Python regular
  expression.
- Keeps the pre-v3 duplicate rejection behavior.
- Makes OCR and archive-file behavior explicit.
- Generates a persistent Paperless signing key only when the v3 profile is
  enabled.
- Uses the v3 OpenID Connect token authentication setting and invalidates the
  v3 database cache after the repository's direct permission reconciliations.

Upstream clears the old task history during the v3 database migration. Saved
views with explicit `note:` and `custom_field:` searches are migrated, but
unqualified searches that happened to match notes or custom fields must be
reviewed manually.

## Bonsai AI Configuration

The v3 profile prepares Paperless AI to use:

```text
backend:  openai-like
endpoint: http://127.0.0.1:8086/v1
model:    bonsai-ternary-27b
context:  8192
timeout:  600 seconds
```

Paperless AI suggestions send OCR text to Bonsai and can propose titles, tags,
correspondents, document types, storage paths, and dates. In v3 these
suggestions are requested and reviewed by a user; they do not automatically
apply themselves during document consumption.

Document chat, similar-document retrieval, and RAG require a separate embedding
model. They remain off initially to avoid an unreviewed model download and index
build. Enable the local Paperless-managed embedding model after the basic
upgrade and Bonsai suggestions pass:

```nix
repo.paperless.v3.ai.localEmbeddings = true;
```

This selects `sentence-transformers/all-MiniLM-L6-v2` and stores its cache below
the persisted Paperless data directory.

## Migration Test Sequence

Before enabling v3:

```bash
sudo systemctl start paperless-exporter.service
sudo systemctl status paperless-exporter.service
sudo systemctl start paperless-stale-reference-check.service
sudo journalctl -u paperless-stale-reference-check.service -n 100 --no-pager
```

After the guarded switch:

```bash
sudo systemctl status \
  paperless-v3-preflight.service \
  paperless-scheduler.service \
  paperless-v3-post-migrate.service \
  paperless-web.service
sudo journalctl -u 'paperless-*' --since today --no-pager
curl --fail http://127.0.0.1:8000/api/
```

Then verify OIDC login, several representative saved searches, a normal PDF
consume, duplicate rejection, one AI suggestion, and an exporter run. Keep the
preflight SQLite snapshot and Kopia snapshot until those checks pass.
