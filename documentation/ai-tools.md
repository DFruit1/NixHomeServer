# AI Tools

The `ai-tools` application serves read-only MCP tools to the local llama.cpp web
UI. Tools are attached per client, so the shared inference endpoint keeps
serving other consumers (Hermes, Paperless) with their own tool choices. The
process speaks MCP over Streamable HTTP on `127.0.0.1:8097` and is published at
`https://tools.<domain>` through the shared Kanidm authentication gateway, which
admits `ai-users`.

## Document conversion is currently unavailable

`convert_document` is suspended for **all** callers. Every call is refused
before any path is resolved and before any file is opened, with the fixed
message:

```text
Document conversion is unavailable pending caller-permission enforcement
```

The refusal is also what a caller gets if it learned the tool from cached
discovery metadata or invokes it directly by name: `convert_document` no longer
appears in `tools/list`, and the dispatch branch is kept as an explicit denial
rather than folded into the unknown-tool error. The message deliberately names
no path, filename or root, so it cannot be used as a probe for the shared
directory.

`web_search` is unaffected and still advertised.

## Why it was suspended

Document conversion was authorized by a static service account, not by the
calling user. The `ai-tools` account holds a read grant on the shared root
(`g:ai-tools:r-x` plus the default ACL `d:g:ai-tools:r-x` re-applied by
`ai-tools-shared-access.service`) and the gateway identity headers never
constrained the open. A caller whose own account cannot read a file could
therefore have it converted and returned by the service account. That is a
containment gap, not a measured live exposure: it was established offline with
synthetic `setfacl`/`getfacl` fixtures.

The owner's standing rule is that the model must not inherit any ACL the calling
user does not have. Until per-caller authorization exists, the smallest
fail-closed change is to refuse every server-path conversion. The tradeoff is
that all clients — including callers who *could* legitimately read the file —
lose conversion. That loss is deliberate and was approved; it is not a bug.

## What did not change

This is an interim containment measure, not a repair of the underlying
authorization model.

* The static service ACLs on the shared root are unchanged, and the
  `ai-tools-shared-access` grant still runs on every activation.
* Live group membership, the ACL migration marker and per-inode effective
  permissions remain unverified.
* `office.rs` and its converter tests stay in the tree, unreferenced by
  `main.rs`, for the caller-aware restoration. Do not delete them as dead code.
* No configuration toggle was added. The denial is unconditional in the source;
  flipping an environment variable cannot re-enable conversion.

## Operating the service

The MCP endpoint is `https://tools.<domain>` (gateway) or
`http://127.0.0.1:8097` (loopback). Health is `GET /healthz`.

```bash
sudo systemctl status ai-tools.service
curl -fsS http://127.0.0.1:8097/healthz
```

The unit is read-only against the shared root (`ProtectSystem=strict`,
`ReadOnlyPaths`, `ProtectHome`), confined to loopback
(`IPAddressDeny=any`, `IPAddressAllow=localhost`), and covered by the
`ai-tools-shared-access` data-pool guard. The module is in `modules/ai-tools/`;
the MCP server is `custom_apps/rust/apps/ai-tools/`.

The private host `tools.<domain>` is a canary target, so a deploy that breaks
routing or access is caught by `homepage-canary-assert`.

## Requirements for restoring conversion

Restoration needs its own approved change and design; it is not a revert of this
commit. Rolling the denial back reopens the unbounded read path, so a bad
containment build must leave conversion unavailable and be repaired, never
worked around.

A caller-aware design must establish, at minimum:

* Trusted request identity, bound to the specific MCP request or session.
* A mapping from that identity to a filesystem principal, with the actual
  current read and ancestor-traverse permission checked on the opened object —
  not just membership in the configured shared group.
* Fail-closed handling of unknown identity and revocation.
* Effective ACL mask handling, so a granting entry cannot act through a mask
  that denies it.
* No reads or writes outside the approved scope, with the hidden/symlink/
  hardlink, replacement-race and copied-file controls from the original
  assessment.
* Any grant being a subset of the caller's actual reach.

Such a change touches trust boundaries and the authorization architecture, so it
needs its own immutable plan and an explicit owner decision before
implementation. Do not add descendant grants, revoke existing ACLs, auto-enrol
users or change `allowedGroups` as an interim substitute — they can widen reach
without establishing caller permission.
