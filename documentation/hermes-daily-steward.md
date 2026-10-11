# Hermes daily board steward

An independent, daily watchdog over every Hermes kanban board. It runs outside
the normal agent workflow: it is a cron job on the dedicated `board-steward`
profile (model `deepseek-v4.1-flash` on the opencode-go endpoint, falling back
to `gpt-6-luna` on the same endpoint), not a kanban lane, and it claims no
cards. It deliberately stays off OpenAI Codex.

Each run it:

1. reads a read-only snapshot of every board
   (`scripts/hermes/kanban-daily-steward.py`);
2. investigates each non-owner blocker read-only and releases only cards whose
   blocker is clearly gone (finished dependency, restored capacity/provider,
   evidence now present) — never an owner gate (`needs_input`, a `Hard Blocker`
   line, a pending decision) or a genuinely absent capability;
3. looks for small, conservative, repo-grounded cleanups and files at most two
   of them as low-priority cards for the otherwise-idle `local-implementer`
   (see "Opportunity cleanup");
4. sends a short report to the owner's dedicated SimpleX channel: what landed,
   what is stuck and why, which cleanup cards it filed, anything the agents are
   doing wrong, and concrete suggested behaviour changes.

## Pieces

| Piece | Location |
|---|---|
| Collector (board snapshot) | `scripts/hermes/kanban-daily-steward.py` |
| Opportunity scanner (monitor source) | `scripts/hermes/steward-opportunity-scan.py` |
| SimpleX group sender (outbound) | `scripts/hermes/simplex-send-group.sh`, `scripts/hermes/simplex_send_group.py` |
| Interactive charter (SOUL template) | `scripts/hermes/steward-soul.md` |
| Daily cron prompt | `scripts/hermes/daily-steward-prompt.txt` |
| Opportunity cron prompt | `scripts/hermes/steward-opportunity-prompt.txt` |
| Installer | `scripts/hermes/install-daily-steward.sh` |

The collector is installed to the profile's script dir
(`~/.hermes/profiles/board-steward/scripts/`) because a cron `--script` path is
resolved relative to that home; the sender stays in the shared root
(`~/.hermes/scripts/`) because it needs the bundled Python and the SimpleX
credentials, which live there, not in a profile home.

`~/.hermes` is untracked, so none of the live half survives a wipe or a rebuilt
workstation. The installer puts it back from the repository: the scripts, the
charter (`scripts/hermes/steward-soul.md` → the profile's `SOUL.md`, the
identity and the standing powers the interactive group turns run with), and the
prompt of each of the two cron jobs — the daily job and the opportunity scan.
Each piece is written only when it differs, so a second run changes nothing and
an operator can re-run it after any rebuild.

## Opportunity cleanup

The second cron job, `steward opportunity scan` (every 2h), keeps the
`local-implementer` busy with easy, safe work without stealing its slot from
urgent or sensitive tasks. Its monitor script
(`scripts/hermes/steward-opportunity-scan.py`) prints one stable
`CANDIDATE <id> <TAG> :: <detail>` line per repo cleanup it finds, and the cron
engine hashes that output byte-for-byte, so the steward model only runs when the
candidate set actually changes.

The checks are deliberately mechanical and git-backed: a script that fails
`sh -n`/`bash -n`/`py_compile` under `scripts/`, an empty tracked file, or an
untracked top-level artifact. A candidate already covered by an open
`steward-cleanup` card is omitted, so a filed finding stops appearing and does
not re-wake the agent.

For each qualifying candidate the steward files one card on the
`nixhomeserver` board:

* assignee `local-implementer`, tenant `steward-cleanup`, `--priority -10`
  (`-10` is below the default `0`, so any urgent or sensitive local card always
  runs first on the single local slot);
* `--workspace worktree`, body in the AGENTS.md slot format with a concrete
  `Verify:` command;
* `--idempotency-key steward-cleanup:<id>`, reusing the scanner's `<id>` so the
  next tick suppresses the duplicate.

Scope is the repository only. The steward never edits or files work against the
running Hermes config under `~/.hermes`; config drift is reported to the owner
in the daily report and never auto-fixed. It files nothing that needs owner
approval — no architecture, dependency/framework/runtime change, secrets,
frontend, or user-visible behaviour change.


## Powers granted by the owner (2026-10-11)

These extend the steward beyond read-only, each with the guardrail stated here.
They are the normative spec for the daily steward prompt
(`scripts/hermes/daily-steward-prompt.txt`) and the interactive charter
(`scripts/hermes/steward-soul.md`, installed to the profile's `SOUL.md`), and
the owner can withdraw any of them.

* **Board surgery** — unlink/link dependencies, promote, schedule, reassign
  between existing lanes when a card is stuck on structure or a worker-toolset
  gap. Read back before/after into a steward comment, at most three changes a
  run, never to bypass a pending owner decision or release an owner gate.
* **Retire stale asks** — mark an owner-facing ask superseded when its premise
  is provably gone or the owner has already answered and the board has recorded
  it, so it stops re-pushing. Evidence in a comment; the steward never messages
  the owner outside the daily report.
* **Restore broken live scripts** — the one narrow exception to "never touch
  `~/.hermes`": when a script under `~/.hermes/scripts/` is provably regressed
  (fails every cron run, or differs from the repository copy), restore the
  repository's file — hashes recorded, previous copy kept in scratch, same mode,
  one component per run, no restart, and never `.env`, `config.yaml`, secrets or
  credentials. A failing bounded cron job may be paused only until its fix
  lands, and must be resumed.
* **File across lanes (administrative only)** — one card per run for a lane
  other than `local-implementer`, tenant `steward-route`, restricted to
  config restore, evidence collection, mis-route correction and verification
  requests. Never implementation on privileged paths, never anything needing
  owner approval, never architecture or user-visible behaviour.
* **Alert admission** — owner-facing blockers go out as one batch, after a
  debounce, with each entry's premise machine-checked at send time, and with the
  recommended option never contradicting a decision already recorded on the card.

Owner-only, whatever else changes: deploy and switch, secrets and credentials,
document and permission grants, anything irreversible in the owner's name, and
new architecture or user-visible behaviour.

## Channel separation and the owner channel

The steward's reports go to a SimpleX **group** (id 1), and the owner replies
there — that group is the owner's separate instructions/notes channel, distinct
from head-coordinator's DM:

* the shared SimpleX bot is `head-coordinator`, which accepts DMs only
  (`SIMPLEX_ALLOWED_USERS=3`, no groups) — `kanban-owner-alerts.py` refuses to
  run if `SIMPLEX_GROUP_ALLOWED` is set there, so owner alerts stay DM-only;
* `board-steward` accepts **group 1 only** (`SIMPLEX_GROUP_ALLOWED=1`) plus a
  sender allowlist of the owner's group member id
  (`SIMPLEX_ALLOWED_USERS=SkQ1Zml3VHNrc2Q0Tmlqbw==`). A SimpleX group sender is
  identified by its group **member id**, not the DM contactId, so the group
  allowlist alone refuses the owner (`Unauthorized user: <id> (David)`) — the
  sender allowlist is what admits them. Because it holds only the member id and
  not contact 3, the steward's own bot declines DMs and they keep going to
  head-coordinator.

The owner's group messages arrive as a normal chat turn for the `board-steward`
profile (`platform_toolsets.simplex` grants it the same tools as `cli`). The
steward treats them as directives within its SOUL's hard limits — it never
deploys, reads secrets, edits `~/.hermes`, or files cards for any lane other
than `local-implementer` — and saves standing instructions to memory so later
cron runs honour them.

The member id is opaque and per-membership: if the owner leaves and rejoins the
group it changes. The steward then logs `Unauthorized user: <id> (David) on
simplex`; put the new id in `SIMPLEX_ALLOWED_USERS`. Read the current one from
that log line.

The gateway hot-reloads a profile's adapters when its `.env`/config changes; no
gateway restart is required.

## Operator steps (one time)

1. Create the profile and point it at the opencode-go tier:
   `hermes profile create board-steward --clone-from default`
   then set `model.default: deepseek-v4.1-flash` and
   `model.provider: custom:opencode-go` in
   `~/.hermes/profiles/board-steward/config.yaml`, add a `fallback_providers`
   entry of `custom:opencode-go` / `gpt-6-luna`, and add `kanban` to
   `platform_toolsets.cli`.
2. The charter is the repository file `scripts/hermes/steward-soul.md`, installed
   to `~/.hermes/profiles/board-steward/SOUL.md` by the installer in step 4; do
   not hand-write the live SOUL, or the next rebuild loses the grant.
3. Create a SimpleX group with the bot and invite the owner, then write
   `~/.hermes/profiles/board-steward/.env`:
   ```
   SIMPLEX_WS_URL=ws://127.0.0.1:5225
   SIMPLEX_GROUP_ALLOWED=1
   SIMPLEX_ALLOWED_USERS=<owner's group member id>
   SIMPLEX_HOME_CHANNEL=1
   SIMPLEX_HOME_CHANNEL_NAME=hermes-daily-steward
   OPENCODE_API_KEY=<same Zen key as the other profiles>
   ```
   The member id is not the DM contactId (3). Get it from the first group message
   the owner sends: the steward logs `Unauthorized user: <id> (David)`, and that
   `<id>` is the value to allow. Also add `simplex:` to `platform_toolsets` in the
   profile config, mirroring the `cli:` list, so group turns have the same tools.
4. Install and schedule: `sh scripts/hermes/install-daily-steward.sh`. It
   installs the scripts, the SOUL charter and both cron jobs, and refreshes the
   prompt of a job whose live text no longer matches the repository file. Re-run
   it after a wipe or a rebuild; a second run reports every piece as already
   current and edits nothing.

## Verification

```sh
python3 ~/.hermes/scripts/kanban-daily-steward.py            # snapshot renders
~/.hermes/scripts/steward-opportunity-scan.py               # candidate lines, or empty when clean
printf 'test\n' | ~/.hermes/scripts/simplex-send-group.sh 1  # exit 0, group gets it
hermes --profile board-steward cron list                     # daily 08:00 + 2-hourly monitor job
sh scripts/hermes/install-daily-steward.sh                   # idempotent: a re-run changes nothing
cmp scripts/hermes/steward-soul.md ~/.hermes/profiles/board-steward/SOUL.md  # charter matches the repo
```

The readback the installer is checked against: after it runs, the live `SOUL.md`
byte-matches `scripts/hermes/steward-soul.md`, and each live cron prompt matches
its repository file — read them from `~/.hermes/profiles/board-steward/cron/jobs.json`,
whose `prompt` field is the file's text without the trailing newline.

The scanner prints nothing when the repo is clean, which is the healthy state:
the monitor then suppresses the agent run every tick.

A green send is not proof the owner sees it; confirm the group on the phone.
