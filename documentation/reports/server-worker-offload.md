# Server execution for Hermes worker tool jobs

Investigation for card `t_a3e32aa3`. Question: can Hermes worker tool jobs
(`terminal`, file tools, `execute_code`) execute on the NixHomeServer instead of
the workstation, and what is the smallest safe path if so?

Everything below is either quoted from official docs in the installed tree or a
probe receipt from this run. No profile was migrated, no secret was read or
transferred, nothing was restarted, and no installed source was edited. There is
no overlap with `server-build-offload.md`: this report covers **tool jobs inside
a worker**, not Nix/Rust builds and validation runs.

---

## 1. Verdict

Two supported mechanisms exist and they are not alternatives to each other:

| | Remote **tools** | Remote **workers** |
|---|---|---|
| Mechanism | `terminal.backend: ssh` | Kanban dispatcher on the server |
| What moves | the `terminal`/`file`/`execute_code` tool calls | the whole worker agent process |
| Status | supported, documented, shipping | **explicitly unsupported** |

The SSH terminal backend is real, shipped and works today against this server
(§2). It is the only supported offload path, and it is sufficient for the goal:
a worker's *tool calls* run on the server while the agent loop, the kanban
lifecycle and the git workspace stay on the workstation.

Remote workers are not an option, and this is not a gap we can engineer around
in a card. Official docs, `website/docs/user-guide/features/kanban.md:1452`:

> Kanban is deliberately single-host. `~/.hermes/kanban.db` is a local SQLite
> file and the dispatcher spawns workers on the same machine. Running a shared
> board across two hosts is not supported — there's no coordination primitive
> for "worker X on host A, worker Y on host B," and the crash-detection path
> assumes PIDs are host-local. If you need multi-host, run an independent board
> per host and use `delegate_task` / a message queue to bridge them.

Two corroborating details in the installed source:

- `hermes_cli/kanban_db.py:2527` derives `host_local` from
  `claim_lock.startswith(host_prefix)`; crash detection compares a
  **host-local** PID. A remote PID is meaningless to `kill()`.
- `hermes_cli/kanban_db_dispatch.py:2835` `_default_spawn` runs
  `hermes -p <profile> chat -q ...` as a local `Popen`, pinning
  `HERMES_KANBAN_WORKSPACES_ROOT`, `TERMINAL_CWD=workspace` and
  `HERMES_KANBAN_DB` to host paths (`kanban_db_dispatch.py:2892-2929`).

`kanban-multi-gateway.md` covers several gateways **on one host** (one
dispatcher, `kanban.dispatch_in_gateway: false` elsewhere). That is not
multi-host and must not be cited as if it were.

**Board ownership stays unambiguous:** the board, the dispatcher, every worker
process, and every kanban lifecycle tool call remain on the workstation. Only
tool execution moves. Nothing about the board becomes remote or shared.

---

## 2. What the SSH terminal backend actually is

`tools/environments/ssh.py` (301 lines) plus
`tools/terminal_tool_backends.py:204` (`_build_ssh_env`). Supported values are
`ssh_host`, `ssh_user`, `ssh_port`, `ssh_key`, `ssh_persistent`
(`terminal_tool.py:760-769`). The docs page is
`website/docs/user-guide/configuration.md:471-504`.

Mechanics that matter for a worker:

- **Spawn-per-call.** Every `execute()` spawns a fresh `ssh … bash -c`; cwd and
  env persist across calls only through a session snapshot file plus in-band
  stdout markers (`ssh.py:45-51`, `base.py:358`). There is no long-lived remote
  shell in this backend, despite the older `persistent_shell` prose.
- **Connection reuse.** SSH `ControlMaster=auto`, `ControlPersist=300`,
  `BatchMode=yes`, `StrictHostKeyChecking=accept-new`, `ConnectTimeout=10`
  (`ssh.py:114-126`). Socket path is `<tmpdir>/hermes-ssh/<sha16>.sock`.
- **Workspace is remote-namespace.** `tools/file_tools_paths.py:222`
  `_resolve_ssh_path` resolves file-tool paths in the *target's* namespace;
  `terminal_tool_config.py:158` `coerce_ssh_remote_cwd` rewrites the Hermes
  host's subprocess home onto the remote `~`. A `/home/dsaw/Projects/...` path
  means that directory **on the server**.
- **Sync covers `~/.hermes` only, not the working tree.** `ssh.py:82-88` builds
  a `FileSyncManager` over `iter_sync_files("<remote_home>/.hermes")` — skills,
  credential files and cache dirs. Docs are explicit
  (`configuration.md:628`): "This covers Hermes state (`~/.hermes/`), **not**
  arbitrary working-tree files inside the sandbox — have the agent copy
  important artifacts out explicitly."
- **Sync-back on teardown** pulls changed remote `~/.hermes/` files back to the
  host, upload-only credential files never overwritten, 3 retries, default
  2 GiB cap (`file_sync.py:51-53`, `configuration.md:621-628`).

### Probe receipts (this run, 2026-10-05)

Read-only. The four `execute()` calls were `uname -sr`, `id -un; echo $HOME`,
`nproc; free -m | awk …; df -h / | awk …`, `uptime`.

Requirements check, `tools.terminal_tool_backends._check_requirements("ssh", …)`
→ `true`.

Environment bring-up and execution, `SSHEnvironment`, `cwd="~"`:

```
"cleanup": "ok"
"control_socket": "/tmp/hermes-ssh/10e9ad7e32dbdaeb.sock"
"env_class": "SSHEnvironment"
"remote_home_detected": "/home/dsaw"
"sync_manager": true
capacity  rc=0  "16\n51264\n85G"          # 16 cores, 51 GB free RAM, 85 GB free /
id_home   rc=0  "dsaw\n/home/dsaw"        #   same 238G root+store as remote-eval.sh
uname     rc=0  "Linux 6.18.48"
uptime    rc=0  "load average: 10.42, 19.66, 14.50"
```

Target: `dsaw@192.168.8.12` (the host already used by
`scripts/helpers/remote-eval.sh` and `scripts/hermes/kanban-durability-sync.sh`,
both of which resolve it from `vars.serverLanIP` / `localAdminUser`). Host load
was **already 10–20** under `nproc 16` while this probe ran, because the sibling
build-offload card is measuring the same box. That is the single most important
quota input in this report — see §5.

---

## 3. Three real defects found, all reproducible

These were found by running the backend, not by reading it. They are upstream
Hermes source (`~/.hermes/hermes-agent`), not this repo, so none can be fixed
here; they are prerequisites for any adoption.

### 3.1 ControlMaster socket path breaks under a long `TMPDIR` — blocker

First execution attempt, with this worker's own scratch TMPDIR:

```
EnvironmentConnectionError: SSH connection failed: unix_listener: path
"/home/dsaw/.hermes/profiles/standard-implementer/cache/scratch/hermes-ssh/10e9ad7e32dbdaeb.sock.j7OYS1UcHWdLvBXu"
too long for Unix domain socket
```

`ssh.py:63` puts the socket under `tempfile.gettempdir()`. The module comments
(`ssh.py:65-68`) show awareness of the 104-byte `sun_path` limit and shorten the
*filename*, but the *directory* prefix is unbounded. A profile-scoped scratch dir
is exactly the deep-prefix case, so this is not hypothetical on this install — it
is the default scratch location for a worker. Re-running with `TMPDIR=/tmp`
produced the successful receipt in §2.

**Smoke criterion:** a worker whose `TMPDIR` is a profile scratch dir must be
able to complete one `terminal` call against the server. Today it cannot.

### 3.2 Sync-back dead-ends above the 2 GiB cap — blocker for this host

On the successful teardown:

```
sync_back: remote tar is 2731642880 bytes (cap 2147483648, override with
terminal.sync_back_max_bytes) — skipping extraction
sync_back: attempt 1 failed (name 'open' is not defined), retrying in 2s
sync_back: attempt 2 failed (name 'open' is not defined), retrying in 4s
sync_back: all 3 attempts failed: name 'open' is not defined
```

The cap is expected and documented: this server's `~/.hermes` is **2.7 GB**
(`tools` 1.3 G, `hermes-agent` 788 M, `installs` 377 M, `cache` 281 M), measured
over SSH. Any sync-back attempt therefore skips.

The `NameError` is a separate real bug and I isolated it rather than guessing:

| probe | result |
|---|---|
| `open` in `file_sync` module globals | absent (`"has_own_open": false`) |
| `builtins.open` present | `true` |
| `open(<file>)` from that module's scope | `ok:64` — resolves fine |
| `_sync_back_locked`'s exact `open(lock_path, "w")` | `ok` |
| `sync_back()` with a small valid tar | returned clean |
| `sync_back()` on the cap path (`_sync_back_max_bytes()` = 2147483648) | returned clean, cap logged |

So `open` resolves correctly in isolation and both sync-back paths pass under
`-m`. The `NameError` appeared only in the live SSH teardown, after the cap
warning, three times. Two possibilities remain and I could not separate them
without editing installed source, which is out of scope here:

- it is specific to the real SSH `cleanup()` call path (threaded gateway-style
  teardown, where a module global is rebound), or
- it is a downstream consequence of the skipped extraction leaving the manager
  in a state where a later `open` lookup fails.

Either way: **teardown against this server does not complete cleanly today.** It
fails loudly (warning + non-fatal), so it is not a data-loss path, but it is not
a path we can put unattended workers on.

### 3.3 The workspace does not exist on the server — the blocker that is ours

```
MISSING /home/dsaw/Projects/NixOS
MISSING /home/dsaw/Projects/NixOS/.worktrees/t_a3e32aa3
```

The server's `/home/dsaw` holds only Qwen build artifacts (`qwen-build*`,
`qwen-*.nix`, `data`). There is no checkout, no worktrees, no `~/Projects`.

This is not a Hermes limitation, it is source-transfer design, and it is the
whole content of the implementation work: `_resolve_ssh_path` resolves the
worker's paths in the remote namespace, so every path the worker uses must exist
there. The repo's own tooling already solves the immutable-transfer half of this
— `scripts/helpers/remote-eval.sh` ships a tracked-only archive via
`create_deploy_repo_archive` (which refuses `secrets/unencrypted` and
`SensitivePrivateSecrets`, so only ciphertext crosses), stages it, evaluates, and
traps removal. That is the pattern to reuse, not a new transport.

---

## 4. Workspace, sync, cancellation, disconnect

**Per-task workspace.** The dispatcher already pins `TERMINAL_CWD=workspace`
(`kanban_db_dispatch.py:2908`), and `_ssh_remote_anchor`
(`file_tools_paths.py:172`) reads exactly that value in raw form. So the
workspace path is *already* threaded correctly — it just points at a directory
the server does not have. Under the SSH backend each task therefore needs its
own remote directory, created at dispatch-equivalent time and named from the task
id. Two workers must never share one, because SSH has no per-task container
isolation: cwd is a single value per session snapshot
(`base.py:266-269`), so concurrent sessions that resolve to the same remote
directory would collide on `cd` and writes exactly as the docs warn for shared
Docker containers (`configuration.md:434`).

**Source transfer.** Archive the tracked tree (reusing
`create_deploy_repo_archive` semantics), place it under a per-task remote
directory, and never interpolate operator text into the remote command line —
`remote-eval.sh:134-144` already does the stdin/staging dance correctly. A
`path:` flake reference is safe precisely because the archive is tracked-files
only.

**Result sync.** This is the asymmetry to design around. `~/.hermes` syncs both
ways automatically; **the working tree does not sync at all**. Results therefore
have to come back explicitly, by the same `scp`/tar mechanism, and
`kanban_attach` for real deliverables. Nothing is needed from Hermes itself —
but a report must not assume the commit came back for free.

**Cancellation.** Two independent mechanisms, and only one is real over SSH:

- Hermes-side: `task.max_runtime_seconds` caps wall clock regardless of PID
  liveness, and `dispatch_stale_timeout_seconds` (5400 on this install,
  `config.yaml:460`) SIGTERMs a stale worker — but the SIGTERM targets a
  **host-local PID**, so it kills the agent loop on the workstation, not the
  remote command.
- Remote-side: killing the `ssh` client does not necessarily kill the remote
  process. `process_registry.py:554` records `pid_scope="sandbox"` for
  env-local PIDs, and `_ssh_bulk_upload` already needs an explicit remote kill
  pattern for its own `tar`/`ssh` pair (`ssh.py:229-236`). A cancelled worker can
  therefore leave orphans on the server. Remote jobs need their own bounded
  `timeout` and cleanup, and the design must state where the kill actually lands.

**Disconnect recovery.** A dropped connection is not a lost task: the next
`execute()` re-establishes (`_establish_connection`, `ssh.py:137`) and
`ControlPersist=300` keeps the master warm for 5 minutes. What a *long* gap costs
is the ControlMaster socket: past 300 s idle, or if the master dies, the next
command pays a fresh connection — and the path-length bug in §3.1 can bite again
on every reconnect. There is no cross-restart recovery of remote state; the
session snapshot is a temp file (`base.py:267`) and is gone with the process.

---

## 5. Trust, credentials, quotas, observability

**Network trust.** The channel is plain LAN SSH to `192.168.8.12` as `dsaw` —
the same uid that owns the deployment, holds `NOPASSWD ALL`, and runs the
Guarded deploy. Offloading tool jobs to this backend does **not** reduce the
blast radius of a compromised agent: it can already run arbitrary commands
locally as the same user. What it does change is that the server's 125 GB / 16
cores and every live service on it become reachable from agent code. Treat the
SSH backend as "same trust as local, different host", and do not let it be
described as hardening. The docs make the same point for the gateway
(`security.md:902`): network isolation keeps the *gateway's* messaging separate
from command execution, not the agent away from the host.

**Credentials boundary.** Two mechanisms, both fail-safe in the right direction:

- *Passthrough is explicit.* Only skill-declared
  `required_environment_variables` and `terminal.env_passthrough` are forwarded,
  by OpenSSH `SendEnv` **name**, with values travelling in the client
  environment and never in remote command text (`ssh.py:278-288`). Provider
  credentials are never forwarded even when listed (`configuration.md:504`).
  Names missing from the active profile scope are explicitly *unset* remotely, so
  a shared host cannot serve another profile's value.
- *Credential files are upload-only.* Sync-back never overwrites them on the
  host (`configuration.md:623`, `file_sync.py:152`).

Concrete blocker for this host: **`AcceptEnv` is absent.**
`grep -c AcceptEnv /etc/ssh/sshd_config` → `0` (exit 1, no matches), and there is
no `/etc/ssh/sshd_config.d`. So even a correctly configured passthrough would be
silently dropped by sshd. Adding it needs `sudo` on the server, which this card
is explicitly not authorised to do — hence the gate in §7.

**Resource quotas.** This is where the evidence argues against going fast.
`TERMINAL_CONTAINER_CPU` / `_MEMORY` / `_DISK` are documented as "ignored for
local/ssh" (`config.yaml:564`). The SSH backend has **no** resource-control knob
at all. What does bound a worker is `process_registry.py:116`
`_worker_memory_max_bytes()` — `TERMINAL_LOCAL_MEMORY_MAX_MB`, honoured only
when it *tightens* a safe bound (min of the enclosing cgroup `memory.max` and
half of RAM, hard-capped at 4 GiB) — and that too is a **local** cgroup bound. On
the server side nothing equivalent applies: `nice`/`ionice` are not requested by
the backend, and no `systemd-run` scope is created for remote commands. Measured
load was already 10–20 on 16 cores during this run. Any adoption must therefore
set explicit `nice`/`ionice` and a bounded timeout **inside the command**; the
backend will not do it, and the server's live services plus the guarded shutdown
timer are the thing being protected.

**Observability.** Worker stdout/stderr already goes to
`<board-root>/logs/<task_id>.log`, and `task_runs` carries `log_path`, exit code,
summary and metadata (`kanban-worker-lanes.md:99-105`); `hermes kanban tail` and
`hermes kanban runs` read them. For remote jobs the audit trail stays on the
workstation, because the worker is. What is *not* observable today is remote
side state: an orphaned remote process after a cancel leaves no board row.

---

## 6. Recommendation: smallest safe path

**Recommendation: keep tool jobs on the workstation, and do not adopt the SSH
terminal backend for workers yet.** Not because the backend is bad — it works
(§2) — but because the three prerequisites in §3 are all unmet, two of them are
upstream defects we cannot fix from this repo, and the third (workspace transfer)
is real work whose payoff is unproven while the server is already the bottleneck
for builds.

The offload we already have is `scripts/helpers/remote-eval.sh`: immutable
tracked-only archive, single batched `nix eval` on the server, `REMOTE_EVAL=0`
local fallback, fails closed. It moves the expensive, bounded, side-effect-free
work and leaves the git workspace and board where they belong. That is the right
shape, and the sibling `server-build-offload.md` report covers extending it.

If the owner wants tool offload anyway, the smallest safe path is a
**project-scoped helper in this repo, not a `terminal.backend` flip** — the same
shape as `remote-eval.sh`, so it is one auditable script rather than a
process-wide backend change affecting every tool call in every session:

1. Ship the tracked archive to a per-task remote directory.
2. Run one bounded command inside it with explicit `nice`/`ionice` and a timeout.
3. Stream the result back; let the commit stay on the workstation.

A `terminal.backend: ssh` flip is global per profile, would move *every* tool
call including the guarded-deploy helpers, and would put the guardrails of §5
(git, kanban, agenix) on a host that holds all of them.

### Implementation slices (each file-owned, chain where shared)

| # | Slice | Files | Depends on |
|---|---|---|---|
| S1 | `remote-exec.sh`: archive → per-task remote dir → bounded run → result back | `scripts/helpers/remote-exec.sh`, `scripts/tests/test-remote-exec.sh`, `run-script-tests.sh` | — |
| S2 | Wire `remote_exec_batch` into the shell regression suite | `scripts/tests/test-common.sh` | S1 |
| S3 | Worker guidance so ordinary tasks actually use the path | `AGENTS.md` | S1 |
| S4 | Report the SSH-backend defects upstream, with these receipts | no repo change | — |
| S5 | Live acceptance: one real remote job, artifacts returned, local load down | — | S1–S3, owner approval |

S1 is the only card with real design content. S4 is worth doing regardless of
the verdict and is nearly free — the §3.1 receipt is a clean upstream bug
report.

### Real smoke criteria

- `bash scripts/tests/test-remote-exec.sh` exits 0, and its fixture asserts a
  transfer failure returns non-zero with **no** output (fails closed, like
  `remote-eval.sh:26-29`).
- With the server unreachable, the helper falls back or fails closed — it never
  reports an empty result as success.
- A live run returns its artifact to the workstation, and the workstation does
  not run the command locally.
- `create_deploy_repo_archive` still refuses `secrets/unencrypted` and
  `SensitivePrivateSecrets`; nothing but ciphertext crosses.

### Explicit human gates

These are decisions, not implementation, and belong to the owner:

1. **Add `AcceptEnv` to the server's `sshd_config`** (requires sudo; currently
   absent, §5). Needed for any skill passthrough. Without it, pass a credential
   in-band or not at all.
2. **Grant the server-side job a resource envelope** — `nice`/`ionice`, a
   timeout, and agreement on whether the SSH uid may be a non-`dsaw` principal.
   The backend offers no knob; §5 measured the box is already loaded.
3. **Decide whether agent-reachable server access is acceptable at all.** §5:
   same uid, sudo-capable, all services. A restricted SSH principal with a
   dedicated remote workspace would reduce blast radius and is an architectural
   change.
4. **Accept or reject raising `terminal.sync_back_max_bytes`** above 2 GiB
   (§3.2). Default is to leave it; the cap is what stopped a 2.7 GB transfer.

---

## 7. Evidence index

Official docs, installed tree `~/.hermes/hermes-agent` (v0.21.5+7015.ga68b467,
upstream `af8839df`), also fetched live from
`https://hermes-agent.nousresearch.com/docs/llms.txt`:

- `website/docs/user-guide/configuration.md:471` — SSH backend, env vars, passthrough
- `website/docs/user-guide/configuration.md:621` — remote-to-host state sync on teardown
- `website/docs/user-guide/features/tools` — terminal backends overview
- `website/docs/user-guide/features/kanban.md:1452` — single-host by design
- `website/docs/user-guide/features/kanban-worker-lanes.md:33-47` — spawn mechanism and pinned env
- `website/docs/user-guide/features/kanban-multi-gateway.md` — one host, one dispatcher
- `website/docs/user-guide/security.md:902` — network isolation
- `website/docs/guides/secure-hermes-on-a-work-machine.md:95`

Installed source:

- `tools/environments/ssh.py` — the backend; `:63` tmpdir socket, `:114` ssh flags, `:278` SendEnv
- `tools/terminal_tool_backends.py:54,204,301` — backend list, builder, requirements
- `tools/file_tools_paths.py:172,222` — remote-namespace path resolution
- `tools/terminal_tool_config.py:158` — cwd coercion onto remote `~`
- `tools/environments/file_sync.py:51,299,367` — sync-back cap, retries, lock
- `tools/environments/base.py:260,358` — session snapshot, cwd marker
- `tools/process_registry.py:116,554` — memory bound, sandbox pid scope
- `hermes_cli/kanban_db_dispatch.py:2835` — local `Popen` spawn, workspace pins
- `hermes_cli/kanban_db.py:2527` — `host_local` claim-lock prefix

Repo:

- `scripts/helpers/remote-eval.sh` — existing tracked-only transfer pattern
- `scripts/hermes/kanban-durability-sync.sh:177,505` — existing BatchMode SSH to the same host
- `vars.nix:62,70` — `localAdminUser`, `serverLanIP`
- `config.yaml:460` — `dispatch_stale_timeout_seconds: 5400`; `:464-493` terminal block, ssh option 2

Probes run this session (all read-only; no writes on the server):

| probe | result |
|---|---|
| `ssh … 'uname -sr; id -un; nproc; free -g; df -h; uptime'` | 16 cores, 125 G, 238 G/63 %, load 0.27 |
| `ssh … 'hermes --version'` | vgit.d0288be, source checkout present |
| `ssh … 'ls ~/.hermes/profiles; ls -la ~/.hermes/kanban.db'` | no profiles, **no kanban.db** |
| `ssh … 'du -sh ~/.hermes; du -sh ~/.hermes/*'` | 2.7 G total |
| `ssh … 'grep -c AcceptEnv /etc/ssh/sshd_config'` | `0`, exit 1 |
| `ssh … 'ls -d ~/Projects/NixOS …'` | both MISSING |
| `_check_requirements("ssh", …)` | `true` |
| `_create_environment("ssh", …)` + 4 read-only `execute()` + `cleanup()` | receipt in §2 |
| `open`-scope probes (3 variants) | `has_own_open: false`, `module_scope_open: ok`, `lockfile_open: ok` |
| `sync_back()` small-tar repro | returned clean |
| `sync_back()` cap-path repro (3 GiB, cap 2 GiB) | returned clean, cap logged |

Not done, deliberately: no `terminal.backend` change, no profile migration, no
`AcceptEnv` edit, no sudo, no restart, no installed-source edit, no heavy build
probe, no overlap with `server-build-offload.md`.
