# Server build and validation offloading — evidence and implementation slices

Card: `t_3a905328` (investigation). Implementation consumer: `t_3dba2417`.

All numbers below are receipts from read-only probes and one bounded build smoke
on this workstation (`/home/dsaw/Projects/NixOS/.worktrees/t_3a905328`, branch
`wt/t_3a905328`) against the live server at `dsaw@192.168.8.12`. No deploy, no
`sudo` expansion, no credential reads, no concurrent heavy gates. Raw probe logs
live under the worker scratch dir (`offload-probe*.sh`, `probe11.out`,
`smoke-repo-policy.log`) and are summarised per claim below.

## Verdict

Two offload paths already exist and both work. Neither is new infrastructure:

| Path | Mechanism | Status | Measured payoff |
|---|---|---|---|
| Evaluation | `scripts/helpers/remote-eval.sh` → `remote_eval_batch_json` | Working, used by `scripts/tests/test-common.sh` | 3.9x on full system eval |
| Build | `~/.config/nix/nix.conf` `builders = ssh-ng://server …` (and deploy's own `NIX_CONFIG`) | Working, pre-existing | Workstation stays at `max-jobs = 1` |

The gap is not capability. It is that **ordinary use of these paths is
undocumented for workers**, and that **the two paths disagree about which
workload belongs where** — `validate-repo.sh --build-checks` still evaluates and
builds on the workstation, where it is slowest, and the Attic cache the deploy
path depends on is only pushed from the workstation.

## Capacity, measured

Workstation (2026-10-05T14:16+11:00 and 14:34):

    4 cores, 11 GiB RAM (6 used at rest)
    / 100G, 59G free
    nix: max-jobs = 1, cores = 0

Server (2026-10-05T14:16+11:00):

    AMD Ryzen 7 5700X, 16 cores
    125 GiB RAM total, 47 GiB available, 31 GiB swap unused
    / 238G, 89G free at rest; /nix/store 69G
    load average 0.07 / 0.20 / 0.16  (idle)
    nix: max-jobs = 2, cores = 4, builders = (empty, i.e. a leaf)
    sandbox = true, sandbox-fallback = false, require-sigs = true

The server is a strict superset for this workload and is idle when not building.
Its own `max-jobs = 2` is the current ceiling on how much the workstation's
`builders` line can actually consume — the `16 16` in `~/.config/nix/nix.conf`
is a *request*, not a grant.

Server-side safety state observed:

    /var/lib/nixhomeserver-deploy-archives  mode 700, owner dsaw  (empty)
    systemd-tmpfiles --cat-config | grep nixhomeserver-deploy-archives
      -> d /var/lib/nixhomeserver-deploy-archives 0700 dsaw dsaw mM:48h -
    atticd.service                        active running, 127.0.0.1:8080
    attic-cache-bootstrap.service          active exited
    nixhomeserver-shutdown-guard          inactive (no guard armed at probe time)

## Path 1 — evaluation offload (existing, working)

`scripts/helpers/remote-eval.sh` stages the tracked tree with
`create_deploy_repo_archive`, transfers it through `stage_archive_on_remote`,
evaluates on the server against `path:<staged dir>`, and deletes the staged
directory via a remote `trap … EXIT`. Query bodies travel on stdin, never
interpolated into the remote command line.

Measured (`time remote_eval_batch_json …`, same three queries both ways):

| Query class | Remote | Local | Ratio |
|---|---|---|---|
| `lib.nixhomeserverSettings` only (3 queries, one batch) | 2.27 s | 1.68 s | 0.7x — slower |
| `nixosConfigurations…config.networking.hostName` | 2.22 s | 2.07 s | ~1x — cached |
| `nixosConfigurations…system.build.toplevel.drvPath` | **19.2 s** | **74.1 s** | **3.9x faster** |

Both sides returned the identical `toplevelDrv`:
`/nix/store/bk3pyp14gwfz3yhrg497fqjqc7k9f0ib-nixos-system-server-26.05.20260829.c5c4a43.drv`.

Reading: offload pays for itself exactly when the evaluation forces the module
system to instantiate the whole host configuration. Settings-level queries are
already served from the local eval cache in ~2 s and the extra SSH round trip is
a small net loss. **This is why batching matters more than offloading**: three
thin queries in one `remote_eval_batch_json` cost one module instantiation
instead of three.

Failure behaviour is fail-closed by construction and was observed live. A
malformed query of mine (`vars.system.buildMode`, where `vars` is not bound in
the `f`-scoped expression) produced a non-zero exit, no stdout payload, a
`remote-eval: falling back to local evaluation (…)` note on stderr, and then a
local evaluation that failed the same way — a transport error can never be read
as an empty result.

Cleanup verified: after all probes,
`ls -d /tmp/nixhomeserver-remote-eval.*` on the server returned 0 entries and no
`/tmp/nixhomeserver-*.tar` remained.

## Path 2 — build offload (existing, working)

`~/.config/nix/nix.conf` already declares the server as an `ssh-ng://` builder
with a pinned identity file and a base64 host key. `deploy-executor.sh`
independently exports `max-jobs`, `cores`, `builders` and
`builders-use-substitutes` in `NIX_CONFIG` per build mode
(`configure_nix_build_allocation`, line 174), which overrides the user config —
so guarded deploys are unaffected by the ambient file, and `switch` skips
allocation setup entirely because it reuses the tested closure
(`configure_nix_build_allocation_for_action`, line 279).

Bounded smoke — `.#checks.x86_64-linux.repo-policy`, chosen because a store-path
sweep of all 48 checks confirmed it was one of exactly five not yet present:

    nix build .#checks."x86_64-linux".repo-policy -L --no-link
    exit=1 elapsed=540s
    log: building '/nix/store/6s5hw3cinc75j078g68b4n6aj12z9iwd-repo-policy.drv'
         on 'ssh-ng://server'...
    server store gained …-repo-policy.drv.chroot (sandbox active)
    workstation during the run: load average 14.48 / 18.07 / 12.58
    server during the run:     load average 26.06 / 22.17 / 12.65

The derivation demonstrably ran on the server inside its sandbox. Both machines
were loaded because a sibling card's full 48-check build was running
concurrently — that is a measurement caveat, not an offload failure.

The smoke **failed**, and the failure is the most useful finding in this report.
27 test scripts failed inside the sandbox. Two sampled failures reproduce
perfectly on the workstation and pass there:

| Failure inside remote sandbox | Same test, workstation |
|---|---|
| `cargo is not installed or not on PATH` (`test-rust-workspace-dependencies.sh`) | exit 0 |
| `no systemd-tmpfiles binary available to prove expiry` (`test-deploy-archive-staging.sh`) | exit 0 |

Others (`hermes CLI not found`, NetBird, bootstrap secrets, shutdown-guard) are
the same class: the derivation's sandbox has no `PATH` into the invoking user's
tools. So **remote build offload is correct for compilations, not for the repo's
own shell test suite.** `validate-repo.sh` already reflects this instinct —
`repo-policy` is explicitly excluded from `--build-checks` and run directly. The
offload path was never wrong; the check-name filter is just incomplete and
undocumented as a rule.

## Path 3 — cache reuse (Attic), and its one real asymmetry

Attic is healthy: `atticd` serving on `127.0.0.1:8080`, `/var/lib/atticd` at
44 GiB, bootstrap service exited clean. The workstation reaches it through an
SSH forward (`127.0.0.1:8080` owned by `ssh`), and `nix-cache-info` over that
forward returns `WantMassQuery: 1 / StoreDir: /nix/store / Priority: 39`. Both
ends list `http://127.0.0.1:8080/nixhomeserver` as a substituter, so a path built
on either machine is fetchable by the other.

The asymmetry: the **push** hook exists only on the workstation.

    workstation ~/.config/nix/nix.conf
      post-build-hook = /home/dsaw/.local/bin/nixhomeserver-attic-post-build
    server /etc/nix/nix.conf
      post-build-hook = /nix/store/hvbxhi…-nixhomeserver-attic-post-build

Both hooks exist, but the server has no Attic credentials (`/home/dsaw/.config/attic/`
is empty, no root credentials, `attic cache info` reports "No servers are
available", and `journalctl -u atticd --since -6h` has zero entries). So after a
remote build the server keeps the path locally and returns it to the workstation
over SSH, but never lands it in the shared cache for the *next* cold build.
That is a throughput leak, not a correctness bug — every repeat still hits the
server's store first via `builders-use-substitutes = true`.

## Comparison

| Workload | Best path | Why |
|---|---|---|
| Settings-level `nix eval` | workstation (or `nix_eval_with_optional_cache`) | cached; SSH round trip costs more than the eval |
| Full `nixosConfigurations` eval | server, batched | 74 s → 19 s |
| Rust / frontend compilations | server as `builders` target | 16 cores, sandboxed, RAM headroom |
| `scripts/tests/*` shell suite | workstation | sandbox has no user `PATH`; 27 scripts prove it |
| Reproducible Nix derivation builds | either, cache makes it moot | Attic serves both ends over the 8080 forward |

## Slices (each file-owned, with an exact verify command)

S1 — **Document the offload decision table for workers.**
Files: `documentation/operations.md`, `AGENTS.md` (one short subsection).
Change: the table above, plus the rule "batch every evaluation query into one
`remote_eval_batch_json` call".
Verify: `bash scripts/tests/test-runtime-reliability.sh` — exit 0.
Why first: it is what makes ordinary future tasks actually use the paths.

S2 — **State the sandbox-`PATH` rule where the check filter lives.**
Files: `scripts/validate-repo.sh` (the `--build-checks` exclusion loop, ~line 183).
Change: replace the single `repo-policy` special case with a documented
exclusion list naming the class — "derivations that shell out to workstation
tools" — and reference it from the header.
Verify: `scripts/validate-repo.sh` (lean) — exit 0.

S3 — **Make remote cache pushes actually land.**
Files: `modules/attic/identity.nix` only (a root-owned Attic credential +
`post-build-hook` wiring for the server daemon). **Gated: moves a credential.**
Change: give the server's root daemon push rights to the `nixhomeserver` cache.
Verify: on the server, `sudo -n attic push --no-closure --jobs 1 nixhomeserver <path>`
— exit 0; then `journalctl -u atticd --since -5m` shows the path.
Requires an owner gate on credential movement (see `t_3dba2417`).

S4 — **Close the server `max-jobs = 2` gap.**
Files: `modules/Core_Modules/base-system/default.nix` (the `nix.*` block).
Change: raise the server's `max-jobs` so the workstation's 16-slot request is not
silently truncated to 2.
Verify: `nix eval --raw .#nixosConfigurations.server.config.nix.settings.max-jobs`
— a value > 2; then lean validation.
Verify is the check; do not raise it while a sibling card's full build runs.

S5 — **Route `validate-repo.sh --build-checks` evaluation through the server.**
Files: `scripts/validate-repo.sh` only.
Change: build the check worklist with `remote_eval_batch_json` instead of a local
evaluation; keep the `nix build` itself as-is.
Verify: `scripts/validate-repo.sh --build-checks` — exit 0, and the worklist
construction emits `remote-eval:` on stderr when it actually went remote.

Sequencing: S1 unblocks adoption, S2 and S5 are independent of each other, S4 is
one line but must not run during another card's build, S3 is owner-gated.

## Failure behaviour and limits, for the implementation card

- Remote eval and remote build are already fail-closed: non-zero, no payload.
  Ambient `builders` never applies to a guarded deploy — `NIX_CONFIG` wins.
- Cancellation is SSH-session-bound. Both paths clean up on session loss, and the
  archive namespace additionally expires at `mM:48h` via systemd-tmpfiles (rule
  confirmed live through `systemd-tmpfiles --cat-config`, not `/etc/tmpfiles.d`).
- Quotas: server `/` had 89G free at rest and 85G after my smoke. There is no
  enforced per-task quota on the offload paths today — only the deploy
  preflight's 10 GiB floor (`min_build_host_free_bytes`). Any slice wanting hard
  quotas must add them, not assume them.
- Isolation: the server builds in `sandbox = true, sandbox-fallback = false`
  sandboxes as root. It runs the *same* source as the workstation because the
  archive is built from the Git worktree, which refuses non-tracked files and
  `secrets/unencrypted`.

## Deliberately not done

- No deploy, no guarded test/switch, no `nixhomeserver-shutdown-guard extend`.
  A sibling card held a 48-check build for most of this probe window; adding
  gates alongside it would have produced misleading timings.
- No `validate-repo.sh` run of any tier. This card's deliverable is a report.
- No Attic credential creation or any credential read (S3 is left gated).
- `nixos-rebuild dry-run` on the server fails independently of this work —
  `/nix/store/0ccnxa25…-source/flake.nix` is missing for `path:/etc/nixos`.
  Pre-existing and unrelated; not investigated.

## Residual risk

- Timings came from a shared, concurrently loaded machine. The 3.9x evaluation
  ratio is large enough to survive that noise; the `max-jobs = 1` vs `2`
  throughput numbers should not be quoted as benchmarks.
- The 27 failing sandbox scripts were sampled, not triaged one by one. Two were
  reproduced and explained; the rest are asserted to be the same missing-`PATH`
  class on the strength of their messages (`hermes CLI not found`, NetBird,
  bootstrap secrets). S2 should confirm before the exclusion list is widened.
- `nix-eval-jobs` is not installed on the server, so the alternative "carry the
  evaluation inside a derivation" route mentioned in the workstation `nix.conf`
  comment is untested and unused.
