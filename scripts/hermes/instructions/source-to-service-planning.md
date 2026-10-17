# Read-only source-to-service planning

Use when the owner supplies an existing codebase or firmware and wants a receiving application designed around it, without changing the supplied source. This is a commissioning and report-acceptance recipe, not proof that any proposed integration already works.

## 1. Freeze the investigation contract

- Confirm the exact source path exists and is readable using metadata checks; this establishes access, not understanding of its code.
- Put the verbatim request, read-only boundary, deliverables and exclusions in one durable specification outside that source before releasing readers. Keep runnable cards concise and point them to that specification.
- Route the investigation through the audit lead. Commission source readers in bounded independent slices, then synthesis, finished-proposal verification and final owner delivery. Do not end the lead handoff merely because readers were created.
- Preserve read-only source status with optional-lock-free Git metadata queries, such as `GIT_OPTIONAL_LOCKS=0 git -C <source> status --porcelain`, plus an externally stored source-file digest inventory where permitted. Do not create worktrees, reports or build outputs under the protected tree, refresh its index, stash changes or run its scripts. Record exclusions and concurrent drift rather than claiming global immutability without evidence.
- Keep credentials, private locations and production telemetry out of reports. Route genuinely necessary confidential inspection to the local lane rather than copying secrets into a general review.

## 2. Commission complementary evidence slices

Prefer these questions over several identical whole-repository reviews:

| Slice | Evidence to return |
|---|---|
| External contract | Actual serializers, connection and publish/subscribe callsites; field types/units, topics, direction, identity, timestamps, protocol/transport, delivery/reconnect/replay semantics and version differences |
| Domain and lifecycle | Measurement conversion/calibration, invalid values, references/sign conventions, device state, sampling versus reporting, power/connectivity modes, status/error codes and provisioning/control capabilities |
| Existing receiving system | Current parser/models/storage/API/UI, broker/authentication/ACLs, ingress/identity, persistence/backups and tests; exact supported/missing/mismatched mappings |

Require file/line citations, source identity, inspected/excluded paths and a compact contract table from each reader. Treat repository HEAD, newest-named directory and documentation examples as candidates, not proof of the deployed version. Reuse existing reports when their scope and source still apply; do not repeat a spent unchanged audit to repair a missing summary.

## 3. Resolve compatibility before selecting architecture

- Trace the exact transport end to end. Distinguish native TCP/TLS from WebSocket/HTTP and inspect what the client actually implements; matching a hostname or saying that traffic goes through a proxy does not establish transport compatibility.
- Verify provider/proxy capability claims against authoritative documentation for the applicable product/version. For MQTT behind Cloudflare, assess the actual TCP, Tunnel/Access, Spectrum or WebSocket path separately instead of assuming ordinary HTTP proxying carries native MQTT. Record options and approval/budget implications rather than inventing an available service.
- Derive schema fixtures from cited source and label them synthetic. Do not invent field names, sensor support, example readings or live-session receipts.
- Keep technical unknowns agent-owned when repository or public documentation can resolve them. Reserve owner questions for installed/deployed facts absent from those sources and genuine product decisions.

## 4. Require a usable high-level plan

The proposal should connect the existing producer to a useful authenticated application:

1. Show ingress, authentication, broker/event handling, validation, storage, API and user workflows; identify existing versus proposed components.
2. Specify compatibility handling for units, calibration/reference metadata, quality/sentinel values, event versus receive time, duplicates, ordering, replay, gaps and schema changes.
3. Define device/site/user ownership, sharing and roles, device enrollment/credential lifecycle and per-device authorization without exposing actual secrets.
4. Separate MVP essentials from optional dashboards, maps, history, alerts, exports, integrations, remote commands and update mechanisms. Telemetry capability is not permission to enable device control.
5. Include phased deliverables, real dependency/file ownership boundaries, synthetic offline acceptance, resource/privacy/retention considerations, backup/restore, later authorized end-to-end pilot and rollout/rollback gates.
6. Label unanswered architecture/stack/frontend/security decisions and proposed implementation classification. A requested high-level proposal is not an approved implementation plan, but missing implementation approval must not prevent producing the proposal itself.

## 5. Ask useful questions after inspection

Lead with the important observed facts, then the plan and a grouped questionnaire. For a deliberately thorough discovery request, a substantial set of focused questions is appropriate; do not force a numeric quota or pad it with facts the code already answers.

Cover end goal/success criteria; users and access; deployed versions/hardware/sites/calibration; connectivity and hosting constraints; data quality/time/retention; dashboards/maps/analysis; alerting/maintenance/control; exports/integrations; scale/budget/reliability; and first-release priorities. Briefly explain the observed fact motivating each group. Mark the small architecture/MVP-critical subset separately from later preferences, and offer defaults only as explicit recommendations.

Ask for sanitized descriptions, not credentials, private coordinates or whole configuration dumps. Keep source-derived behavior distinct from field behavior that still needs a later authorized device or service test. Deliver actual durable reports and the question set through the existing final continuation; do not substitute an asynchronous routing acknowledgment for the requested completed review.
