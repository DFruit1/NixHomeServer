# Caller-scoped Office access

Office operations are offered only by the authenticated gateway. The loopback
listener and stdio bridge remain web-search-only and explicitly deny cached
Office calls. The gateway checks the existing `ai-users` admission group and
passes a private, per-request `AuthenticatedCaller` through HTTP extensions.

## Gateway boundary

Caddy alone can connect to `/run/ai-tools-gateway.sock` (`caddy:caddy`, 0600).
Systemd supplies the listening descriptor; the service validates its pathname,
activation PID, stream/listener type and close-on-exec flag. Caddy removes
client identity headers and replaces canonical subject/preferred-username
claims after authentication. Ordinary, JSON and API branches all use this
socket. The existing private AI host additionally routes `/mcp` here for Bonsai.

The router uses `NeverSessionManager`: every request needs current canonical
claims, and every `Mcp-Session-Id` header is rejected. Subject/username must be
single, nonempty, bounded ASCII claims without whitespace or commas. Host and
Origin checks apply independently; approved browser origins specify HTTPS port
443. TCP headers, arguments and `_meta` cannot construct the private caller.
Root, Caddy, systemd, the directory and the Rust gateway process are trusted.

Other private tools must start with
`crate::gateway::AuthenticatedCaller::require(&context)?`. This proves gateway
authentication, not filesystem access or authorization to use service tokens.
App tools additionally pass only the current request's SSO cookie to the target
app gateway; it retains its existing group and ownership checks.

## Online file identity and credential dropping

Only `ai-tools` can connect to `/run/ai-tools-office-io.sock` (0600). A separate
`ai-tools-io` account has no document ACL grant. Its capability bounding and
ambient sets contain only `CAP_SETUID` and `CAP_SETGID`, permitting credential
switching without root, DAC override, filesystem administration or setpcap.

For **each** file operation the broker performs a fresh native anonymous
Kanidm authentication transaction over certificate-verified HTTPS, pinned to
loopback. It requests `/v1/account/<subject UUID>/_unix/_token` using the
anonymous token. No stored credential or user SSO cookie is used. The current
Unix token must be valid and match the subject UUID and canonical name/SPN.
Only existing configured human names from `kanidmAdminUser`, `kanidmAppUsers`
and `filesSftpUsers` are accepted: a Unix token alone also permits service
identities, so it cannot establish that the caller is a person. Unknown users
are denied, never enrolled. UIDs/GIDs below 1000 are refused.

Fresh directory groups determine supplementary groups. NSS only corroborates
numeric UID/GID-to-name mapping (including primary GID = UID); it supplies no
cached membership grants. Missing mappings, collisions, disabled accounts,
directory failures and malformed/oversized responses fail closed. Local
`dsaw` and directory `admindsaw` are distinct; no privileged alias is inferred.
Gateway admission continues to follow existing SSO session semantics; this is
not a claim of immediate non-POSIX `ai-users` revocation. Fresh Unix groups
prevent using stale file-group membership on subsequent file operations.

The primary GID is corroborated against NSS even when the token omits its
private group from the supplementary list. Its name must match the same
account, as required by [Kanidm's user-private-group model](https://kanidm.github.io/kanidm/stable/accounts/posix_accounts_and_groups.html).
Names/SPNs must form consistent canonical pairs with valid DNS realms; no
whitespace/control suffixes or short-name fallback for malformed SPNs is
accepted. Conflicting identities with one numeric GID are rejected rather
than deduplicated into a grant. Valid short-name and full-SPN mappings remain
supported, and repeated identical groups remain harmless.

The broker serializes requests and spawns the fixed executable as a disposable
worker. A syscall-only `pre_exec` sets supplementary groups and real/effective/
saved UID/GID, explicitly clears permitted/effective/inheritable and ambient
capabilities, sets no-new-privileges, and verifies the result. The worker
verifies all IDs, filesystem IDs, groups, empty capabilities and no-new-privileges
again after exec, then closes inherited descriptors before opening documents.
The broker never parses Office data. No UID, group, root or command is supplied
by the model. Frames, pipe output, document sizes, concurrency and elapsed time
are bounded; saves are never automatically retried.

## Filesystem and save contract

Reads initially cover only the existing shared root, subject to the caller's
actual kernel permissions, including ancestor traversal and ACL masks.
Reading a legitimately shared file does not require the caller to own its UID.
These checks do not alter shared-folder ACLs, ownership or deletion policy.
`openat2` pins the root, requires beneath resolution and refuses symlinks/magic
links. Hidden components, absolute paths, backslashes and parent traversal are
refused. Only regular, single-link files up to 32 MiB are eligible; reads use
the opened handle, bound growth and check for concurrent metadata changes.
Personal roots and application-level OpenCloud shares are separate scope.

Writes create a **new copy only**, with one filename directly in the existing
AI workspace. The worker opens the workspace relative to the pinned root and
requires a root-owned sticky shared root and root-owned workspace. These
existing storage invariants prevent a caller moving the publication directory.
It stages with O_EXCL, writes and fsyncs, checks the inode, then publishes using
`renameat2(RENAME_NOREPLACE)` and verifies the published inode. Existing files
are never replaced; the original is never modified. New files belong to the
caller and start mode 0600. Other workspace writers retain their existing
rights. An interrupted/failed save can retain a hidden `.ai-tools-*.part`
stage; no pathname cleanup risks deleting a raced replacement. Inspect the
workspace after an uncertain result before choosing a new output name.

The main service cannot open the shared root (`InaccessiblePaths`). Existing
static `ai-tools` ACLs are retained for compatibility with the old provisioning
unit but are never consulted for authorization and cannot be used through the
restored path. The broker account receives no new ACL. Their removal is a
separate migration.

## Parser and preservation boundary

The parser receives only bounded bytes/specifications on stdin. A fresh exec
installs fully enforced Landlock v3 filesystem restrictions: read/execute from
`/nix/store`, no filesystem writes, and no other readable tree. Seccomp denies
network/Unix sockets, io_uring, cross-process memory/FD access, signals and
process creation; unknown syscall architectures/x32 are killed. All descriptors
above stderr are closed before the pinned Python helper executes. Memory, CPU,
core and file-size limits apply. Startup runs the packaged helper's sandbox
probe; unsupported isolation prevents the service advertising Office tools.

Native edits mutate selected OOXML parts rather than rebuilding a read view.
Workbook cell patches preserve styles, sheet states and unrelated ZIP members;
formula caches are cleared and recalculation requested on open. This service
does **not** calculate formulas. Merged non-anchor cells, protected sheets and
worksheets containing shared/array formula constructs are refused. Word replacements must uniquely match
body paragraph text (including tables); formatting/other package parts remain.
Tracked changes and complex body fields are refused for the whole source;
fields and non-text constructs in touched paragraphs are refused. Signed/macro packages are refused for editing. Native-preserving
edits require xlsx-to-xlsx or docx-to-docx; ODF can be read or newly created
through existing Collabora conversion. Creation rejects demonstrated silent
text/column truncation and case-insensitive sheet renaming.

Views are capped at 256 sheets, 2000 rows per sheet and 64 columns, or 5000
Word blocks. `next_offset` paginates within that bounded view, not the omitted
source content; respect the source truncation flags. A large entry
can be marked omitted. Never rebuild a source from this view. ZIP member/count/
expansion limits precede native parsing. The Python exception remains justified
by the existing pinned openpyxl/python-docx pairing; targeted XML uses their
existing lxml dependency.

## Focused verification

The additive [structural editing interface](office-editing.md) uses this same
actor/broker/parser boundary. Every imported file is separately broker-read and
revision-pinned. Entire operation batches finish in memory before one new-copy
publication; no preview/rebuild or intermediate file grants bypass permissions.

```bash
cargo test --offline --locked --manifest-path custom_apps/Cargo.toml -p ai-tools -- --test-threads=1
# Explicit catastrophic-risk check, outside build sandboxes, in a mapped namespace:
unshare --user --map-auto --map-root-user --setgroups allow \
  <ai-tools-test-executable> --exact \
  office_io::tests::office_worker_drops_nonroot_capabilities_and_cannot_overwrite \
  --ignored --nocapture
nix eval --impure --json --expr '
  let f = builtins.getFlake ("git+file://" + toString ./.);
      pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  in import ./scripts/tests/ai-tools-gateway-contract.nix {
    inherit pkgs; inherit (pkgs) lib;
  }'
```

Local checks cover transport separation, online identity validation logic,
Linux capability dropping/permissions, no-overwrite publication, parser
isolation and synthetic document preservation. They do not establish deployed
NSS mappings, production socket activation, live browser/model workflows or
service health. Guarded test/switch and authenticated post-deploy checks remain
required before claiming activation. Recovery must never route private calls
through the identity-free listener or relax failed permission checks.
