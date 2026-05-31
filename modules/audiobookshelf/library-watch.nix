{ config, lib, pkgs, vars, ... }:

let
  loopback = vars.networking.loopbackIPv4;
  audiobookshelfPort = config.services.audiobookshelf.port;
  sharedAudiobooksRoot = config.repo.audiobookshelf.paths.sharedAudiobooksRoot;
  cleanupUsers = vars.staleReferenceCleanup.users or false;
  cleanupShared = vars.staleReferenceCleanup.shared or false;
  mkSettledWatcherScript = import ../../lib/settled-watcher.nix { inherit pkgs; };
  watchedRoots = [
    sharedAudiobooksRoot
    vars.usersRoot
  ];
  mediaIncludeRegex = ".*\\.(m4b|m4a|mp3|flac|opus|ogg|oga|aac|wav|mp4|mka|mkv|pdf|epub|mobi|azw3|nfo|json|jpg|jpeg|png|webp)$";
  managedPathRegex = "(${sharedAudiobooksRoot}|${vars.usersRoot}/[^/]+/_Audiobooks).*";
  watcherScript = mkSettledWatcherScript {
    name = "audiobookshelf-library-watch";
    inherit watchedRoots;
    triggerUnit = "audiobookshelf-stale-reference-cleanup.service";
    includeRegex = mediaIncludeRegex;
    pathRegex = managedPathRegex;
    settleSeconds = 20;
    pollSeconds = 5;
  };
  audiobookshelfStaleReferenceCleanupPath = with pkgs; [
    coreutils
    curl
    jq
  ];
in
{
  config = {
    systemd.services.audiobookshelf-library-watch = {
      description = "Watch Audiobookshelf media roots for settled file changes";
      wantedBy = [ "multi-user.target" ];
      after = [
        "audiobookshelf.service"
        "audiobookshelf-library-watch-config-v1.service"
        "audiobookshelf-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      wants = [
        "audiobookshelf.service"
        "audiobookshelf-library-watch-config-v1.service"
        "audiobookshelf-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      serviceConfig = {
        ExecStart = watcherScript;
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };

    systemd.timers.audiobookshelf-stale-reference-cleanup = {
      description = "Regularly remove stale Audiobookshelf library references";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "15m";
        OnUnitActiveSec = "15m";
        AccuracySec = "1m";
        RandomizedDelaySec = "2m";
        Persistent = true;
        Unit = "audiobookshelf-stale-reference-cleanup.service";
      };
    };

    systemd.services.audiobookshelf-stale-reference-cleanup = {
      description = "Remove Audiobookshelf stale library references in enabled media scopes";
      after = [
        "audiobookshelf.service"
        "audiobookshelf-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      wants = [
        "audiobookshelf.service"
        "audiobookshelf-storage-layout-v1.service"
        "data-pool-layout.service"
      ];
      unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
      path = audiobookshelfStaleReferenceCleanupPath;
      script = ''
        set -euo pipefail

        cleanup_users=${if cleanupUsers then "true" else "false"}
        cleanup_shared=${if cleanupShared then "true" else "false"}
        users_root=${lib.escapeShellArg vars.usersRoot}
        shared_root=${lib.escapeShellArg vars.sharedRoot}
        base_url="http://${loopback}:${toString audiobookshelfPort}"

        if [[ "$cleanup_users" != "true" && "$cleanup_shared" != "true" ]]; then
          echo "Audiobookshelf stale reference cleanup is disabled for users and shared scopes"
          exit 0
        fi

        if [[ "$cleanup_users" == "true" && ! -d "$users_root" ]]; then
          echo "Audiobookshelf users cleanup requested but $users_root is missing; skipping cleanup"
          exit 0
        fi

        if [[ "$cleanup_shared" == "true" && ! -d "$shared_root" ]]; then
          echo "Audiobookshelf shared cleanup requested but $shared_root is missing; skipping cleanup"
          exit 0
        fi

        ready=0
        for _ in $(seq 1 60); do
          if curl --silent --show-error --fail --max-time 5 "$base_url/ping" >/dev/null; then
            ready=1
            break
          fi
          sleep 1
        done
        (( ready == 1 )) || {
          echo "Audiobookshelf HTTP endpoint is not ready yet; skipping stale reference cleanup"
          exit 0
        }

        bootstrap_password="$(< ${config.age.secrets.absBootstrapPass.path})"
        login_json="$(
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 30 \
            -X POST \
            -H 'Content-Type: application/json' \
            --data-binary "$(jq -cn \
              --arg username ${lib.escapeShellArg vars.kanidmAdminUser} \
              --arg password "$bootstrap_password" \
              '{username: $username, password: $password}')" \
            "$base_url/login"
        )"
        token="$(jq -r '.user.token // .user.accessToken // .token // .accessToken // empty' <<<"$login_json")"
        [[ -n "$token" ]] || {
          echo "Audiobookshelf login did not return an API token; skipping stale reference cleanup" >&2
          exit 0
        }

        libraries_json="$(
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 60 \
            -H "Authorization: Bearer $token" \
            "$base_url/api/libraries"
        )"

        while IFS= read -r library_id; do
          [[ -n "$library_id" ]] || continue
          echo "Scanning Audiobookshelf library $library_id before issue cleanup"
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 60 \
            -X POST \
            -H "Authorization: Bearer $token" \
            "$base_url/api/libraries/$library_id/scan" \
            >/dev/null

          echo "Removing Audiobookshelf issue items from scoped library $library_id"
          curl \
            --silent \
            --show-error \
            --fail \
            --max-time 300 \
            -X DELETE \
            -H "Authorization: Bearer $token" \
            "$base_url/api/libraries/$library_id/issues" \
            >/dev/null
        done < <(
          jq -r \
            --arg usersRoot "$users_root" \
            --arg sharedRoot "$shared_root" \
            --argjson cleanupUsers "$cleanup_users" \
            --argjson cleanupShared "$cleanup_shared" \
            '
              (.libraries // .)[]? as $library
              | [($library.folders // [])[]? | (.fullPath // .path // .folderFullPath // empty)] as $paths
              | select(any($paths[]; (
                  ($cleanupUsers and (. == $usersRoot or startswith($usersRoot + "/")))
                  or ($cleanupShared and (. == $sharedRoot or startswith($sharedRoot + "/")))
                )))
              | $library.id // empty
            ' <<<"$libraries_json"
        )
      '';
      serviceConfig = {
        Type = "oneshot";
        Restart = "on-failure";
        RestartSec = "5s";
      };
    };
  };
}
