#!/bin/sh
# Install the independent daily board steward.
#
# What this does:
#   * installs the steward scripts into the shared root and the board-steward
#     profile's script dir;
#   * installs the steward's interactive charter from the repository to the
#     profile's SOUL.md;
#   * creates the daily 08:00 report cron job and the monitor-gated 2-hourly
#     opportunity scan under the board-steward profile, and refreshes the
#     prompt of an existing job when the repository's prompt file has moved on.
#
# Everything here is idempotent: a file is written only when it differs and a
# cron prompt is edited only when the live text no longer matches the repo, so
# a second run changes nothing.
#
# What this does NOT do (operator steps, one time):
#   * create the board-steward profile and give it the opencode-go tier
#     (deepseek-v4.1-flash, fallback gpt-6-luna, both on opencode-go);
#   * create the SimpleX group channel and bind it in the profile .env.
#   See documentation/hermes-daily-steward.md for the exact steps.
set -eu
root="${HERMES_ROOT:-$HOME/.hermes}"
repo="${REPO_DIR:-$HOME/Projects/NixOS}"
profile="board-steward"
src="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"

install -d -m 700 "$root/scripts"
install -m 700 "$src/simplex_send_group.py" "$root/scripts/simplex_send_group.py"
install -m 755 "$src/simplex-send-group.sh" "$root/scripts/simplex-send-group.sh"
install -m 755 "$src/kanban-daily-steward.py" "$root/scripts/kanban-daily-steward.py"
install -m 755 "$src/steward-opportunity-scan.py" "$root/scripts/steward-opportunity-scan.py"
install -d -m 700 "$root/profiles/$profile/scripts"
install -m 755 "$src/kanban-daily-steward.py" "$root/profiles/$profile/scripts/kanban-daily-steward.py"
install -m 755 "$src/steward-opportunity-scan.py" "$root/profiles/$profile/scripts/steward-opportunity-scan.py"
echo "installed steward scripts under $root"

# The charter. SOUL.md is the identity the interactive group turns run with and
# the standing powers the daily job inherits; a rebuilt or wiped profile loses
# it, so it is restored from the repository. Unchanged content is left alone.
soul="$root/profiles/$profile/SOUL.md"
if [ -f "$soul" ] && cmp -s "$src/steward-soul.md" "$soul"; then
    echo "SOUL.md already current for $profile"
else
    install -d -m 700 "$root/profiles/$profile"
    install -m 600 "$src/steward-soul.md" "$soul"
    echo "installed SOUL.md for $profile"
fi

# Prompt sync. The old guard skipped any job that already existed, so a prompt
# edit never reached the live job; the job id is therefore read from the cron
# store itself (a JSON file this host owns) rather than parsed out of
# `hermes cron list`, whose renderer is not ours to depend on. The prompt is
# rewritten only when it differs, and only for the two jobs this installer owns.
jobs="$root/profiles/$profile/cron/jobs.json"

# Prints "<job id> current", "<job id> stale", "missing" when no job of that
# name exists, or "unreadable" when the store cannot be parsed.
job_prompt_state() {
    python3 - "$jobs" "$1" "$2" <<'PY'
import json
import pathlib
import sys

jobs_path, name, prompt_path = sys.argv[1], sys.argv[2], sys.argv[3]
try:
    store = json.loads(pathlib.Path(jobs_path).read_text())
except (OSError, ValueError):
    print("unreadable")
    raise SystemExit(0)
try:
    desired = pathlib.Path(prompt_path).read_text().rstrip("\n")
except OSError:
    print("unreadable")
    raise SystemExit(0)
for job in store.get("jobs", []):
    if job.get("name") == name:
        stored = str(job.get("prompt") or "").rstrip("\n")
        state = "current" if stored == desired else "stale"
        print("{} {}".format(job.get("id", ""), state))
        raise SystemExit(0)
print("missing")
PY
}

create_daily_steward_job() {
    prompt="$(cat "$src/daily-steward-prompt.txt")"
    hermes --profile "$profile" cron create "0 8 * * *" "$prompt" \
        --name "hermes daily steward" \
        --script kanban-daily-steward.py \
        --workdir "$repo" \
        --deliver local
    echo "created cron job 'hermes daily steward' for $profile"
}

# The opportunity scan is monitor-gated: the scanner emits one stable
# CANDIDATE line per repo cleanup it finds, the cron engine hashes that output
# byte-for-byte, and the agent only runs when the set of candidates changes.
# It files low-priority (tenant steward-cleanup, -10) cards for the local
# implementer and never touches the running Hermes config.
create_opportunity_job() {
    opp_prompt="$(cat "$src/steward-opportunity-prompt.txt")"
    hermes --profile "$profile" cron create "every 2h" "$opp_prompt" \
        --name "steward opportunity scan" \
        --monitor-script steward-opportunity-scan.py \
        --workdir "$repo" \
        --deliver local
    echo "created cron job 'steward opportunity scan' for $profile"
}

# Reconciles one owned job's prompt with its repo file: current -> nothing,
# stale -> edit that job by id, missing -> create it.
sync_job() {
    name="$1"
    file="$2"
    create="$3"
    state="$(job_prompt_state "$name" "$file")"
    id="${state%% *}"
    verdict="${state##* }"
    case "$verdict" in
        current)
            echo "cron job '$name' already current for $profile" ;;
        stale)
            hermes --profile "$profile" cron edit "$id" \
                --prompt "$(cat "$file")"
            echo "refreshed prompt of cron job '$name' for $profile" ;;
        unreadable)
            echo "cannot read $jobs; leaving cron prompt '$name' untouched" ;;
        *)
            "$create" ;;
    esac
}

if [ -f "$jobs" ] && command -v python3 >/dev/null 2>&1; then
    sync_job "hermes daily steward" "$src/daily-steward-prompt.txt" create_daily_steward_job
    sync_job "steward opportunity scan" "$src/steward-opportunity-prompt.txt" create_opportunity_job
else
    # No cron store, or no python3 to read it: fall back to presence by name
    # and never duplicate a job that already exists.
    if [ -f "$jobs" ] && grep -q 'hermes daily steward' "$jobs"; then
        echo "cron job 'hermes daily steward' already present for $profile"
    else
        create_daily_steward_job
    fi
    if [ -f "$jobs" ] && grep -q 'steward opportunity scan' "$jobs"; then
        echo "cron job 'steward opportunity scan' already present for $profile"
    else
        create_opportunity_job
    fi
fi
