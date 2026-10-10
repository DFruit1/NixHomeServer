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
| Daily cron prompt | `scripts/hermes/daily-steward-prompt.txt` |
| Opportunity cron prompt | `scripts/hermes/steward-opportunity-prompt.txt` |
| Installer | `scripts/hermes/install-daily-steward.sh` |

The collector is installed to the profile's script dir
(`~/.hermes/profiles/board-steward/scripts/`) because a cron `--script` path is
resolved relative to that home; the sender stays in the shared root
(`~/.hermes/scripts/`) because it needs the bundled Python and the SimpleX
credentials, which live there, not in a profile home.

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


## Channel separation

The steward's reports go to a SimpleX **group** (id 1), never the owner DM:

* the shared SimpleX bot is `head-coordinator`, which accepts DMs only
  (`SIMPLEX_ALLOWED_USERS=3`, no groups) — `kanban-owner-alerts.py` refuses to
  run if `SIMPLEX_GROUP_ALLOWED` is set there, so owner alerts stay DM-only;
* `board-steward` has its own SimpleX binding (`.env`) that accepts **only**
  group 1 (`SIMPLEX_GROUP_ALLOWED=1`, no DM allowlist), so group traffic and
  owner replies never mix with head-coordinator's DM.

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
2. Overwrite its SOUL with the steward identity (see the installed
   `~/.hermes/profiles/board-steward/SOUL.md`).
3. Create a SimpleX group with the bot and invite the owner, then write
   `~/.hermes/profiles/board-steward/.env`:
   ```
   SIMPLEX_WS_URL=ws://127.0.0.1:5225
   SIMPLEX_GROUP_ALLOWED=1
   SIMPLEX_HOME_CHANNEL=1
   SIMPLEX_HOME_CHANNEL_NAME=hermes-daily-steward
   OPENCODE_API_KEY=<same Zen key as the other profiles>
   ```
4. Install and schedule: `scripts/hermes/install-daily-steward.sh`.

## Verification

```sh
python3 ~/.hermes/scripts/kanban-daily-steward.py            # snapshot renders
~/.hermes/scripts/steward-opportunity-scan.py               # candidate lines, or empty when clean
printf 'test\n' | ~/.hermes/scripts/simplex-send-group.sh 1  # exit 0, group gets it
hermes --profile board-steward cron list                     # daily 08:00 + 2-hourly monitor job
```

The scanner prints nothing when the repo is clean, which is the healthy state:
the monitor then suppresses the agent run every tick.

A green send is not proof the owner sees it; confirm the group on the phone.
