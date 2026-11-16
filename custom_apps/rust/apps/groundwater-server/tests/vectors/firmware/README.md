# Firmware golden vectors (copied unchanged)

Decoded by `src/vectors_tests.rs` (`firmware_*` tests). Copied 2026-11-16 from
the firmware worktrees; regenerate there, never edit here.

| File | Source worktree / branch @ commit | Generator |
|---|---|---|
| `rev2-records.json` | `Ground-Water-Level-fw-storage-core`, `fw/storage-core` @ 4299d3a (file untracked there) | `tests/gen_vectors.c` |
| `rev2-batches.json` | `Ground-Water-Level-fw-persistence-io`, `fw/persistence-io` @ ef285d0 | `tests/gen_batch_vectors.c` |
| `rev2-json.json` | `Ground-Water-Level-fw-protocol`, `fw/protocol` @ 7e8491d | `tests/gen_json_vectors.c` |

SHA-256: records `672de1aa…5e1d`, batches `a10a8fc5…a884`, json `84a50192…a430b`.

Re-checked 2026-11-16 against the merged firmware branch `feat/fw-rev2` @
c105daf (`docs/protocol/vectors/`): rebuilding the three generators from a
`git archive` snapshot and running them with `--write` reproduces all three
files byte for byte, so the copies here are current.

Re-checked 2026-11-17 against `feat/fw-rev2` @ dfc8fae (round 3
integration) and again @ 12de183 (its review): the three generators built from a `git archive` snapshot
report the committed files current, and they are byte-identical to these
copies. They do not yet exercise the round 3 wire forms (`"persist":false`,
`"prev":"failed"`, `boot_report`, `gps:"off"`, omitted `bat_mv`); the server
covers those in `wire_follow_tests.rs` and unit tests.

Known contract point: Type 14 `firmware_version` is packed
`major<<16 | minor<<8 | patch` (build in bits 24-31), not the byte order
"major, minor, patch, build" the Rev2 table suggests; the server follows the
firmware (`records::firmware_version_text`).
