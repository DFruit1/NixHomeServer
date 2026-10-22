# Hermes adapter patches

Applied against `~/.hermes/hermes-agent` when the pinned agent does not yet carry
the fix. Each patch is small, reviewed here, and re-applied after an agent update
that overwrites the file.

| Patch | File | Purpose |
| --- | --- | --- |
| `simplex-group-reply.patch` | `plugins/platforms/simplex/adapter.py` | Authorise group senders by numeric `memberContactId` (so `SIMPLEX_ALLOWED_USERS` works in groups) and surface a reply-to-message's quoted text as `[Replying to: ...]` so a quoted decision keeps its D label. |

Apply from the agent checkout:

```bash
cd ~/.hermes/hermes-agent
git apply --check scripts/hermes/patches/simplex-group-reply.patch   # path adjusted to the repo
git apply scripts/hermes/patches/simplex-group-reply.patch
hermes gateway restart        # loads the adapter for the affected profiles
```

The patch path above is relative to the NixHomeServer checkout; run
`git apply "$OLDPWD/scripts/hermes/patches/simplex-group-reply.patch"` from the
agent checkout, or copy the file first.

Without the `memberContactId` mapping, the gateway logs
`Unauthorized user: <base64 memberId>` and silently drops every group reply.
After an agent update, re-check:

```bash
grep -n 'memberContactId' ~/.hermes/hermes-agent/plugins/platforms/simplex/adapter.py
grep -n 'Replying to:' ~/.hermes/hermes-agent/plugins/platforms/simplex/adapter.py
```
