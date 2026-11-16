# Firmware golden vectors (copied unchanged)

Decoded by `src/vectors_tests.rs` (`firmware_*` tests). Copied 2026-11-16 from
the firmware worktrees; regenerate there, never edit here.

| File | Source worktree / branch @ commit | Generator |
|---|---|---|
| `rev2-records.json` | `Ground-Water-Level-fw-storage-core`, `fw/storage-core` @ 4299d3a (file untracked there) | `tests/gen_vectors.c` |
| `rev2-batches.json` | `Ground-Water-Level-fw-persistence-io`, `fw/persistence-io` @ ef285d0 | `tests/gen_batch_vectors.c` |
| `rev2-json.json` | `Ground-Water-Level-fw-protocol`, `fw/protocol` @ 7e8491d | `tests/gen_json_vectors.c` |

SHA-256: records `672de1aa…5e1d`, batches `a10a8fc5…a884`, json `84a50192…a430b`.

Known contract point: Type 14 `firmware_version` is packed
`major<<16 | minor<<8 | patch` (build in bits 24-31), not the byte order
"major, minor, patch, build" the Rev2 table suggests; the server follows the
firmware (`records::firmware_version_text`).
