# Caller-scoped Office access

The owner requested implementation of the first parts of the caller-aware
restoration on 2026-11-11. This document records that increment's contract and
the boundaries still required before Office tools can be restored.

## First increment: authenticated request identity

The existing loopback endpoint and stdio bridge remain `web_search`-only.
All four Office handlers keep their unconditional denial. No environment
variable, identity header or model argument can restore them.

The gateway-facing endpoint uses a separate systemd-activated Unix stream
socket, `/run/ai-tools-gateway.sock`, owned by `caddy:caddy`, mode `0600`.
Systemd hands the listening descriptor to the unprivileged `ai-tools` process.
The process validates the activation contract and sets close-on-exec before
serving it. It never creates, chmods or removes a gateway socket itself.

The existing `tools.<domain>` host authenticates through the shared gateway,
checks its unchanged `ai-users` admission group, then proxies directly to this
socket. The internal loopback router has no route to it. Caddy replaces the
canonical subject and preferred-username headers with authenticated gateway
claims. Loopback clients cannot create a trusted request identity by forging
headers. Root and the gateway process remain trusted infrastructure.

The new endpoint is stateless Streamable HTTP. It uses rmcp's
`NeverSessionManager`, creates no resumable event store, and rejects every
request carrying `Mcp-Session-Id`, including empty headers. Every request,
including initialization and notifications, independently requires exactly one
nonempty canonical subject and username. There is no username/email fallback,
identity in tool arguments, identity cache, or session-to-user ownership map.
Host and browser Origin checks apply independently of identity checks. The
gateway's browser Origin allowlist explicitly specifies HTTPS port 443; a
portless rmcp allowlist entry would also admit other ports. Any future chat
origin added to this list must also specify port 443.

Middleware creates a private typed caller value in HTTP request extensions.
rmcp carries those HTTP parts to each handler. The authenticated handler checks
for that value again before tool discovery or execution. The value establishes
gateway authentication only: it is **not** a filesystem principal or a grant of
document access. The subject is opaque; the username is a directory claim,
never a path component or an instruction to impersonate a Unix account.

Caller-scoped tools use `crate::gateway::AuthenticatedCaller::require(&context)?`
at the beginning of each handler. Its `subject()` and `username()` accessors
return the canonical claims from this request. The fields and constructor are
private and the type has no deserializer. Require it before arguments are used
or private upstreams are contacted. Scope stored jobs, caches and result access
to `subject()`. Independently enforce the source application's permissions:
this API supplies no access token, current group membership or authorization
to use an application's service credentials. For filesystem reads it supplies
no POSIX mapping. Missing identity is an error, never an owner-account default.

Gateway JSON/API routes must use the same direct-handler selection and group
check as ordinary authenticated routes. Previously those branches always used
the loopback router, so a direct socket handler could not be used by MCP.
Unauthenticated JSON requests retain HTTP 401 handling.

## Remaining restoration stages

1. Resolve the stable authenticated identity to an approved existing Kanidm
   POSIX identity. Prove UID/GID mapping, local-name collision handling and
   freshness of account/group information. Reject unknown, disabled, root and
   service identities; do not auto-enrol users or use stale/offline group grants.
   Gateway session authentication alone does not prove immediate revocation of
   directory membership.
2. Build a minimal Rust launcher and read worker. Drop to the resolved user's
   credentials before opening paths, including ancestors. Enforce both the
   approved root and kernel permissions on the actual opened regular file;
   handle ACL masks, hidden entries, symlinks, hardlinks and replacement races.
   Give the parser bounded bytes rather than ambient filesystem access. Never
   give the parser privileges or use the service account's document grants as
   an authorization fallback.
3. Restore native read operations only after the identity/permission checks
   pass. The initial root remains the existing shared root; personal roots and
   OpenCloud's application-level shares are separate scope. OpenCloud shares
   require its user-authorized API rather than storage-directory ACL inference.
4. Correct the demonstrated document-preservation problems before restoring
   editing: silent column/text truncation, sheet renaming/visibility changes,
   and unsupported Word styles. Prefer verified targeted changes and new output
   copies. Writes need destination permissions, explicit replacement intent,
   version checks, and authorization at commit time.
5. Connect the Bonsai browser's per-client MCP configuration through an
   authenticated route. The shared inference account and identity-free stdio
   bridge must never substitute for the current user. Verify real authenticated
   Word/Excel workflows before claiming restoration.

Existing static ACLs and membership are unchanged by the first increment.
Removing or replacing those grants requires a separately reviewed migration;
their continued presence does not authorize a read. No new credentials, public
hosts, file permissions, filesystem privilege launcher or live activation are
part of this increment.

## Verification and failure behavior

Focused automated checks are warranted by the concrete risk of future
cross-user document disclosure. They cover missing/malformed/duplicate identity,
forged arguments/metadata, per-request actor isolation, session replay rejection,
socket activation, gateway backend selection, and the unchanged Office denials.
Use a real Unix socket and the MCP client for transport checks. They do not
prove Kanidm-to-POSIX mapping, filesystem authorization, directory revocation,
production gateway health or browser usability.

Focused local checks:

```bash
cargo test --offline --locked --manifest-path custom_apps/Cargo.toml -p ai-tools gateway -- --test-threads=1
nix eval --impure --json --expr '
  let f = builtins.getFlake ("git+file://" + toString ./.);
      pkgs = f.inputs.nixpkgs.legacyPackages.${builtins.currentSystem};
  in import ./scripts/tests/ai-tools-gateway-contract.nix {
    inherit pkgs; inherit (pkgs) lib;
  }'
```

Rollback must preserve the unconditional Office denials. Never route a caller's
document operation through the identity-free listener to recover availability.
Commit focused validated source before a separately authorized guarded test and
switch. No deployment is implied by this design or its implementation.
