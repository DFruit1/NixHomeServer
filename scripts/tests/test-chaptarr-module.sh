#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash jq mktemp nix rg

host="$(test_default_host)"
chaptarr_json="$(NIXHOMESERVER_TEST_HOST="$host" flake_eval_json '
  host = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  base = builtins.getAttr host f.nixosConfigurations;
  cfg = base.config;
  customCompleteCfg = (base.extendModules {
    modules = [{ repo.qbittorrent.paths.completeDir = "/mnt/data/shared/_Downloads/qbittorrent/done"; }];
  }).config;
  customLibraryCfg = (base.extendModules {
    modules = [{
      repo.chaptarr.paths.audiobookRoot = "/mnt/data/shared/_AlternateAudiobooks";
      repo.chaptarr.paths.ebookRoot = "/mnt/data/shared/_AlternateBooks/_Ebooks";
    }];
  }).config;
  invalidCompleteCfg = (base.extendModules {
    modules = [{ repo.qbittorrent.paths.completeDir = "/mnt/data/outside-qbittorrent"; }];
  }).config;
  service = cfg.systemd.services.chaptarr;
  container = cfg.virtualisation.oci-containers.containers.chaptarr;
in {
  registered = cfg.nixhomeserver.modules.chaptarr or false;
  image = container.image;
  serviceName = container.serviceName;
  networks = container.networks;
  ports = container.ports;
  volumes = container.volumes;
  environment = container.environment;
  serviceWants = service.wants;
  serviceAfter = service.after;
  serviceRestart = service.serviceConfig.Restart;
  runtimeDirectory = service.serviceConfig.RuntimeDirectory;
  audiobookRoot = cfg.repo.chaptarr.paths.audiobookRoot;
  audiobookshelfRoot = cfg.repo.audiobookshelf.paths.sharedAudiobooksRoot;
  ebookRoot = cfg.repo.chaptarr.paths.ebookRoot;
  kavitaEbookRoot = "${cfg.repo.kavita.paths.sharedBooksRoot}/_Ebooks";
  metadataServerUrl = cfg.repo.chaptarr.metadataServerUrl;
  protectedApp = cfg.repo.authGateway.protectedApps.chaptarr;
  privateDnsTarget = cfg.services.unbound.privateHosts."chaptarr.${f.lib.nixhomeserverSettings.${host}.domain}".target or null;
  chaptarrPort = f.lib.nixhomeserverSettings.${host}.networking.ports.chaptarr;
  userSystem = cfg.users.users.chaptarr.isSystemUser;
  userGroup = cfg.users.users.chaptarr.group;
  userExtraGroups = cfg.users.users.chaptarr.extraGroups;
  stateDirReadOnly = (builtins.getAttr host f.nixosConfigurations).options.repo.chaptarr.paths.stateDir.readOnly;
  guardedServices = cfg.repo.storage.dataPool.guardedServices;
  persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
  backupApps = map (entry: entry.app) cfg.repo.backups.appStateEntries;
  sqliteDumps = cfg.repo.backups.sqliteDumps;
  sharedRoots = cfg.repo.storage.sharedRoots.contentSubdirs;
  qbitBootstrap = cfg.systemd.services."media-automation-bootstrap-qbittorrent".script;
  mediaLayout = cfg.systemd.services."media-automation-storage-layout-v1".script;
  chaptarrLayout = cfg.systemd.services."chaptarr-storage-layout-v1".script;
  chaptarrBootstrap = cfg.systemd.services."media-automation-bootstrap-chaptarr".script;
  chaptarrBootstrapRuntimeDirectory = cfg.systemd.services."media-automation-bootstrap-chaptarr".serviceConfig.RuntimeDirectory;
  chaptarrBootstrapUser = cfg.systemd.services."media-automation-bootstrap-chaptarr".serviceConfig.User;
  chaptarrBootstrapGroup = cfg.systemd.services."media-automation-bootstrap-chaptarr".serviceConfig.Group;
  chaptarrBootstrapNoNewPrivileges = cfg.systemd.services."media-automation-bootstrap-chaptarr".serviceConfig.NoNewPrivileges;
  prowlarrBootstrap = cfg.systemd.services."media-automation-bootstrap-prowlarr".script;
  prowlarrBootstrapRuntimeDirectory = cfg.systemd.services."media-automation-bootstrap-prowlarr".serviceConfig.RuntimeDirectory;
  customCompleteBootstrap = customCompleteCfg.systemd.services."media-automation-bootstrap-chaptarr".script;
  customLibraryLayout = customLibraryCfg.systemd.services."chaptarr-storage-layout-v1".script;
  invalidCompleteMessages = map (entry: entry.message) (builtins.filter (entry: !entry.assertion) invalidCompleteCfg.assertions);
}
')"

jq -e '
  .registered
  and (.image | test("^docker[.]io/chaptarr/chaptarr@sha256:[0-9a-f]{64}$"))
  and (.serviceName == "chaptarr")
  and (.networks == ["host"])
  and (.ports == [])
  and (.volumes | any(endswith(":/config")))
  and (.volumes | any(endswith(":/audiobooks")))
  and (.volumes | any(endswith(":/ebooks")))
  and (.volumes | any(endswith(":/downloads")))
  and (.environment.UMASK == "002")
  and (.serviceWants | index("chaptarr-storage-layout-v1.service") != null)
  and (.serviceAfter | index("chaptarr-storage-layout-v1.service") != null)
  and (.serviceRestart == "on-failure")
  and (.runtimeDirectory == "chaptarr")
  and (.audiobookRoot == .audiobookshelfRoot)
  and (.ebookRoot == .kavitaEbookRoot)
  and (.metadataServerUrl == "https://api2.chaptarr.com")
  and (.protectedApp.host | startswith("chaptarr."))
  and (.protectedApp.upstream == "http://127.0.0.1:8789")
  and (.protectedApp.allowedGroups == ["media-automation-users"])
  and (.privateDnsTarget == "private")
  and (.chaptarrPort == 8789)
  and .userSystem
  and (.userGroup == "chaptarr")
  and ((.userExtraGroups | index("media-automation")) == null)
  and .stateDirReadOnly
  and (.guardedServices | index("chaptarr") != null)
  and (.guardedServices | index("chaptarr-storage-layout-v1") != null)
  and (.guardedServices | index("media-automation-bootstrap-chaptarr") != null)
  and (.persistence | index("/var/lib/chaptarr") != null)
  and (.backupApps | index("chaptarr") != null)
  and (.sqliteDumps | any(.source == "/var/lib/chaptarr/chaptarr.db" and .outputName == "chaptarr.sqlite"))
  and (.sharedRoots | index("_Audiobooks") != null)
  and (.sharedRoots | index("_Books") != null)
  and (.sharedRoots | index("_Downloads") != null)
  and (.qbitBootstrap | contains("create_category books"))
  and (.mediaLayout | contains("g:chaptarr:r-X"))
  and (.mediaLayout | contains("g:chaptarr:rwx,d:g:chaptarr:rwx"))
  and (.mediaLayout | contains("install -d -m 1770 -o root -g media-automation"))
  and ((.mediaLayout | contains("install -d -m 0770 -o root -g media-automation")) | not)
  and (.chaptarrLayout | contains("setfacl -P -R -m g:chaptarr:rwX"))
  and (.chaptarrLayout | contains("-type d -exec setfacl -m d:g:chaptarr:rwx"))
  and (.chaptarrBootstrap | contains("/api/v1/downloadclient/schema"))
  and (.chaptarrBootstrap | contains("/api/v1/config/development"))
  and (.chaptarrBootstrap | contains("/api/v1/config/development/test"))
  and (.chaptarrBootstrap | contains("https://api2.chaptarr.com"))
  and (.chaptarrBootstrap | contains("/api/v1/rootfolder"))
  and (.chaptarrBootstrap | contains("/api/v1/config/mediamanagement"))
  and (.chaptarrBootstrap | contains("/audiobooks"))
  and (.chaptarrBootstrap | contains("/ebooks"))
  and (.chaptarrBootstrap | contains("category\" then .value = \"books"))
  and (.chaptarrBootstrap | contains("/api/v1/remotepathmapping"))
  and (.chaptarrBootstrap | contains("remotePath"))
  and (.chaptarrBootstrap | contains("localPath"))
  and (.chaptarrBootstrap | contains("/mnt/data/shared/_Downloads/qbittorrent/complete/"))
  and (.chaptarrBootstrap | contains("/downloads/complete/"))
  and (.chaptarrBootstrap | contains("download_client_id"))
  and (.chaptarrBootstrap | contains("downloadClientId: $downloadClientId"))
  and (.chaptarrBootstrap | contains("/api/v1/remotepathmapping/test"))
  and (.chaptarrBootstrap | contains(".downloadClientPathChecked"))
  and (.chaptarrBootstrap | contains(".downloadClientPathMatched"))
  and (.chaptarrBootstrapRuntimeDirectory == "media-automation-bootstrap-chaptarr")
  and (.chaptarrBootstrapUser == "chaptarr")
  and (.chaptarrBootstrapGroup == "chaptarr")
  and .chaptarrBootstrapNoNewPrivileges
  and ((.chaptarrBootstrap | contains("-H \"X-Api-Key: $api_key\"")) | not)
  and ((.chaptarrBootstrap | contains("--data-binary \"$payload\"")) | not)
  and (.prowlarrBootstrap | contains("upsert_app Chaptarr Readarr"))
  and (.prowlarrBootstrapRuntimeDirectory == "media-automation-bootstrap-prowlarr")
  and ((.prowlarrBootstrap | contains("-H \"X-Api-Key: $prowlarr_key\"")) | not)
  and ((.prowlarrBootstrap | contains("--arg apiKey \"$api_key\"")) | not)
  and ((.prowlarrBootstrap | contains("--data-binary \"$payload\"")) | not)
  and (.customCompleteBootstrap | contains("/mnt/data/shared/_Downloads/qbittorrent/done/"))
  and (.customCompleteBootstrap | contains("/downloads/done/"))
  and (.customLibraryLayout | contains("/mnt/data/shared/_AlternateAudiobooks"))
  and (.customLibraryLayout | contains("/mnt/data/shared/_AlternateBooks/_Ebooks"))
  and (.customLibraryLayout != .chaptarrLayout)
  and (.invalidCompleteMessages | any(contains("completed-download directory must be below its download root so Chaptarr can translate it into /downloads")))
' <<<"$chaptarr_json" >/dev/null || {
  echo "❌ Chaptarr is missing a pinned container, private route, durable state, dual-format storage, or media-automation bootstrap."
  jq . <<<"$chaptarr_json"
  exit 1
}

for source_file in modules/chaptarr/services.nix modules/chaptarr/filepaths.nix modules/Integrations/wire_media_automation_stack.nix; do
  if rg -n '(:latest|pull = "always")' "$source_file"; then
    echo "❌ Chaptarr must not use a mutable image tag or unconditional pull policy: $source_file"
    exit 1
  fi
done

if ! rg -Fq '[wire_media_automation_stack]="chaptarr sonarr radarr prowlarr qbittorrent jellyfin"' scripts/tests/test-integration-dependencies.sh; then
  echo "❌ Conditional media-automation participants are not represented in dependency metadata."
  exit 1
fi

enabled_apps_file="$(mktemp)"
trap 'rm -f "$enabled_apps_file"' EXIT
printf '%s\n' \
  'mail-archive-ui,files,audiobookshelf,jellyfin,kavita,kiwix,paperless,youtube-downloader,chaptarr,prowlarr,qbittorrent' \
  >"$enabled_apps_file"
NIXHOMESERVER_STRICT_INTEGRATION_DEPS=1 \
  NIXHOMESERVER_ENABLED_APPS_FILE="$enabled_apps_file" \
  scripts/tests/test-integration-dependencies.sh >/dev/null
rm -f "$enabled_apps_file"
trap - EXIT

if ! rg -Fq 'id = "chaptarr"; name = "Book Downloads"' modules/Core_Modules/homepage/canary.nix; then
  echo "❌ Chaptarr is missing from the authenticated service-access canary."
  exit 1
fi

if ! rg -Fq 'id = "chaptarr";' modules/Core_Modules/homepage/services.nix \
  || ! rg -Fq 'enabled = chaptarrEnabled;' modules/Core_Modules/homepage/services.nix; then
  echo "❌ Chaptarr is missing its conditional Homepage service card."
  exit 1
fi

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT
mkdir -p "$tmpdir/bin" "$tmpdir/runtime"
jq -r '.chaptarrBootstrap' <<<"$chaptarr_json" >"$tmpdir/chaptarr-bootstrap.sh"
chmod +x "$tmpdir/chaptarr-bootstrap.sh"
cat >"$tmpdir/config.xml" <<'EOF'
<Config><ApiKey>TEST_CHAPTARR_KEY</ApiKey></Config>
EOF

real_jq="$(command -v jq)"
cat >"$tmpdir/bin/jq" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
for arg in "$@"; do
  if [[ "$arg" == *TEST_CHAPTARR_KEY* ]]; then
    echo "API key leaked into jq argv" >&2
    exit 90
  fi
done
exec "$REAL_JQ" "$@"
EOF

cat >"$tmpdir/bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

method=GET
url=""
read_stdin=false
for ((index = 1; index <= $#; index++)); do
  arg="${!index}"
  if [[ "$arg" == *TEST_CHAPTARR_KEY* ]]; then
    echo "API key leaked into curl argv" >&2
    exit 91
  fi
  case "$arg" in
    -X)
      next=$((index + 1))
      method="${!next}"
      ;;
    --data-binary)
      next=$((index + 1))
      [[ "${!next}" != "@-" ]] || read_stdin=true
      ;;
    http://*) url="$arg" ;;
  esac
done

payload=""
if [[ "$read_stdin" == true ]]; then
  payload="$(cat)"
fi
printf '%s %s\n' "$method" "$url" >>"$MOCK_CALL_LOG"

case "$method $url" in
  "GET "*/api/v1/system/status)
    printf '{}\n'
    ;;
  "GET "*/api/v1/config/development)
    printf '%s\n' '{"id":1,"metadataServerUrl":"https://stale.invalid","consoleLogLevel":"","logSql":false,"logRotate":7,"filterSentryEvents":true}'
    ;;
  "PUT "*/api/v1/config/development/1)
    "$REAL_JQ" -e '.id == 1 and .metadataServerUrl == "https://api2.chaptarr.com"' <<<"$payload" >/dev/null
    ;;
  "POST "*/api/v1/config/development/test)
    "$REAL_JQ" -e '.id == 1 and .metadataServerUrl == "https://api2.chaptarr.com"' <<<"$payload" >/dev/null
    printf '%s\n' '{"successMessages":["Metadata server OK"]}'
    ;;
  "GET "*/api/v1/rootfolder)
    if [[ -s "$MOCK_ROOT_STATE" ]]; then
      "$REAL_JQ" -s '.' "$MOCK_ROOT_STATE"
    else
      printf '%s\n' '[]'
    fi
    ;;
  "POST "*/api/v1/rootfolder)
    "$REAL_JQ" -e '
      (.path == "/audiobooks" and .name == "Audiobookshelf" and .folderType == 1)
      or (.path == "/ebooks" and .name == "Kavita Ebooks" and .folderType == 2)
    ' <<<"$payload" >/dev/null
    root_id="$(( $(wc -l <"$MOCK_ROOT_STATE") + 1 ))"
    "$REAL_JQ" -c --argjson id "$root_id" '.id = $id' <<<"$payload" >>"$MOCK_ROOT_STATE"
    ;;
  "GET "*/api/v1/config/mediamanagement)
    printf '%s\n' '{"id":1,"defaultAudiobookRootFolderPath":"","defaultEbookRootFolderPath":"","minimumFreeSpaceWhenImporting":100}'
    ;;
  "PUT "*/api/v1/config/mediamanagement/1)
    "$REAL_JQ" -e '
      .id == 1
      and .defaultAudiobookRootFolderPath == "/audiobooks"
      and .defaultEbookRootFolderPath == "/ebooks"
    ' <<<"$payload" >/dev/null
    ;;
  "GET "*/api/v1/downloadclient/schema)
    printf '%s\n' '[{"implementation":"QBittorrent","fields":[{"name":"host"},{"name":"port"},{"name":"useSsl"},{"name":"urlBase"},{"name":"username"},{"name":"password"},{"name":"category"},{"name":"recentPriority"},{"name":"olderPriority"},{"name":"initialState"}]}]'
    ;;
  "GET "*/api/v1/downloadclient)
    if [[ -e "$MOCK_CLIENT_STATE" ]]; then
      printf '%s\n' '[{"id":7,"name":"qBittorrent"}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  "POST "*/api/v1/downloadclient)
    "$REAL_JQ" -e '.name == "qBittorrent" and (.fields[] | select(.name == "category").value == "books")' <<<"$payload" >/dev/null
    : >"$MOCK_CLIENT_STATE"
    ;;
  "PUT "*/api/v1/downloadclient/7)
    "$REAL_JQ" -e '.id == 7 and .name == "qBittorrent"' <<<"$payload" >/dev/null
    ;;
  "GET "*/api/v1/remotepathmapping)
    if [[ -e "$MOCK_LEGACY_MAPPING_STATE" ]]; then
      printf '%s\n' '[{"id":9,"downloadClientId":7,"host":"127.0.0.1","remotePath":"/mnt/data/shared/_Downloads/qbittorrent/complete/books/","localPath":"/downloads/complete/books/"}]'
    elif [[ -e "$MOCK_MAPPING_STATE" ]]; then
      printf '%s\n' '[{"id":9,"downloadClientId":7,"host":"127.0.0.1","remotePath":"/mnt/data/shared/_Downloads/qbittorrent/complete/","localPath":"/downloads/complete/"}]'
    else
      printf '%s\n' '[]'
    fi
    ;;
  "POST "*/api/v1/remotepathmapping/test)
    "$REAL_JQ" -e '
      .downloadClientId == 7
      and .remotePath == "/mnt/data/shared/_Downloads/qbittorrent/complete/"
      and .localPath == "/downloads/complete/"
    ' <<<"$payload" >/dev/null
    printf '%s\n' '{"isMapped":true,"localPathExists":true,"localPathWritable":true,"downloadClientPathChecked":true,"downloadClientPathMatched":true,"downloadClientTestError":null}'
    ;;
  "POST "*/api/v1/remotepathmapping)
    if [[ -e "$MOCK_LEGACY_MAPPING_STATE" ]]; then
      echo "Download client already has a scoped remote path mapping" >&2
      exit 93
    fi
    "$REAL_JQ" -e '.downloadClientId == 7' <<<"$payload" >/dev/null
    : >"$MOCK_MAPPING_STATE"
    ;;
  "PUT "*/api/v1/remotepathmapping/9)
    "$REAL_JQ" -e '.id == 9 and .downloadClientId == 7' <<<"$payload" >/dev/null
    ;;
  *)
    echo "Unexpected mock Chaptarr request: $method $url" >&2
    exit 92
    ;;
esac
EOF
make_test_executable "$tmpdir/bin/jq" "$tmpdir/bin/curl"

call_log="$tmpdir/calls.log"
client_state="$tmpdir/client.state"
mapping_state="$tmpdir/mapping.state"
legacy_mapping_state="$tmpdir/legacy-mapping.state"
root_state="$tmpdir/root-folders.jsonl"
: >"$call_log"
: >"$root_state"
for _ in 1 2; do
  PATH="$tmpdir/bin:$PATH" \
    REAL_JQ="$real_jq" \
    CHAPTARR_CONFIG_XML="$tmpdir/config.xml" \
    RUNTIME_DIRECTORY="$tmpdir/runtime" \
    MOCK_CALL_LOG="$call_log" \
    MOCK_CLIENT_STATE="$client_state" \
    MOCK_MAPPING_STATE="$mapping_state" \
    MOCK_LEGACY_MAPPING_STATE="$legacy_mapping_state" \
    MOCK_ROOT_STATE="$root_state" \
    bash "$tmpdir/chaptarr-bootstrap.sh"
done

if [[ "$(rg -c '^POST .*/api/v1/downloadclient$' "$call_log")" != 1 ]] \
  || [[ "$(rg -c '^PUT .*/api/v1/downloadclient/7$' "$call_log")" != 1 ]] \
  || [[ "$(rg -c '^POST .*/api/v1/remotepathmapping$' "$call_log")" != 1 ]] \
  || [[ "$(rg -c '^PUT .*/api/v1/remotepathmapping/9$' "$call_log")" != 1 ]] \
  || [[ "$(rg -c '^POST .*/api/v1/remotepathmapping/test$' "$call_log")" != 2 ]] \
  || [[ "$(rg -c '^POST .*/api/v1/rootfolder$' "$call_log")" != 2 ]] \
  || [[ "$(rg -c '^PUT .*/api/v1/config/mediamanagement/1$' "$call_log")" != 2 ]]; then
  echo "❌ Chaptarr bootstrap did not converge idempotently through create, update, and live mapping validation."
  cat "$call_log"
  exit 1
fi

rm -f "$mapping_state"
: >"$client_state"
: >"$legacy_mapping_state"
: >"$call_log"
PATH="$tmpdir/bin:$PATH" \
  REAL_JQ="$real_jq" \
  CHAPTARR_CONFIG_XML="$tmpdir/config.xml" \
  RUNTIME_DIRECTORY="$tmpdir/runtime" \
  MOCK_CALL_LOG="$call_log" \
  MOCK_CLIENT_STATE="$client_state" \
  MOCK_MAPPING_STATE="$mapping_state" \
  MOCK_LEGACY_MAPPING_STATE="$legacy_mapping_state" \
  MOCK_ROOT_STATE="$root_state" \
  bash "$tmpdir/chaptarr-bootstrap.sh"

if [[ "$(rg -c '^PUT .*/api/v1/remotepathmapping/9$' "$call_log")" != 1 ]] \
  || rg -q '^POST .*/api/v1/remotepathmapping$' "$call_log"; then
  echo "❌ Chaptarr bootstrap did not update an existing scoped remote-path mapping in place."
  cat "$call_log"
  exit 1
fi

echo "✅ Chaptarr container, storage, backup, private access, and download automation checks passed."
