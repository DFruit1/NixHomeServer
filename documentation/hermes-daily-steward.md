# Hermes daily board steward

An independent, daily watchdog over every Hermes kanban board. It runs outside
the normal agent workflow: it is a cron job on the dedicated `board-steward`
profile (model `gpt-6-luna`), not a kanban lane, and it claims no cards.

Each run it:

1. reads a read-only snapshot of every board
   (`scripts/hermes/kanban-daily-steward.py`);
2. investigates each non-owner blocker read-only and releases only cards whose
   blocker is clearly gone (finished dependency, restored capacity/provider,
   evidence now present) — never an owner gate (`needs_input`, a `Hard Blocker`
   line, a pending decision) or a genuinely absent capability;
3. sends a short report to the owner's dedicated SimpleX channel: what landed,
   what is stuck and why, anything the agents are doing wrong, and concrete
   suggested behaviour changes.

## Pieces

| Piece | Location |
|---|---|
| Collector (board snapshot) | `scripts/hermes/kanban-daily-steward.py` |
| SimpleX group sender (outbound) | `scripts/hermes/simplex-send-group.sh`, `scripts/hermes/simplex_send_group.py` |
| Cron prompt | `scripts/hermes/daily-steward-prompt.txt` |
| Installer | `scripts/hermes/install-daily-steward.sh` |

The collector is installed to the profile's script dir
(`~/.hermes/profiles/board-steward/scripts/`) because a cron `--script` path is
resolved relative to that home; the sender stays in the shared root
(`~/.hermes/scripts/`) because it needs the bundled Python and the SimpleX
credentials, which live there, not in a profile home.

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

1. Create the profile and keep the luna-6 model:
   `hermes profile create board-steward --clone-from default`
   then set `model.default: gpt-6-luna` in
   `~/.hermes/profiles/board-steward/config.yaml` and add `kanban` to
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
   ```
4. Install and schedule: `scripts/hermes/install-daily-steward.sh`.

## Verification

```sh
python3 ~/.hermes/scripts/kanban-daily-steward.py            # snapshot renders
printf 'test\n' | ~/.hermes/scripts/simplex-send-group.sh 1  # exit 0, group gets it
hermes --profile board-steward cron list                     # job present, daily 08:00
```

A green send is not proof the owner sees it; confirm the group on the phone.
