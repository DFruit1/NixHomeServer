# Filesystem feature-directory ownership

Writers manage their own temporary directory claims. No coordinator, card
comment, database or expiry service grants ownership. Formal card dependencies
continue to describe required results; folder contention is filesystem state.

## Writer workflow

Each writer uses an exclusive assigned Git worktree. From that checkout:

```bash
python3 ~/.hermes/scripts/directory_claims.py list
python3 ~/.hermes/scripts/directory_claims.py claim modules/immich
python3 ~/.hermes/scripts/directory_claims.py request modules/immich --reason "Update the shared option"
git add -- modules/immich/services.nix
git commit -m "immich: update the shared option"
python3 ~/.hermes/scripts/directory_claims.py release
```

Plain-directory projects also use claims, stored in their assigned workspace's
`.directory-claims/` directory. They can have disjoint writers without a shared
Git index; releasing preserves their files in place. The runtime keeps the
assigned workspace bound even when a command uses another working directory.

Claim every required directory together. Acquisition either succeeds for all
directories or leaves ownership unchanged. An existing holder may continue
disjoint work; never hold a partial set while waiting on another writer.
Requests are addressed to the current claim generation. They neither transfer
ownership nor authorize effects outside the holder's task. The holder inspects
`list`, performs an in-scope requested edit or commits and releases its claim.
The requester then acquires it and obtains any required accepted commit through
the existing workspace/input procedure. A released claim does not deliver code.

Feature paths such as `modules/immich` or an application's frontend/backend
subdirectory are allowed. Repository roots, top-level collections, known
aggregate paths, symlink directories and individual-file claims are refused.
Parent/child claims conflict across every linked worktree. Separate directories
can still depend on the same interface: establish that contract or use a real
prerequisite edge before parallel implementation.

Files outside feature directories share one `@shared-files` claim: files directly
under the repository root, top-level collections such as `documentation/` and
`lib/`, and the known nested aggregate directories. Use native write/patch tools
for these atomic edits. This is one integration group, never per-file ownership.
Terminals cannot mutate shared files or rename/delete a claimed directory itself;
its parent remains read-only. There is no per-file locking workflow.

The runtime supplies the writer profile/session identity and assigned checkout.
Interactive operators outside Hermes specify `--repo PATH --owner LABEL` before
the command. These labels are coordination identities, not new authorization.
Existing role/tool restrictions, secrets, reviews and deployment gates remain.

## Filesystem protocol and enforcement

`git rev-parse --git-common-dir` owns `directory-claims/state.json`, shared by
all linked worktrees. It records owners, checkouts, feature paths, generations
and direct holder requests. A permanent `mutex` file protects transactions.
JSON is fsynced, atomically replaced and its containing directory fsynced.
Malformed state fails closed. Generation lock files are never unlinked.

Native file writes and both endpoints of patches/moves require ownership.
Resolution failures, symlink traversal and hardlinked targets are refused.
Before exposing a writable directory to a shell, the helper rejects hardlinked
files anywhere in that directory, including generated dependencies. Recreate
such dependencies with copies rather than sharing their writable inodes.
One operation lock serializes each holder's mutations and prevents release
while a write or terminal process is active. Different holders remain parallel.

Writer terminals use bubblewrap: the host filesystem and Git metadata are
read-only, owned feature directories and ordinary tool caches are writable,
and scratch is private to the command. A private PID/proc namespace contains
descendants. Bubblewrap retains the operation lock descriptor for the sandbox
lifetime, including background and PTY execution. Missing confinement support
fails closed; a refusal never selects an unsandboxed fallback.

The native terminal adapter runs after existing authority checks. Exact claim
management argv executes outside the source sandbox with the runtime identity;
shell expressions do not receive that exemption. Explicit `git add` and
`git commit` are checked management operations: they reject unrelated staged
files and option overrides, retain Git hooks, and serialize Git mutations.
The reference-transaction guard chains the existing hook and checks the actual
commit before Git publishes it, including changes staged by earlier hooks.
Failed commits restore their original staging state without changing files.
Arbitrary commands never receive writable Git metadata.

This protects managed Hermes writers against conflicting source edits. It is
not an authentication boundary against a human or process deliberately changing
the shared filesystem outside the managed runtime. Separate clones on different
filesystems do not share claims; combine their outputs through normal review.

Python is intentional here: these are small adapters to the existing Python
Hermes tool runtime and filesystem, using its standard library. A Rust service
or separate executable would add installation and IPC without changing the
ownership protocol.

## Install and activate

The unified fleet release includes the claim helper, instructions and native
adapters in its existing reviewed install/readback/rollback transaction. For an
active fleet use `fleet-release.py plan/apply` with the normal independent
acceptance contract; the standalone installer refuses to overwrite an active
release. See [fleet maintenance](hermes-fleet.md).

For initial installation before a fleet release exists, the scoped installer
validates native source anchors before writing, retains private preimages and
supports idempotent readback:

```bash
python3 -B scripts/hermes/install-directory-claims.py
python3 -B scripts/hermes/install-directory-claims.py --check
```

Bubblewrap and Linux user/PID namespaces are required in the writer runtime.
Use refreshed workers after installation. Already-running workers and terminals
retain their previous code/access until they exit; installation alone is not
proof that enforcement is active. Follow the maintained runtime propagation
procedure in [instruction ownership](hermes-instructions.md).

Claims do not expire. After interruption, resume the original writer session,
inspect its checkout and request records, preserve/commit its unfinished work,
then release. Never steal a claim, delete its lock files, or delete/move a held
worktree. Another writer can run `recover <generation>` after the recorded
writer process has stopped. Recovery verifies the process start fingerprint,
checks no sandbox retains the operation lock and requires the original checkout
to remain available. It records its HEAD and unfinished paths and preserves all
bytes before releasing ownership. Missing process provenance requires an
operator's explicit stopped-writer check; idle age never permits reassignment.

Revert an installation using its exact preimages under
`~/.hermes/backups/directory-claims/`, then refresh the affected runtime. Retain
claim records and unfinished worktrees during rollback.
