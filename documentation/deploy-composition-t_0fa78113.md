# Reviewed deployment composition: t_0fa78113

## Source contract

Use only branch `wt/t_0fa78113` in the preserved worktree
`/home/dsaw/Projects/NixOS/.worktrees/t_0fa78113` after its same-card review
approves the exact integration commit. Do not deploy from the older source
worktrees. The base is `ec10e8d`; its three post-`efee182` infrastructure and
agent-documentation commits were already present, not imported by this card.

The following task-owned patches were applied once with `git cherry-pick
--no-commit`, without importing sibling merge ancestry. All commit objects and
review handoffs were inspected; origin tracking refs match the reviewed heads
below (the deploy-review head is retained locally). No textual conflicts arose.

| Reviewed task | Exact reviewed head | Imported patches, in source order |
| --- | --- | --- |
| Deploy composition t_75be1a28 | 9907c2612d5b7e9e656cd3e3b1a986ffb3bbf8cf | 5e1a967, 0c25462, 37c2f00, d0994df, e9310b3, 9907c26 |
| Sudo/recovery t_192d38cd | b8c1cd3a511820e53058185fe9755aa67ecf9365 | 9073db6, e4ed42e, 05f2d5e, a0847e3, 4006e0b, b8c1cd3 |
| Memory t_db10a39b | f3315f5b8082ff83f40500e2a681572b0a3697f3 | 180a537, f3315f5 |
| Balanced policy t_b1302cf1 | a0406b6caa187601e0964b38b2ad7f4426fa1786 | a0406b6 |
| Executor t_43879ae2 | 030a4e94625e3717b71f8e198f7909ce9f807833 | 030a4e9 only; parent patches already supplied above |
| pnpm t_e1e0d36f | ebdb8a73a4834d5063dbf42e113484784e5bb070 | b1087ba, ebdb8a7 |
| Rust t_2cada628 | 50a1dfc871eeb0100e12e3878e30b31652f94e16 | 7189cd7, 3761dee, 69f1c26, 50a1dfc |
| mkvmaker t_f8e5eaa4 | ab962d17f4fe5a4bcbb46c099f72245dcc7d8d11 | d5cc148, ab962d1 |
| Chaptarr t_2f289fc6 | 4b57e24eb84edb2be19e2b197c4c7e097e0a812a | 4b57e24 |
| Kubo t_968a7b52 | 14175cb089f635276bf92ebfc365726092a10da2 | af8b42c, 14175cb |
| Identity edge t_7b7d3bbf | 7fd30766762022fc5253b524050444f5cec96ff9 | 7fd3076 |

Excluded: incomplete t_ffbf4279 and t_564ca00d, unrelated sibling changes and
merge-only commits. `vars.nix` is byte-identical to the base: no identity,
site, address, build-mode selection or admin-policy change. The missing new
sudo setting defaults to the existing bootstrap policy; adding a supported
restricted option is not authorization to select it on this host.

## Integration correction

The first combined lean run exited 1 because the sudo-policy scratch fixture
required an explicit `localAdminSudo` in the operator-owned `vars.nix`, although
production supports legacy files without it. The fixture now injects the
restricted policy into its copied identity block when absent. This exercises
the actual legacy shape without editing user settings; production behavior and
all security gates remain unchanged. No other integration fix was necessary.

## Local verification

All commands below used `REMOTE_EVAL=0`, a worktree-private `XDG_CACHE_HOME`,
and worktree-private `TMPDIR`. No server mutation or credential access occurred.
The focused commands used `NIXHOMESERVER_SKIP_NESTED_BUILDS=1`; this does not
constitute package-build or real-activation evidence.

- `bash scripts/tests/test-local-admin-sudo-policy.sh`: exit 0 after correction.
  Executes real executor test/switch processes, exact stamp reuse, stale-source
  refusal, boot-commit logic, post-activation root routing and non-root refusal
  with external systemd/Nix operations mocked in isolated namespaces.
- `bash scripts/validate-repo.sh`: corrected run exit 0; all requested script
  tests and repository checks passed.
- Each `bash scripts/tests/test-<name>.sh` below exited 0 in the combined tree:
  deploy-cli, deploy-debug-attestation, deploy-transaction-runtime,
  deploy-archive-staging, deploy-archive-permissions, build-allocation-policy,
  central-memory-containment, chaptarr-module, ipfs-swarm-binding,
  edge-flood-protection, node-pnpm-deps-scoping,
  rust-dependency-manifest-scope, rust-source-isolation,
  rust-workspace-dependencies, mkvmaker-tool-resolution, mkvmaker-automation,
  bootstrap-host, core-runtime-safety, homepage-guidance.
- Containment exercised the same assertions against actual selected, disabled
  IPFS/Search/offline-media and removed five-optional-app Nix configurations.
- Archive permissions executed the real helper and stamp writer with mapped
  non-root identities, not source-only permission assertions.
- `git diff --cached --check`: exit 0.
- `git diff --exit-code HEAD -- vars.nix`: exit 0 before integration commit.
- `nix eval --raw .#nixosConfigurations.server.config.system.build.toplevel.drvPath`:
  exit 0; target derivation at evaluation time:
  `/nix/store/zd296p5lv8033hk2rg0rj5smvlp6a6vf-nixos-system-server-26.05.20260829.c5c4a43.drv`.
- `nix build --dry-run --no-link .#nixosConfigurations.server.config.system.build.toplevel`:
  exit 0. This is a build plan, not a completed closure build; the reported
  cache/build worklist depends on the local store and configured substitutes.

Logs are preserved under `.cache/composition/` in this worktree. Full, all-apps,
VM, real activation and throughput benchmarking were not performed. Original
Rust review noted a pre-existing toolchain/kanidm-client compatibility risk;
closure evaluation cannot prove compilation succeeds. Prior package builds on
source cards are not claimed as builds of this exact combined source.

## Rollout prerequisites and boundaries

Routine rebuilds and deployment tests must use only the guarded helper, first
`nix run .#deploy -- --action test`, then the matching guarded `switch` after
passing health/canary and source-bound stamp checks. Keep dashboard-selected
allocation; no raw rebuild or allocation override is authorized here.
AGENTS.md already prohibits raw ordinary rebuilds and preserves default
allocation. An attempted wording reinforcement was denied by the protected-file
approval guard; no alternate write was attempted and AGENTS.md is unchanged.

Read `documentation/operations.md`, especially Local-Admin Sudo Policy and
Deploy Archive Staging Rollout. Missing sibling staging on any selected build
host fails closed before upload. The local-only deployment worker must confirm
actual owner/traversal, 0700 directory, 0600 archive, independent 48-hour expiry
and active cleanup timer; if bootstrap needs an allocation exception, stop for
explicit authorization rather than improvising a bypass. Do not select the
restricted admin policy or console/local allocation to work around rollout.

After approved deployment, inspect real transaction/rollback/stamp outcomes,
authenticated Homepage canary, external password/passkey sign-in, service
memory/OOM behavior, Chaptarr loopback socket and application UID/LAN refusal,
and Kubo NetBird swarm and publishing connectivity. These are live evidence
gaps, not offline-test guarantees. The user permits completed reviewed changes
to proceed without the paused tasks; this implementation card itself performs
no live action and the exact integration still requires reviewer approval.
