# Deployment and recovery

Read the focused operation's maintained runbook and `AGENTS.md` deploy gate.
Hermes uses `documentation/hermes-deployment-receipts.md` to verify recorded
whole-set review, paired decision, frozen source, and guarded test consistency.
Outside this checkout, use its maintained installed copy under
`~/.hermes/scripts/hermes-deployment-receipts.md`.

Commit validated source where possible before a guarded operation. Ordinary
build/activation uses the dashboard's default allocation:

```bash
nix run .#deploy -- --action test
nix run .#deploy -- --action switch
```

Run only the already-authorized action after its prerequisites hold. A matching
green test plus qualified whole-set acceptance/decision authorizes routine
switching within recorded scope. Changed source or mutable inputs need fresh
review/test. Preserve the deployer's evaluation, build, activation, route/unit/
canary, tested-closure, boot-commit, and rollback checks. Never switch manually
to bypass them, use raw `nixos-rebuild` outside an in-scope console recovery, or
override build mode/host, max-jobs, sandbox exclusions, or credential placement.

If deployed-server sudo interaction is unavoidable, use only the root-only
agenix `serverBootstrapSudoPassword` at
`/run/agenix/serverBootstrapSudoPassword` as documented in `AGENTS.md`.
Never print or copy it into source, scratch, logs, or a review payload.

After activation, inspect affected units, routes, authenticated access,
persistence, or backup health. A new app also requires:

```bash
sudo systemctl start homepage-canary.service
sudo homepage-canary-assert
```

Inspect the authenticated rendered result; a green deploy alone is not access
proof. Preserve failure evidence and allow guarded rollback to complete.

For storage replacement, restores, deletion, bootstrap, and secret rotation,
retain reserved authority for actual destructive/credential effects. Verify
stable device identities independently before destructive work. Restore into
a separate path and preserve failed state until recovery is inspected. Stop
when target identity, backup freshness, rollback, or required authority is
ambiguous. Reversible preparation stays within existing approved scope.
