# AI Tools

The `ai-tools` application serves MCP tools to the local llama.cpp web UI. Tools
are attached per client, so the shared inference endpoint keeps serving other
consumers (such as Paperless) with their own tool choices. The process speaks MCP
over Streamable HTTP on `127.0.0.1:8097` and is published at `https://tools.<domain>`
through the shared Kanidm authentication gateway, which admits `ai-users`.

The gateway-facing transport uses a Caddy-only Unix socket and authenticates
each request independently; the loopback endpoint and stdio bridge carry no
trusted caller identity. See the [access-control contract](ai-tools-access-control.md)
for this foundation and the remaining filesystem-authorization work.

## The office tools are currently unavailable

All four office-document tools are suspended for **all** callers:

| Tool | Answer |
| --- | --- |
| `convert_document` | `Document conversion is unavailable pending caller-permission enforcement` |
| `spreadsheet_read` | `Office tools are unavailable pending caller-permission enforcement` |
| `spreadsheet_write` | `Office tools are unavailable pending caller-permission enforcement` |
| `word_document` | `Office tools are unavailable pending caller-permission enforcement` |

Each call is refused at the start of the tool's handler, before the arguments are
parsed, before any path is resolved, and before any file is opened, created,
staged, handed to the office helper or converted by Collabora. The refusal names
no path, filename or root, so it cannot be used as a probe for the shared
directory.

The refusal is also what a caller gets if it learned a tool from cached
discovery metadata or invokes it directly by name: none of the four appear in
`tools/list`, and each dispatch branch is kept as an explicit denial rather than
folded into the unknown-tool error. The stdio bridge that llama-server spawns
forwards this reduced list unchanged, so the model is offered `web_search` and
nothing else.

`web_search` is unaffected and still advertised.

## Search and YouTube tools

When their optional applications are enabled, the authenticated gateway also
offers these tools. The loopback endpoint and stdio bridge stay web-search-only.

| Tool | Use |
| --- | --- |
| `document_search` | Search saved documents by words and optional inclusive date range. |
| `email_search` | Search archived email, with optional inclusive sent-date range. |
| `youtube_search` | Find candidate YouTube video titles, links and snippets. |
| `youtube_info` | Inspect one video's title, channel, duration and chapters. |
| `youtube_download` | Submit one video/audio download; personal storage by default. |
| `youtube_job` | Check a submitted job belonging to the current user. |

Document and email searches use the existing Search app and require its
`search-admins` access. They do not expand access to everyone in `ai-users`.
Results include source links, snippets, dates and partial-result warnings;
`max_results` is limited to 20, with zero-based `page` pagination. Date fields
are `after` and `before` in `YYYY-MM-DD` format. Set both to the same day for an
exact date. These refer to the source document/email date, not its import date.
Search words are required. Email search covers the archive, not a live mailbox;
no sending, moving, labelling or deleting mail is implemented.

The downloader retains its `downloads-users` access, job ownership and
shared-write checks. Accepted URLs identify one HTTPS YouTube video, including
short links and Shorts. Tracking and playlist parameters are stripped;
playlist/channel downloads are not exposed. Downloads default to 1080p MP4
video or M4A audio. `download_transcript` optionally saves subtitles alongside
the media. Submitting a job is not success: inspect `youtube_job` and report a
completed download only after `status` becomes `completed`. Resolve duplicate,
chapter or destination-collision alerts in the downloader UI. Do not blindly
retry a submission after a connection failure; inspect the downloader first.

### Bonsai chat connection

With AI Tools and Bonsai enabled, the existing private AI host serves `/mcp`
through the authenticated gateway socket. Its `ai-users` admission remains
unchanged. The pinned llama.cpp UI receives a default **Home server** MCP
connection to `https://ai.<domain>/mcp`, enabled for new chats. Requests run in
the browser with its same-origin SSO cookie; no credentials are stored in UI
configuration and the llama-server CORS proxy is not enabled.

Existing browser settings may override the new default. In the chat's MCP
settings, add/enable **Home server**, use `https://ai.<domain>/mcp`, and leave
the proxy disabled. No API key or custom identity headers are needed. Tools
must also be enabled in the current conversation. A logged-out session fails
closed; sign back into the AI page and reconnect.

### Request authorization

Private app tools first require the gateway's typed authenticated caller. Each
call extracts only the shared SSO cookie (including numbered chunks) from that
HTTP request, then contacts the target app through local Caddy over HTTPS.
The target gateway authenticates the session and applies its existing group
gate; the app applies its existing ownership/action checks. The hostname and
API path are configured by the integration, never selected by the model.

The HTTP client verifies the hostname's TLS certificate, pins connections to
loopback, ignores environment proxies, follows no redirects, stores no cookies,
and bounds responses. No session, service token, caller identity or filesystem
grant is cached between tool calls. Credentials cannot be supplied through tool
arguments and upstream error bodies are not returned. Source documents, email
snippets and video metadata remain untrusted content, not instructions.

These optional integrations create no host, credentials, storage grants or
public exposure. Disabling either app removes its tools/configuration; removing
Bonsai removes the same-origin chat route and browser default. Office tools
remain suspended. Validate and deploy through the normal guarded procedure;
source checks do not establish live browser or authenticated app access.

## Why they were suspended

The document tools were authorized by a static service account, not by the
calling user. The `ai-tools` account holds a read grant on the shared root
(`g:ai-tools:r-x` plus the default ACL `d:g:ai-tools:r-x` re-applied by
`ai-tools-shared-access.service`) and the gateway identity headers never
constrained the open. A caller whose own account cannot read a file could
therefore have it read or converted and returned by the service account, and the
write half could create or overwrite documents in the workspace the same way.
That is a containment gap, not a measured live exposure: it was established
offline.

The owner's standing rule is that the model must not inherit any ACL the calling
user does not have. Until per-caller authorization exists, the smallest
fail-closed change is to refuse every server-path document operation. The
tradeoff is that all clients — including callers who *could* legitimately read or
write the file — lose the office tools. That loss is deliberate and was
approved; it is not a bug.

## What did not change

This is an interim containment measure, not a repair of the underlying
authorization model.

* The static service ACLs on the shared root and the workspace are unchanged,
  and the `ai-tools-shared-access` grant still runs on every activation.
* Live group membership, the ACL migration marker and per-inode effective
  permissions remain unverified.
* `office.rs`, `office_write.rs` and the Python office helper stay in the tree,
  unreferenced by the running handlers, for the caller-aware restoration. Their
  format-adapter and path-confinement tests still run. Do not delete them as dead
  code.
* Collabora configuration and the shared/workspace roots are still parsed and
  validated at startup, so a restoration re-enables a working endpoint rather
  than discovering a stale one at republish time.
* No configuration toggle was added. The denial is unconditional in the source;
  flipping an environment variable cannot re-enable the tools.

## Operating the service

The MCP endpoint is `https://tools.<domain>` (authenticated, stateless gateway)
or `http://127.0.0.1:8097` (identity-free loopback). Health is `GET /healthz`.
Gateway requests require canonical subject and preferred-username claims from
Caddy and reject `Mcp-Session-Id`. The gateway socket is
`/run/ai-tools-gateway.sock`, owned by Caddy, mode `0600`, and passed to the
service through systemd socket activation. A direct loopback client cannot
authenticate by supplying identity headers.

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

## Requirements for restoring the office tools

Restoration needs its own approved change and design; it is not a revert of this
commit. Rolling the denial back reopens the unbounded document read and write
paths, so a bad containment build must leave the tools unavailable and be
repaired, never worked around.

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
