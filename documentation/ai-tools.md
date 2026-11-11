# AI Tools

The `ai-tools` application serves MCP tools to the local llama.cpp web UI. Tools
are attached per client, so the shared inference endpoint keeps serving other
consumers (such as Paperless) with their own tool choices. The process speaks MCP
over Streamable HTTP on `127.0.0.1:8097` and is published at `https://tools.<domain>`
through the shared Kanidm authentication gateway, which admits `ai-users`.

The gateway-facing transport uses a Caddy-only Unix socket and authenticates
each request independently; the loopback endpoint and stdio bridge carry no
trusted caller identity. See the [access-control contract](ai-tools-access-control.md)
for the authentication and filesystem-authorization boundaries.

## Word and Excel tools

For ordinary changes to existing documents, use `office_skill`, `office_inspect`,
`office_import_table`, `word_edit` and `spreadsheet_edit`. These support revision-bound table row
insertion/deletion, literal cell changes, mapped cross-document imports and
actual stable record sorting in one atomic new copy. Word also supports body
paragraph changes; Excel supports proven row-local formulas and table growth.
The runtime skills handle conventional user intentions without requiring users
to supply technical operation details. See the [structural editing contract](office-editing.md)
and the [packaged skill](../custom_apps/rust/apps/ai-tools/skills/office-editing/SKILL.md).

The authenticated gateway offers `convert_document`, `spreadsheet_read`,
`spreadsheet_write` and `word_document`. They require a current approved human
POSIX identity and operate only on shared-root files that user can access.
The TCP listener and stdio bridge retain their explicit Office denials.

Reads use a bounded view (256 sheets, 2000 rows/sheet, 64 columns or 5000
Word blocks); `next_offset` paginates that view. Respect truncation and omitted-
entry warnings; pagination does not recover omitted source content. Native xlsx reads retain formula text, not calculated
results. Word supports docx, odt, doc and rtf reads; spreadsheet reads support
xlsx and ods. Legacy/ODF conversion uses the existing Collabora instance.

`spreadsheet_write` and `word_document` use `action=create` or `action=edit`.
Every save needs a **new** `output_name`, one filename in `ai-workspace`.
Existing files are never overwritten. Creation uses `spec.sheets` (name/rows,
optional visibility state) or `spec.blocks` (paragraph/table kind, text/runs,
optional existing style). Edits use `source_path` plus targeted patches:

```json
{"action":"edit","source_path":"Reports/budget.xlsx","output_name":"budget-reviewed.xlsx","spec":{"cells":[{"sheet":"Budget","cell":"A1","value":150}]}}
```

```json
{"action":"edit","source_path":"Reports/letter.docx","output_name":"letter-reviewed.docx","spec":{"replacements":[{"find":"Pending approval","replace":"Approved"}]}}
```

Native edits preserve untouched package content and styles. Word phrases must
match exactly once in body paragraph text; complex body fields, tracked changes and unsupported non-text constructs
are refused. Editing ODF into a preservation-guaranteed copy is not supported;
use native xlsx/docx sources. New ODF documents can be created through Collabora.
Formulas are marked for recalculation when opened, not calculated here. Inspect
the workspace after a timed-out save before retrying with a new name.

See the [access-control contract](ai-tools-access-control.md) for identity,
filesystem, parser and preservation limits. Repository configuration alone is
not proof of live activation or browser connectivity.

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
retain their denials on identity-free transports. Validate and deploy through the normal guarded procedure;
source checks do not establish live browser or authenticated app access.

## Authorization history

The earlier implementation used the service account's static ACLs for every
caller. Office tools were suspended after offline review demonstrated that
this could exceed a caller's own file permissions. The current restoration
uses the separate credential-dropping broker and sandboxed byte parser; the
old handlers remain unconditional denials on identity-free transports. Existing
static ACL provisioning remains, but the main service cannot open the shared
root and the broker's account has no document grant.

## Operating the services

The authenticated MCP endpoint is `https://tools.<domain>` or the Bonsai
same-origin `https://ai.<domain>/mcp`. Loopback `http://127.0.0.1:8097` remains
web-search-only, with `GET /healthz` for health. No client-provided identity
header can authenticate a loopback request.

```bash
sudo systemctl status ai-tools.service ai-tools-office-io.socket ai-tools-office-io.service
curl -fsS http://127.0.0.1:8097/healthz
```

The file broker is socket-activated; an idle broker need not already be running.
Both services have memory/CPU/IO limits, loopback egress restrictions and data-
pool guards. Gateway and broker socket ownership are distinct. The module is
`modules/ai-tools/`; implementation is `custom_apps/rust/apps/ai-tools/`.
The private AI host retains authenticated canary coverage; the private Tools
host is API-only and requires explicit MCP handshake verification. After a
guarded deployment, verify caller-specific native Office workflows, Search
admission and downloader job ownership before claiming the tools usable.
