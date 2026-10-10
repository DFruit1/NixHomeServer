#!/bin/sh
# Install the independent daily board steward.
#
# What this does:
#   * installs the steward scripts into the shared root and the board-steward
#     profile's script dir;
#   * creates the daily 08:00 cron job under the board-steward profile (idempotent).
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
install -d -m 700 "$root/profiles/$profile/scripts"
install -m 755 "$src/kanban-daily-steward.py" "$root/profiles/$profile/scripts/kanban-daily-steward.py"
echo "installed steward scripts under $root"

jobs="$root/profiles/$profile/cron/jobs.json"
if [ -f "$jobs" ] && grep -q 'hermes daily steward' "$jobs"; then
    echo "cron job 'hermes daily steward' already present for $profile"
else
    prompt="$(cat "$src/daily-steward-prompt.txt")"
    hermes --profile "$profile" cron create "0 8 * * *" "$prompt" \
        --name "hermes daily steward" \
        --script kanban-daily-steward.py \
        --workdir "$repo" \
        --deliver local
    echo "created cron job 'hermes daily steward' for $profile"
fi
