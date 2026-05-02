{ pkgs }:

{
  mkSettledWatcherScript =
    {
      name,
      watchedRoots,
      triggerUnit,
      includeRegex ? ".*",
      settleSeconds ? 20,
      pollSeconds ? 5,
    }:
    pkgs.writeShellScript name ''
      set -euo pipefail

      settle_seconds=${toString settleSeconds}
      poll_seconds=${toString pollSeconds}
      include_regex=${builtins.toJSON includeRegex}
      trigger_unit=${builtins.toJSON triggerUnit}
      watch_roots=(${builtins.concatStringsSep " " (map builtins.toJSON watchedRoots)})

      for root in "''${watch_roots[@]}"; do
        if [[ ! -d "$root" ]]; then
          echo "watch root does not exist: $root" >&2
          exit 1
        fi
      done

      trigger_sync() {
        if /run/current-system/sw/bin/systemctl is-active --quiet "$trigger_unit"; then
          return 1
        fi

        echo "starting $trigger_unit after settled media changes"
        /run/current-system/sw/bin/systemctl start "$trigger_unit"
      }

      coproc WATCHER {
        exec ${pkgs.inotify-tools}/bin/inotifywait \
          --monitor \
          --quiet \
          --recursive \
          --format '%w%f|%e' \
          --event CLOSE_WRITE,CREATE,MOVED_TO,MOVED_FROM,DELETE,DELETE_SELF,ATTRIB \
          "''${watch_roots[@]}"
      }
      trap 'kill "$WATCHER_PID" 2>/dev/null || true' EXIT

      dirty=0
      last_change=0

      while true; do
        if IFS= read -r -t "$poll_seconds" event <&''${WATCHER[0]}; then
          path="''${event%%|*}"
          if [[ ! "$path" =~ $include_regex ]]; then
            continue
          fi

          dirty=1
          last_change="$(date +%s)"
          continue
        fi

        if ! kill -0 "$WATCHER_PID" 2>/dev/null; then
          wait "$WATCHER_PID"
          echo "inotify watcher exited unexpectedly" >&2
          exit 1
        fi

        if (( dirty == 0 )); then
          continue
        fi

        now="$(date +%s)"
        if (( now - last_change < settle_seconds )); then
          continue
        fi

        if trigger_sync; then
          dirty=0
        fi
      done
    '';
}
