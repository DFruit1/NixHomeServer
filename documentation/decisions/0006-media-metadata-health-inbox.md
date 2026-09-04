# Bounded metadata health inbox

- Status: accepted
- Date: 2026-09-03
- Extends: [ADR 0003](0003-media-metadata-observation-and-propagation.md)

## Context

Item metadata inspection already reports missing fields, invalid chapter or
track data, and disagreements between available sources. Those findings are
only visible after a person opens an individual item, so there is no practical
way to triage an existing library or find the records that most need review.

Metadata inspection can read embedded tags and sidecars. A whole-library
request would make one HTTP request unbounded by library size and could hold a
connection open for too long. Building the queue in the browser by requesting
every item separately would instead create an avoidable N+1 API pattern and
duplicate authorization and pagination logic in the client.

## Decision

Add `GET /api/v1/metadata/issues`, scoped to one root visible to the
authenticated identity. The first request reconciles that root with the
filesystem. It then inspects at most 20 catalog positions by default and 50 at
most, using the same metadata assembly and health rules as the single-item
endpoint. Results are grouped by item and records without issues are omitted.

Pagination uses the catalog's unique relative path as a forward cursor. A
response reports both the number of supported media records inspected and the
number and severity of issues returned. When another catalog page exists, the
client passes `nextCursor` back unchanged. Continuation requests do not repeat
the filesystem reconciliation scan.

The response is private and non-cacheable. It exposes only catalog identity,
relative path, media kind, and the existing health findings; it does not expose
raw metadata previews or provider credentials. The same shared/personal root
visibility and ownership rules as the library browser apply.

The interface presents the endpoint as a review inbox. It lets the user choose
a visible root, accumulates subsequent pages on request, and links each result
to a durable `view=library&root=...&item=...` URL. The library route restores
that item in the existing editor. If the item is beyond the browser's bounded
root listing, `GET /api/v1/items/{itemId}` restores its authorization-checked
catalog record directly. All changes remain inside the established preview and
explicit-confirm workflow.

## Consequences

- Health rules have one implementation and therefore cannot drift between an
  item detail and the library queue.
- Work per HTTP request is bounded, but inspecting a large library still
  requires deliberate pagination.
- A page can contain no results even when `nextCursor` is present because
  healthy and unsupported catalog entries are intentionally omitted.
- The path cursor is stable for a catalog snapshot, but concurrent renames can
  move an item before or after the cursor. A future persisted scan job may be
  warranted if exact point-in-time reports or background scheduling are added.

## Rejected alternatives

- Inspect every library item in one synchronous request.
- Have the browser request the item metadata endpoint once per catalog record.
- Create a second, reduced set of health rules solely for list performance.
- Apply fixes automatically when an issue is detected.
