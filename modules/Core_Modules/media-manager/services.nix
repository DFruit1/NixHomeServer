{ config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mediaManager;
  integrationsJson = builtins.toJSON (lib.mapAttrsToList
    (id: integration: {
      inherit id;
      inherit (integration) label available capabilities;
    })
    cfg.integrations);
  commonEnvironment = {
    MEDIA_MANAGER_ADDRESS = cfg.address;
    MEDIA_MANAGER_PORT = toString cfg.port;
    MEDIA_MANAGER_STATE_DIR = cfg.stateDir;
    MEDIA_MANAGER_SHARED_ROOT = vars.sharedRoot;
    MEDIA_MANAGER_USERS_ROOT = vars.usersRoot;
    MEDIA_MANAGER_EDITOR_GROUP = cfg.editorGroup;
    MEDIA_MANAGER_MUTATION_MODE = cfg.mutationMode;
    MEDIA_MANAGER_MKVMAKER_PROGRESS_FILE = "/run/mkvmaker/progress.json";
    MEDIA_MANAGER_INTEGRATIONS_JSON = integrationsJson;
    MEDIA_MANAGER_FRONTEND_DIR = "${cfg.package}/share/media-manager/frontend";
    MEDIA_MANAGER_FFPROBE = "${pkgs.ffmpeg}/bin/ffprobe";
    MEDIA_MANAGER_FILESTASH_BASE_URL = "https://files.${vars.domain}";
  };
  openSubtitlesConfigured = builtins.hasAttr "openSubtitlesCredentials" config.age.secrets;
  acoustidConfigured = builtins.hasAttr "acoustidApiKey" config.age.secrets;
  jellyfinMetadataAvailable = cfg.integrations.jellyfin.available or false;
  audiobookshelfMetadataAvailable = cfg.integrations.audiobookshelf.available or false;
  kavitaMetadataAvailable = cfg.integrations.kavita.available or false;
  jellyfinMetadataCache = "/var/cache/media-manager-jellyfin/metadata.json";
  audiobookshelfMetadataCache = "/var/cache/media-manager-audiobookshelf/metadata.json";
  kavitaMetadataCache = "/var/cache/media-manager-kavita/metadata.json";
  webEnvironment = commonEnvironment
  // lib.optionalAttrs openSubtitlesConfigured {
    MEDIA_MANAGER_OPENSUBTITLES_CREDENTIALS_FILE = config.age.secrets.openSubtitlesCredentials.path;
  }
  // lib.optionalAttrs acoustidConfigured {
    MEDIA_MANAGER_ACOUSTID_API_KEY_FILE = config.age.secrets.acoustidApiKey.path;
  }
  // lib.optionalAttrs jellyfinMetadataAvailable {
    MEDIA_MANAGER_JELLYFIN_METADATA_CACHE_FILE = jellyfinMetadataCache;
    MEDIA_MANAGER_JELLYFIN_BASE_URL = "http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.jellyfin}";
    MEDIA_MANAGER_JELLYFIN_API_KEY_FILE = "/var/lib/jellyfin/data/library-sync.api-key";
    MEDIA_MANAGER_JELLYFIN_PUBLIC_URL = "https://videos.${vars.domain}";
  }
  // lib.optionalAttrs audiobookshelfMetadataAvailable {
    MEDIA_MANAGER_AUDIOBOOKSHELF_METADATA_CACHE_FILE = audiobookshelfMetadataCache;
    MEDIA_MANAGER_AUDIOBOOKSHELF_PUBLIC_URL = "https://audiobooks.${vars.domain}";
  }
  // lib.optionalAttrs kavitaMetadataAvailable {
    MEDIA_MANAGER_KAVITA_METADATA_CACHE_FILE = kavitaMetadataCache;
    MEDIA_MANAGER_KAVITA_PUBLIC_URL = "https://books.${vars.domain}";
  }
  // {
    MEDIA_MANAGER_FPCALC_PATH = "${pkgs.chromaprint}/bin/fpcalc";
  };
  refreshAvailable = id:
    (cfg.integrations.${id}.available or false)
    && lib.any
      (capability: capability == "library-refresh" || capability == "folder-rescan")
      (cfg.integrations.${id}.capabilities or [ ]);
  jellyfinRefreshAvailable = refreshAvailable "jellyfin";
  audiobookshelfRefreshAvailable = refreshAvailable "audiobookshelf";
  kavitaRefreshAvailable = refreshAvailable "kavita";
  syncthingRefreshAvailable = refreshAvailable "syncthing";
  refreshDispatcher = pkgs.writeShellApplication {
    name = "media-manager-refresh-dispatch";
    runtimeInputs = [ pkgs.coreutils pkgs.jq pkgs.systemd ];
    text = ''
      set -euo pipefail
      shopt -s nullglob

      request_dir=${lib.escapeShellArg "${cfg.stateDir}/refresh-requests"}
      result_dir=${lib.escapeShellArg "${cfg.stateDir}/refresh-results"}
      had_failure=0
      while true; do
        markers=("$request_dir"/*.request)
        (( ''${#markers[@]} > 0 )) || break
        for marker in "''${markers[@]}"; do
        if [[ ! -f "$marker" || -L "$marker" ]]; then
          rm -f -- "$marker"
          continue
        fi
        integration="$(basename "$marker" .request)"
        request_id="$(jq -er \
          --arg integration "$integration" \
          'select(.schemaVersion == 1 and .integrationId == $integration and .state == "queued") | .requestId' \
          "$marker" 2>/dev/null || true)"
        queued_at="$(jq -er '.queuedAt | select(type == "number")' "$marker" 2>/dev/null || true)"
        if [[ ! "$request_id" =~ ^r[0-9a-f]+-[0-9a-f]+$ || ! "$queued_at" =~ ^[0-9]+$ ]]; then
          jq -cn \
            --arg integrationId "$integration" \
            '{level:"error",service:"media-manager-refresh-dispatch",event:"integration_refresh_marker_invalid",integrationId:$integrationId}' >&2
          rm -f -- "$marker"
          had_failure=1
          continue
        fi

        case "$integration" in
          ${lib.optionalString jellyfinRefreshAvailable ''
          jellyfin)
            unit=media-manager-refresh-jellyfin.service
            metadata_unit=media-manager-jellyfin-metadata.service
            success_message="Jellyfin library scan and metadata observation completed."
            failure_message="Jellyfin library scan failed. Check the adapter service log."
            ;;
          ''}
          ${lib.optionalString audiobookshelfRefreshAvailable ''
          audiobookshelf)
            unit=media-manager-refresh-audiobookshelf.service
            metadata_unit=media-manager-audiobookshelf-metadata.service
            success_message="Audiobookshelf library scans and metadata observation completed."
            failure_message="Audiobookshelf library scans failed. Check the adapter service log."
            ;;
          ''}
          ${lib.optionalString kavitaRefreshAvailable ''
          kavita)
            unit=media-manager-refresh-kavita.service
            metadata_unit=media-manager-kavita-metadata.service
            success_message="Kavita library scans and metadata observation completed."
            failure_message="Kavita library scans failed. Check the adapter service log."
            ;;
          ''}
          ${lib.optionalString syncthingRefreshAvailable ''
          syncthing)
            unit=media-manager-refresh-syncthing.service
            metadata_unit=
            success_message="Syncthing folder scan completed."
            failure_message="Syncthing folder scan failed. Check the adapter service log."
            ;;
          ''}
          *)
            jq -cn \
              --arg integrationId "$integration" \
              --arg requestId "$request_id" \
              '{level:"error",service:"media-manager-refresh-dispatch",event:"integration_refresh_adapter_unavailable",integrationId:$integrationId,requestId:$requestId}' >&2
            rm -f -- "$marker"
            had_failure=1
            continue
            ;;
        esac

        started_at="$(date +%s)"
        running_tmp="$(mktemp "$request_dir/.running.XXXXXX")"
        jq --argjson startedAt "$started_at" \
          '.state = "running" | .startedAt = $startedAt' \
          "$marker" >"$running_tmp"
        chmod 0640 "$running_tmp"
        mv -f -- "$running_tmp" "$marker"

        if systemctl start --wait "$unit" \
          && { [[ -z "$metadata_unit" ]] || systemctl start --wait "$metadata_unit"; }; then
          terminal_state=succeeded
          message="$success_message"
          level=info
          event=integration_refresh_succeeded
        else
          terminal_state=failed
          message="$failure_message"
          level=error
          event=integration_refresh_failed
          had_failure=1
        fi
        finished_at="$(date +%s)"
        result_tmp="$(mktemp "$result_dir/.result.XXXXXX")"
        jq -cn \
          --arg integrationId "$integration" \
          --arg state "$terminal_state" \
          --arg requestId "$request_id" \
          --arg message "$message" \
          --argjson queuedAt "$queued_at" \
          --argjson startedAt "$started_at" \
          --argjson finishedAt "$finished_at" \
          '{schemaVersion:1,integrationId:$integrationId,state:$state,requestId:$requestId,queuedAt:$queuedAt,startedAt:$startedAt,finishedAt:$finishedAt,message:$message}' \
          >"$result_tmp"
        chmod 0640 "$result_tmp"
        mv -f -- "$result_tmp" "$result_dir/$integration.json"
        rm -f -- "$marker"

        jq -cn \
          --arg level "$level" \
          --arg event "$event" \
          --arg integrationId "$integration" \
          --arg requestId "$request_id" \
          --argjson durationSeconds "$((finished_at - started_at))" \
          '{level:$level,service:"media-manager-refresh-dispatch",event:$event,integrationId:$integrationId,requestId:$requestId,durationSeconds:$durationSeconds}' \
          >&2
        done
      done
      exit "$had_failure"
    '';
  };
  jellyfinRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-jellyfin";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.jellyfin}"
      api_key_file=/var/lib/jellyfin/data/library-sync.api-key
      [[ -f "$api_key_file" && ! -L "$api_key_file" ]] || {
        echo "Jellyfin library-sync API key is unavailable" >&2
        exit 1
      }
      api_key="$(tr -d '\r\n' <"$api_key_file")"
      [[ "$api_key" =~ ^[A-Za-z0-9._~-]+$ ]] || {
        echo "Jellyfin library-sync API key is malformed" >&2
        exit 1
      }
      jellyfin_curl() {
        printf 'header = "X-Emby-Token: %s"\n' "$api_key" \
          | curl --config - --fail --silent --show-error --max-time 30 "$@"
      }

      tasks="$(jellyfin_curl "$base_url/ScheduledTasks")"
      task_id="$(jq -er '
        map(select((.Key // .key) == "RefreshLibrary"))
        | first
        | (.Id // .id)
        | select(type == "string" and test("^[A-Fa-f0-9-]+$"))
      ' <<<"$tasks")"
      previous_finished="$(jq -r \
        --arg taskId "$task_id" \
        'map(select((.Id // .id) == $taskId)) | first | (.LastExecutionResult.EndTimeUtc // .lastExecutionResult.endTimeUtc // "")' \
        <<<"$tasks")"
      jellyfin_curl -X POST "$base_url/ScheduledTasks/Running/$task_id" >/dev/null

      saw_running=false
      for _ in $(seq 1 3600); do
        task="$(jellyfin_curl "$base_url/ScheduledTasks/$task_id")"
        state="$(jq -r '.State // .state // empty' <<<"$task")"
        finished="$(jq -r '.LastExecutionResult.EndTimeUtc // .lastExecutionResult.endTimeUtc // ""' <<<"$task")"
        if [[ "$state" == "Running" || "$state" == "Cancelling" ]]; then
          saw_running=true
        elif [[ "$state" == "Idle" && ( "$saw_running" == "true" || ( -n "$finished" && "$finished" != "$previous_finished" ) ) ]]; then
          status="$(jq -r '.LastExecutionResult.Status // .lastExecutionResult.status // empty' <<<"$task")"
          [[ "$status" == "Completed" ]] && exit 0
          echo "Jellyfin scheduled task ended with status: ''${status:-unknown}" >&2
          exit 1
        fi
        sleep 2
      done
      echo "Timed out waiting for the Jellyfin library scan" >&2
      exit 1
    '';
  };
  jellyfinMetadataExport = pkgs.writeShellApplication {
    name = "media-manager-jellyfin-metadata-export";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.jellyfin}"
      api_key_file=/var/lib/jellyfin/data/library-sync.api-key
      output=${lib.escapeShellArg jellyfinMetadataCache}
      [[ -f "$api_key_file" && ! -L "$api_key_file" ]] || exit 1
      api_key="$(tr -d '\r\n' <"$api_key_file")"
      [[ "$api_key" =~ ^[A-Za-z0-9._~-]+$ ]] || exit 1
      tmp="$(mktemp "$(dirname "$output")/.metadata.XXXXXX")"
      trap 'rm -f -- "$tmp"' EXIT
      printf 'header = "X-Emby-Token: %s"\n' "$api_key" \
        | curl --config - --fail --silent --show-error --max-time 90 --max-filesize 16777216 \
          --get "$base_url/Items" \
          --data-urlencode 'Recursive=true' \
          --data-urlencode 'IncludeItemTypes=Movie,Episode,Audio' \
           --data-urlencode 'Fields=Path,Overview,Genres,Studios,People,ProviderIds,MediaStreams,PremiereDate,ProductionYear,CommunityRating,OfficialRating,RunTimeTicks,SeriesName,ParentIndexNumber,IndexNumber,Id,ImageTags' \
          --data-urlencode 'Limit=10000' \
        | jq -e \
          --arg shared ${lib.escapeShellArg vars.sharedRoot} \
          --arg users ${lib.escapeShellArg vars.usersRoot} \
          --argjson observedAt "$(date +%s)" '
          def clean($n): if type == "string" then .[0:$n] else null end;
          def location:
            . as $path
            | if startswith($shared + "/_Videos/") then {rootId:"shared-videos",ownerUsername:null,relativePath:ltrimstr($shared + "/_Videos/")}
              elif startswith($shared + "/_Music/") then {rootId:"shared-music",ownerUsername:null,relativePath:ltrimstr($shared + "/_Music/")}
              elif startswith($shared + "/_Audiobooks/") then {rootId:"shared-audiobooks",ownerUsername:null,relativePath:ltrimstr($shared + "/_Audiobooks/")}
              elif startswith($shared + "/_Books/") then {rootId:"shared-books",ownerUsername:null,relativePath:ltrimstr($shared + "/_Books/")}
              elif startswith($users + "/") then
                (ltrimstr($users + "/") | split("/")) as $p
                | select(($p|length) >= 3 and ($p[0] | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")))
                | ({"_Videos":"videos","_Music":"music","_Audiobooks":"audiobooks","_Books":"books"}[$p[1]]) as $category
                | select($category != null)
                | {rootId:("personal-" + $category),ownerUsername:$p[0],relativePath:($p[2:]|join("/"))}
              else empty end;
          select((.TotalRecordCount // 0) <= 10000)
          | {schemaVersion:1, observedAt:$observedAt, entries:[.Items[]
              | select((.Path|type) == "string" and (.Path|length) <= 4096)
              | (.Path | location) as $location
              | $location + {
                   mediaType:(if .Type == "Episode" then "episode" elif .Type == "Movie" then "movie" elif ($location.rootId | endswith("audiobooks")) then "audiobook" else "music" end),
                   itemId: .Id,
                   observedAt: $observedAt,
                   imageTags: (.ImageTags // {}),
                   title:(.Name|clean(500)), year:.ProductionYear,
                  series:(.SeriesName|clean(500)), season:.ParentIndexNumber, episode:.IndexNumber,
                  episodeTitle:(if .Type == "Episode" then (.Name|clean(500)) else null end),
                  description:(.Overview|clean(20000)),
                  publisher:((.Studios // [])[0].Name|clean(500)),
                  genres:((.Genres // [])[:64] | map(clean(500))),
                  writers:((.People // []) | map(select(.Type == "Writer") | .Name | clean(500))[:64]),
                  premiereDate:(.PremiereDate|clean(32)),
                  runtimeMinutes:(if (.RunTimeTicks|type) == "number" then ((.RunTimeTicks / 600000000)|round) else null end),
                  officialRating:(.OfficialRating|clean(64)), communityRating:.CommunityRating,
                  providerIds:((.ProviderIds // {}) | to_entries[:32] | map(select((.key|length)<=64 and (.value|type)=="string" and (.value|length)<=256)) | from_entries),
                  videoStreams:((.MediaStreams // []) | map(select(.Type == "Video") | {codec:(.Codec|clean(32)),height:.Height,width:.Width,videoRange:(.VideoRange|clean(32)),bitRate:.BitRate})[:8]),
                  audioStreams:((.MediaStreams // []) | map(select(.Type == "Audio") | {codec:(.Codec|clean(32)),language:(.Language|clean(15)),channelLayout:(.ChannelLayout|clean(32)),channels:.Channels,bitRate:.BitRate})[:16]),
                  subtitleStreams:((.MediaStreams // []) | map(select(.Type == "Subtitle") | {index:.Index,codec:(.Codec|clean(32)),language:(.Language|clean(15)),title:((.DisplayTitle // .Title)|clean(128)),isDefault:(.IsDefault == true),isForced:(.IsForced == true),isHearingImpaired:(.IsHearingImpaired == true),isExternal:(.IsExternal == true)})[:32])
                }
              | select(.relativePath != "" and (.relativePath | split("/") | all(. != "" and . != "." and . != "..")))]}
          | select((.entries|length) <= 10000)
        ' >"$tmp"
      chmod 0640 "$tmp"
      mv -f -- "$tmp" "$output"
      trap - EXIT
    '';
  };
  audiobookshelfMetadataExport = pkgs.writeShellApplication {
    name = "media-manager-audiobookshelf-metadata-export";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.audiobookshelf}"
      output=${lib.escapeShellArg audiobookshelfMetadataCache}
      service_ready=0
      for _ in $(seq 1 30); do
        if (exec 3<>/dev/tcp/${vars.networking.loopbackIPv4}/${toString vars.networking.ports.audiobookshelf}) 2>/dev/null; then
          service_ready=1
          break
        fi
        sleep 2
      done
      (( service_ready == 1 )) || {
        echo "Audiobookshelf did not become ready before metadata export" >&2
        exit 1
      }
      password="$(< ${config.age.secrets.absBootstrapPass.path})"
      login="$(jq -cn \
        --arg username ${lib.escapeShellArg vars.kanidmAdminUser} \
        --arg password "$password" \
        '{username:$username,password:$password}')"
      response="$(printf '%s' "$login" | curl --fail --silent --show-error --max-time 30 \
        -X POST -H 'Content-Type: application/json' --data-binary @- "$base_url/login")"
      unset password login
      token="$(jq -r '.user.token // .user.accessToken // .token // .accessToken // empty' <<<"$response")"
      [[ "$token" =~ ^[A-Za-z0-9._~+/-]+$ ]] || exit 1
      libraries="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | curl --config - --fail --silent --show-error --max-time 60 --max-filesize 16777216 \
          "$base_url/api/libraries")"
      work="$(mktemp -d)"
      trap 'rm -rf -- "$work"' EXIT
      : >"$work/entries.jsonl"
      while IFS= read -r library_id; do
        [[ -n "$library_id" ]] || continue
        printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 90 --max-filesize 16777216 \
            --get "$base_url/api/libraries/$library_id/items" \
            --data-urlencode 'limit=10000' --data-urlencode 'page=0' --data-urlencode 'minified=0' \
          | jq -ce \
            --arg shared ${lib.escapeShellArg vars.sharedRoot} \
            --arg users ${lib.escapeShellArg vars.usersRoot} \
            --argjson observedAt "$(date +%s)" '
            def clean($n): if type == "string" then .[0:$n] else null end;
            def names: map(if type == "object" then .name else . end | clean(500)) | map(select(. != null));
            def location:
              . as $path
              | if startswith($shared + "/_Audiobooks/") then {rootId:"shared-audiobooks",ownerUsername:null,relativePath:ltrimstr($shared + "/_Audiobooks/")}
                elif startswith($shared + "/_Podcasts/") then {rootId:"shared-podcasts",ownerUsername:null,relativePath:ltrimstr($shared + "/_Podcasts/")}
                elif startswith($users + "/") then
                  (ltrimstr($users + "/") | split("/")) as $parts
                  | select(($parts|length) >= 3 and ($parts[1] == "_Audiobooks" or $parts[1] == "_Podcasts") and ($parts[0] | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")))
                  | (if $parts[1] == "_Podcasts" then "podcasts" else "audiobooks" end) as $category
                  | {rootId:("personal-" + $category),ownerUsername:$parts[0],relativePath:($parts[2:]|join("/"))}
                else empty end;
            select((.total // 0) <= 10000)
            | .results[]
            | select((.path|type) == "string" and (.path|length) <= 4096)
            | (.path | location) as $location
            | (.media.metadata // {}) as $metadata
            | (.media // {}) as $media
            | $location + {
                itemId:(.id|clean(128)), observedAt:$observedAt,
                mediaType:(if ($location.rootId | endswith("podcasts")) then "podcast" else "audiobook" end),
                title:($metadata.title|clean(500)),
                subtitle:($metadata.subtitle|clean(500)),
                authors:(if ($metadata.authors|type) == "array" then (($metadata.authors // [])|names)[:64] elif ($metadata.author|type) == "string" then [($metadata.author|clean(500))] else [] end),
                narrators:(($metadata.narrators // [])|names)[:64],
                series:((($metadata.series // [])[0].name)|clean(500)),
                volumeNumber:((($metadata.series // [])[0].sequence)|clean(64)),
                publisher:($metadata.publisher|clean(500)),
                isbn:($metadata.isbn|clean(64)), language:($metadata.language|clean(32)),
                genres:(($metadata.genres // [])|names)[:64],
                description:($metadata.description|clean(20000)),
                year:(try ($metadata.publishedYear|tonumber) catch null),
                publishedDate:(($metadata.publishedDate // $metadata.releaseDate)|clean(32)),
                explicit:(if ($metadata.explicit|type) == "boolean" then $metadata.explicit else null end),
                tags:(($media.tags // $metadata.tags // [])|names)[:64],
                chapters:(($media.chapters // [])[:512] | map({id:(.id|clean(128)),title:(.title|clean(500)),start:.start,end:.end})),
                audioFiles:(($media.audioFiles // [])[:512] | map({index:.index,filename:(.metadata.filename|clean(500)),size:.metadata.size,duration:.duration,codec:(.codec|clean(32)),bitRate:.bitRate,channels:.channels,language:(.language|clean(32)),trackNumber:(.trackNumFromMeta // .trackNumFromFilename),discNumber:(.discNumFromMeta // .discNumFromFilename),embeddedCoverArt:(.embeddedCoverArt|clean(32)),error:(.error|clean(500))})),
                ebookFile:(if ($media.ebookFile|type) == "object" then {filename:($media.ebookFile.metadata.filename|clean(500)),size:$media.ebookFile.metadata.size,extension:($media.ebookFile.metadata.ext|clean(16))} else null end),
                providerIds:({isbn:($metadata.isbn|clean(64)),asin:($metadata.asin|clean(64)),itunes:($metadata.itunesId|tostring|clean(128)),feedUrl:($metadata.feedURL|clean(2048))}|with_entries(select(.value != null and .value != "null"))),
                isLocked:(($metadata.isLocked // false) == true)
              }
            | select(.relativePath != "" and (.relativePath | split("/") | all(. != "" and . != "." and . != "..")))' \
          >>"$work/entries.jsonl"
      done < <(jq -r '(.libraries // .)[]?.id // empty' <<<"$libraries")
      tmp="$(mktemp "$(dirname "$output")/.metadata.XXXXXX")"
      jq -sc '{schemaVersion:1,observedAt:(now|floor),entries:.} | select((.entries|length) <= 10000)' \
        "$work/entries.jsonl" >"$tmp"
      chmod 0640 "$tmp"
      mv -f -- "$tmp" "$output"
      trap - EXIT
      rm -rf -- "$work"
    '';
  };
  kavitaMetadataExport = pkgs.writeShellApplication {
    name = "media-manager-kavita-metadata-export";
    runtimeInputs = [ pkgs.bash pkgs.coreutils pkgs.curl pkgs.findutils pkgs.jq pkgs.python3 pkgs.sqlite ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.kavita}"
      output=${lib.escapeShellArg kavitaMetadataCache}
      service_ready=0
      for _ in $(seq 1 30); do
        if (exec 3<>/dev/tcp/${vars.networking.loopbackIPv4}/${toString vars.networking.ports.kavita}) 2>/dev/null; then
          service_ready=1
          break
        fi
        sleep 2
      done
      (( service_ready == 1 )) || {
        echo "Kavita did not become ready before metadata export" >&2
        exit 1
      }
      db=/var/lib/kavita/config/kavita.db
      token_key_file=${lib.escapeShellArg config.age.secrets.kavitaTokenKey.path}
      admin_username=${lib.escapeShellArg vars.kanidmAdminUser}
      [[ -f "$db" && ! -L "$db" && -f "$token_key_file" && ! -L "$token_key_file" ]] || exit 1
      admin_token="$(python3 - "$token_key_file" "$db" "$admin_username" <<'PY'
import base64, hashlib, hmac, json, sqlite3, sys, time
def encode(value): return base64.urlsafe_b64encode(value).rstrip(b"=")
token_key_path, database_path, username = sys.argv[1:]
with sqlite3.connect(f"file:{database_path}?mode=ro", uri=True, timeout=5) as database:
    row = database.execute("select Id, UserName from AspNetUsers where UserName = ? limit 1", (username,)).fetchone()
if row is None: raise SystemExit("Kavita admin identity is unavailable")
token_key = open(token_key_path, "rb").read().strip()
if len(token_key) < 32: raise SystemExit("Kavita token key is malformed")
now = int(time.time())
header = encode(json.dumps({"alg":"HS512","typ":"JWT"}, separators=(",", ":")).encode())
payload = encode(json.dumps({"name":row[1],"nameid":str(row[0]),"role":["Admin","Login"],"nbf":now,"iat":now,"exp":now+300}, separators=(",", ":")).encode())
unsigned = header + b"." + payload
print((unsigned + b"." + encode(hmac.new(token_key, unsigned, hashlib.sha512).digest())).decode())
PY
)"
      series="$(printf 'header = "Authorization: Bearer %s"\n' "$admin_token" \
        | curl --config - --fail --silent --show-error --max-time 90 --max-filesize 16777216 \
          -X POST -H 'Content-Type: application/json' --data '{}' \
          "$base_url/api/Series/all-v2?PageNumber=1&PageSize=10000")"
      work="$(mktemp -d)"
      trap 'rm -rf -- "$work"' EXIT
      mkdir "$work/results"
      printf 'header = "Authorization: Bearer %s"\n' "$admin_token" >"$work/curl.conf"
      chmod 0600 "$work/curl.conf"
      unset admin_token
      # The worker shell, rather than this parent shell, expands its positional parameters.
      # shellcheck disable=SC2016
      jq -r '.[].id // empty' <<<"$series" \
        | xargs -r -P 4 -n 1 bash -c '
            base_url="$1"
            work="$2"
            series_id="$3"
            [[ "$series_id" =~ ^[0-9]+$ ]] || exit 1
            curl --config "$work/curl.conf" --fail --silent --show-error \
              --max-time 15 --max-filesize 1048576 --get \
              --data-urlencode "seriesId=$series_id" "$base_url/api/Series/metadata" \
              | jq -ce --argjson seriesId "$series_id" ". + {seriesId:\$seriesId}" \
                >"$work/results/$series_id.json"
          ' _ "$base_url" "$work"
      if compgen -G "$work/results/*.json" >/dev/null; then
        jq -s '.' "$work"/results/*.json >"$work/metadata.json"
      else
        printf '[]\n' >"$work/metadata.json"
      fi
      tmp="$(mktemp "$(dirname "$output")/.metadata.XXXXXX")"
      trap 'rm -f -- "$tmp"; rm -rf -- "$work"' EXIT
      jq -e \
        --arg shared ${lib.escapeShellArg vars.sharedRoot} \
        --arg users ${lib.escapeShellArg vars.usersRoot} \
        --slurpfile metadata "$work/metadata.json" \
        --argjson observedAt "$(date +%s)" '
        def clean($n): if type == "string" then .[0:$n] else null end;
        def names: map(if type == "object" then .name else . end | clean(500)) | map(select(. != null));
        def location:
          . as $path
          | if startswith($shared + "/_Books/") then {rootId:"shared-books",ownerUsername:null,relativePath:(ltrimstr($shared + "/_Books/")|rtrimstr("/"))}
            elif startswith($users + "/") then
              (ltrimstr($users + "/") | split("/")) as $parts
              | select(($parts|length) >= 3 and $parts[1] == "_Books" and ($parts[0] | test("^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$")))
              | {rootId:"personal-books",ownerUsername:$parts[0],relativePath:($parts[2:]|join("/")|rtrimstr("/"))}
            else empty end;
        select(type == "array" and length <= 10000)
        | ($metadata[0] | map({key:(.seriesId|tostring),value:.}) | from_entries) as $metadataById
        | {schemaVersion:1,observedAt:$observedAt,entries:[.[]
            | select((.folderPath|type) == "string" and (.folderPath|length) <= 4096)
            | (.folderPath|location) as $location
            | ($metadataById[(.id|tostring)] // {}) as $details
            | $location + {
                itemId:(.id|tostring), observedAt:$observedAt,
                title:((.localizedName // .name)|clean(500)),
                series:(.name|clean(500)),
                year:(if ($details.releaseYear // 0) > 0 then $details.releaseYear else null end),
                description:($details.summary|clean(20000)),
                language:($details.language|clean(32)),
                genres:(($details.genres // [])|names)[:64],
                tags:(($details.tags // [])|names)[:64],
                writers:(($details.writers // [])|names)[:64],
                authors:(($details.writers // [])|names)[:64],
                publisher:((($details.publishers // [])[0].name)|clean(500)),
                ageRating:$details.ageRating,
                publicationStatus:$details.publicationStatus,
                fieldLocks:{title:((.localizedNameLocked // false) == true),sortTitle:((.sortNameLocked // false) == true),language:(($details.languageLocked // false) == true),description:(($details.summaryLocked // false) == true),genres:(($details.genresLocked // false) == true),tags:(($details.tagsLocked // false) == true),writers:(($details.writerLocked // false) == true),publisher:(($details.publisherLocked // false) == true),year:(($details.releaseYearLocked // false) == true),ageRating:(($details.ageRatingLocked // false) == true),publicationStatus:(($details.publicationStatusLocked // false) == true)},
                isLocked:((.localizedNameLocked // false) == true or (.sortNameLocked // false) == true or ($details.languageLocked // false) == true or ($details.summaryLocked // false) == true or ($details.genresLocked // false) == true or ($details.tagsLocked // false) == true or ($details.writerLocked // false) == true or ($details.publisherLocked // false) == true or ($details.releaseYearLocked // false) == true),
                providerIds:({anilist:(if (.aniListId // 0) > 0 then (.aniListId|tostring) else null end),mal:(if (.malId // 0) > 0 then (.malId|tostring) else null end),hardcover:(if (.hardcoverId // 0) > 0 then (.hardcoverId|tostring) else null end),metron:(if (.metronId // 0) > 0 then (.metronId|tostring) else null end),comicVine:(.comicVineId|clean(128)),mangaBaka:(if (.mangaBakaId // 0) > 0 then (.mangaBakaId|tostring) else null end),webLinks:($details.webLinks|clean(2048))}|with_entries(select(.value != null)))
              }
            | select(.relativePath != "" and (.relativePath | split("/") | all(. != "" and . != "." and . != "..")))]}
      ' <<<"$series" >"$tmp"
      chmod 0640 "$tmp"
      mv -f -- "$tmp" "$output"
      trap - EXIT
      rm -rf -- "$work"
    '';
  };
  audiobookshelfRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-audiobookshelf";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.audiobookshelf}"
      password="$(< ${config.age.secrets.absBootstrapPass.path})"
      login="$(${pkgs.jq}/bin/jq -cn \
        --arg username ${lib.escapeShellArg vars.kanidmAdminUser} \
        --arg password "$password" \
        '{username: $username, password: $password}')"
      response="$(printf '%s' "$login" | curl --fail --silent --show-error --max-time 30 \
        -X POST -H 'Content-Type: application/json' --data-binary @- \
        "$base_url/login")"
      token="$(jq -r '.user.token // .user.accessToken // .token // .accessToken // empty' <<<"$response")"
      [[ "$token" =~ ^[A-Za-z0-9._~+/-]+$ ]] || {
        echo "Audiobookshelf returned no safe API token" >&2
        exit 1
      }
      libraries="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
        | curl --config - --fail --silent --show-error --max-time 60 \
          "$base_url/api/libraries")"
      library_ids="$(jq -c '[((.libraries // .)[]?.id // empty)]' <<<"$libraries")"
      library_count="$(jq 'length' <<<"$library_ids")"
      (( library_count > 0 )) || {
        echo "Audiobookshelf has no libraries to scan" >&2
        exit 1
      }
      started_at_ms="$(date +%s%3N)"
      while IFS= read -r library_id; do
        [[ -n "$library_id" ]] || continue
        printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 300 -X POST \
            "$base_url/api/libraries/$library_id/scan" >/dev/null
      done < <(jq -r '.[]' <<<"$library_ids")

      for attempt in $(seq 1 3600); do
        tasks="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 30 \
            "$base_url/api/tasks")"
        libraries="$(printf 'header = "Authorization: Bearer %s"\n' "$token" \
          | curl --config - --fail --silent --show-error --max-time 30 \
            "$base_url/api/libraries")"
        completed_count="$(jq \
          --argjson ids "$library_ids" \
          --argjson startedAt "$started_at_ms" \
          '[((.libraries // .)[]?) | select((.id as $id | $ids | index($id)) != null and (.lastScan // 0) >= $startedAt)] | length' \
          <<<"$libraries")"
        active_count="$(jq \
          --argjson ids "$library_ids" \
          '[.tasks[]? | select(.action == "library-scan" and (.data.libraryId as $id | $ids | index($id)) != null)] | length' \
          <<<"$tasks")"
        (( completed_count == library_count )) && exit 0
        if (( active_count == 0 && completed_count < library_count && attempt > 5 )); then
          echo "An Audiobookshelf library scan ended without updating lastScan" >&2
          exit 1
        fi
        sleep 2
      done
      echo "Timed out waiting for Audiobookshelf library scans" >&2
      exit 1
    '';
  };
  kavitaRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-kavita";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.jq pkgs.python3 pkgs.sqlite ];
    text = ''
      set -euo pipefail
      base_url="http://${vars.networking.loopbackIPv4}:${toString vars.networking.ports.kavita}"
      db=/var/lib/kavita/config/kavita.db
      token_key_file=${lib.escapeShellArg config.age.secrets.kavitaTokenKey.path}
      admin_username=${lib.escapeShellArg vars.kanidmAdminUser}

      [[ "$admin_username" =~ ^[a-z][a-z0-9._-]{0,63}$ ]] || {
        echo "Kavita admin username is malformed" >&2
        exit 1
      }
      [[ -f "$db" && ! -L "$db" ]] || {
        echo "Kavita database is unavailable" >&2
        exit 1
      }
      [[ -f "$token_key_file" && ! -L "$token_key_file" ]] || {
        echo "Kavita token key is unavailable" >&2
        exit 1
      }

      admin_token="$(python3 - "$token_key_file" "$db" "$admin_username" <<'PY'
import base64
import hashlib
import hmac
import json
import sqlite3
import sys
import time

def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=")

token_key_path, database_path, username = sys.argv[1:]
with sqlite3.connect(f"file:{database_path}?mode=ro", uri=True, timeout=5) as database:
    row = database.execute(
        "select Id, UserName from AspNetUsers where UserName = ? limit 1",
        (username,),
    ).fetchone()
if row is None:
    raise SystemExit("Kavita admin identity is unavailable")
token_key = open(token_key_path, "rb").read().strip()
if len(token_key) < 32:
    raise SystemExit("Kavita token key is malformed")
now = int(time.time())
header = encode(json.dumps(
    {"alg": "HS512", "typ": "JWT"}, separators=(",", ":")
).encode())
payload = encode(json.dumps({
    "name": row[1],
    "nameid": str(row[0]),
    "role": ["Admin", "Login"],
    "nbf": now,
    "iat": now,
    "exp": now + 300,
}, separators=(",", ":")).encode())
unsigned = header + b"." + payload
signature = encode(hmac.new(token_key, unsigned, hashlib.sha512).digest())
print((unsigned + b"." + signature).decode())
PY
)"
      kavita_curl() {
        printf 'header = "Authorization: Bearer %s"\n' "$admin_token" \
          | curl --config - --fail --silent --show-error --max-time 60 "$@"
      }

      baseline="$(sqlite3 -readonly -json -cmd '.timeout 5000' "$db" \
        'select Id as id, LastScanned as lastScanned from Library order by Id;')"
      library_count="$(jq 'length' <<<"$baseline")"
      if (( library_count == 0 )); then
        echo "Kavita has no libraries to scan"
        exit 0
      fi

      kavita_curl -X POST "$base_url/api/library/scan-all?force=false" >/dev/null
      unset admin_token
      # Kavita has no public scan-job status endpoint. LastScanned is persisted
      # after the library data update, so every baseline timestamp must advance.
      for _ in $(seq 1 3600); do
        current="$(sqlite3 -readonly -json -cmd '.timeout 5000' "$db" \
          'select Id as id, LastScanned as lastScanned from Library order by Id;')"
        if ! jq -e --argjson before "$baseline" \
          '. as $current
           | all($before[]; . as $previous
             | any($current[]; .id == $previous.id))' \
          <<<"$current" >/dev/null; then
          echo "A Kavita library was removed while its scan was running" >&2
          exit 1
        fi
        if jq -e --argjson before "$baseline" \
          '. as $current
           | all($before[]; . as $previous
             | any($current[];
               .id == $previous.id and .lastScanned != $previous.lastScanned))' \
          <<<"$current" >/dev/null; then
          exit 0
        fi
        sleep 2
      done
      echo "Timed out waiting for Kavita library scans" >&2
      exit 1
    '';
  };
  syncthingRefresh = pkgs.writeShellApplication {
    name = "media-manager-refresh-syncthing";
    runtimeInputs = [ pkgs.coreutils pkgs.curl pkgs.libxml2 ];
    text = ''
      set -euo pipefail
      config_file=/var/lib/syncthing/.config/syncthing/config.xml
      [[ -f "$config_file" && ! -L "$config_file" ]] || {
        echo "Syncthing configuration is unavailable" >&2
        exit 1
      }
      api_key="$(xmllint --xpath 'string(configuration/gui/apikey)' "$config_file")"
      [[ "$api_key" =~ ^[A-Za-z0-9_-]+$ ]] || {
        echo "Syncthing API key is unavailable or malformed" >&2
        exit 1
      }
      printf 'header = "X-API-Key: %s"\n' "$api_key" \
        | curl --config - --fail --silent --show-error --max-time 300 -X POST \
          http://127.0.0.1:8384/rest/db/scan >/dev/null
    '';
  };
in
{
  systemd.services.media-manager = {
    description = "Catalog and coordinate safe media-library changes";
    wantedBy = [ "multi-user.target" ];
    requires = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    after = [ "network.target" "data-pool-layout.service" "media-manager-storage-access.service" ];
    environment = webEnvironment;
    restartTriggers = lib.optionals openSubtitlesConfigured [ config.age.secrets.openSubtitlesCredentials.file ];
    serviceConfig = {
      Type = "simple";
      User = "media-manager";
      Group = "media-manager";
      DynamicUser = false;
      ExecStart = lib.getExe cfg.package;
      Restart = "on-failure";
      RestartSec = "5s";
      StateDirectory = "media-manager";
      StateDirectoryMode = "0770";
      RuntimeDirectory = "media-manager";
      RuntimeDirectoryMode = "0750";
      UMask = "0007";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      # RestrictSUIDSGID blocks openat2, which contained media reads require.
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "-${vars.sharedRoot}" "-${vars.usersRoot}" "-/run/mkvmaker" ]
        ++ lib.optionals jellyfinMetadataAvailable [ "-/var/cache/media-manager-jellyfin" "-/var/lib/jellyfin/data/library-sync.api-key" ]
        ++ lib.optionals audiobookshelfMetadataAvailable [ "-/var/cache/media-manager-audiobookshelf" ]
        ++ lib.optionals kavitaMetadataAvailable [ "-/var/cache/media-manager-kavita" ];
      ReadWritePaths = [ cfg.stateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-scanner = {
    description = "Reconcile Media Manager catalogs with the current filesystem";
    requires = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    after = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    environment = commonEnvironment;
    serviceConfig = {
      Type = "oneshot";
      User = "media-manager";
      Group = "media-manager";
      ExecStart = lib.getExe' cfg.package "media-manager-scanner";
      UMask = "0007";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "-${vars.sharedRoot}" "-${vars.usersRoot}" ];
      ReadWritePaths = [ cfg.stateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.timers.media-manager-scanner = {
    description = "Periodically reconcile Media Manager catalogs";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitInactiveSec = "15m";
      RandomizedDelaySec = "2m";
      Persistent = true;
      Unit = "media-manager-scanner.service";
    };
  };

  systemd.services.media-manager-broker = {
    description = "Apply one queued Media Manager mutation plan";
    requires = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    after = [ "data-pool-layout.service" "media-manager-storage-access.service" ];
    environment = commonEnvironment;
    serviceConfig = {
      Type = "oneshot";
      User = "media-manager-broker";
      Group = "media-manager";
      SupplementaryGroups = [ "media-manager-broker" ];
      ExecStart = lib.getExe' cfg.package "media-manager-broker";
      UMask = "0007";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      # The broker uses the same openat2-based contained path traversal.
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadWritePaths = [ cfg.stateDir vars.sharedRoot vars.usersRoot ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.timers.media-manager-broker = lib.mkIf (cfg.mutationMode == "enabled") {
    description = "Poll the durable Media Manager mutation queue";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "20s";
      OnUnitInactiveSec = "10s";
      AccuracySec = "1s";
      Unit = "media-manager-broker.service";
    };
  };

  systemd.paths.media-manager-refresh-requests = {
    description = "Dispatch queued Media Manager application refresh requests";
    wantedBy = [ "paths.target" ];
    pathConfig = {
      PathChanged = "${cfg.stateDir}/refresh-requests";
      Unit = "media-manager-refresh-dispatch.service";
    };
  };

  systemd.services.media-manager-refresh-dispatch = {
    description = "Dispatch closed Media Manager refresh adapter requests";
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "media-manager";
      ExecStart = lib.getExe refreshDispatcher;
      UMask = "0027";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      PrivateNetwork = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectClock = true;
      ProtectHostname = true;
      RestrictAddressFamilies = [ "AF_UNIX" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadWritePaths = [ cfg.stateDir ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-refresh-jellyfin = lib.mkIf jellyfinRefreshAvailable {
    description = "Run and follow the Jellyfin media-library scan task";
    after = [ "jellyfin.service" ];
    wants = [ "jellyfin.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe jellyfinRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "/var/lib/jellyfin/data/library-sync.api-key" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-jellyfin-metadata = lib.mkIf jellyfinMetadataAvailable {
    description = "Export a bounded Jellyfin metadata snapshot for Media Manager";
    after = [ "jellyfin.service" ];
    wants = [ "jellyfin.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "media-manager";
      ExecStart = lib.getExe jellyfinMetadataExport;
      CacheDirectory = "media-manager-jellyfin";
      CacheDirectoryMode = "0750";
      UMask = "0027";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      MemoryMax = "256M";
      TasksMax = 32;
      TimeoutStartSec = "2m";
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "/var/lib/jellyfin/data/library-sync.api-key" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.timers.media-manager-jellyfin-metadata = lib.mkIf jellyfinMetadataAvailable {
    description = "Refresh the Media Manager Jellyfin metadata snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "2m";
      OnUnitInactiveSec = "30m";
      RandomizedDelaySec = "30s";
      Persistent = true;
      Unit = "media-manager-jellyfin-metadata.service";
    };
  };

  systemd.services.media-manager-audiobookshelf-metadata = lib.mkIf audiobookshelfMetadataAvailable {
    description = "Export a bounded Audiobookshelf metadata snapshot for Media Manager";
    after = [ "audiobookshelf.service" ];
    wants = [ "audiobookshelf.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "media-manager";
      ExecStart = lib.getExe audiobookshelfMetadataExport;
      CacheDirectory = "media-manager-audiobookshelf";
      CacheDirectoryMode = "0750";
      UMask = "0027";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      MemoryMax = "256M";
      TasksMax = 32;
      TimeoutStartSec = "3m";
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ config.age.secrets.absBootstrapPass.path ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.timers.media-manager-audiobookshelf-metadata = lib.mkIf audiobookshelfMetadataAvailable {
    description = "Refresh the Media Manager Audiobookshelf metadata snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "3m";
      OnUnitInactiveSec = "30m";
      RandomizedDelaySec = "45s";
      Persistent = true;
      Unit = "media-manager-audiobookshelf-metadata.service";
    };
  };

  systemd.services.media-manager-kavita-metadata = lib.mkIf kavitaMetadataAvailable {
    description = "Export a bounded Kavita metadata snapshot for Media Manager";
    after = [ "kavita.service" ];
    wants = [ "kavita.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kavita";
      Group = "media-manager";
      ExecStart = lib.getExe kavitaMetadataExport;
      CacheDirectory = "media-manager-kavita";
      CacheDirectoryMode = "0750";
      UMask = "0027";
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      MemoryMax = "256M";
      TasksMax = 32;
      TimeoutStartSec = "3m";
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "/var/lib/kavita/config/kavita.db" config.age.secrets.kavitaTokenKey.path ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" "fchown" ];
    };
  };

  systemd.timers.media-manager-kavita-metadata = lib.mkIf kavitaMetadataAvailable {
    description = "Refresh the Media Manager Kavita metadata snapshot";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnBootSec = "4m";
      OnUnitInactiveSec = "30m";
      RandomizedDelaySec = "45s";
      Persistent = true;
      Unit = "media-manager-kavita-metadata.service";
    };
  };

  systemd.services.media-manager-refresh-audiobookshelf = lib.mkIf audiobookshelfRefreshAvailable {
    description = "Request scans for every Audiobookshelf library";
    after = [ "audiobookshelf.service" ];
    wants = [ "audiobookshelf.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe audiobookshelfRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };

  systemd.services.media-manager-refresh-kavita = lib.mkIf kavitaRefreshAvailable {
    description = "Request and follow Kavita library scans";
    after = [ "kavita.service" "kavita-oidc-bootstrap.service" ];
    wants = [ "kavita.service" "kavita-oidc-bootstrap.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "kavita";
      Group = "kavita";
      ExecStart = lib.getExe kavitaRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      TimeoutStartSec = "2h5m";
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [
        "/var/lib/kavita/config/kavita.db"
        config.age.secrets.kavitaTokenKey.path
      ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" "fchown" ];
    };
  };

  systemd.services.media-manager-refresh-syncthing = lib.mkIf syncthingRefreshAvailable {
    description = "Request an immediate scan of every Syncthing folder";
    after = [ "syncthing.service" ];
    wants = [ "syncthing.service" ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      Group = "root";
      ExecStart = lib.getExe syncthingRefresh;
      NoNewPrivileges = true;
      PrivateTmp = true;
      PrivateDevices = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      ProtectKernelTunables = true;
      ProtectKernelModules = true;
      ProtectKernelLogs = true;
      ProtectControlGroups = true;
      ProtectProc = "invisible";
      ProcSubset = "pid";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictRealtime = true;
      RestrictSUIDSGID = true;
      LockPersonality = true;
      MemoryDenyWriteExecute = true;
      CapabilityBoundingSet = [ ];
      AmbientCapabilities = [ ];
      ReadOnlyPaths = [ "/var/lib/syncthing/.config/syncthing" ];
      IPAddressDeny = "any";
      IPAddressAllow = [ "localhost" ];
      SystemCallArchitectures = "native";
      SystemCallFilter = [ "@system-service" "~@privileged" "~@resources" ];
    };
  };
}
