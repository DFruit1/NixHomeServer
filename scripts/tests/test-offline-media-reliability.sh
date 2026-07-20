#!/usr/bin/env bash
# shellcheck disable=SC2016

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools cmp jq nix rg

behavior_json="$(nix eval --impure --json --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packages = import ./flake/packages.nix {
      inherit lib pkgs;
      crane = f.inputs.crane;
    };
    mkConfig = vars: (import ./flake/system.nix {
      inputs = f.inputs;
      inherit lib vars pkgs;
      system = base.hostPlatform;
      appPackages = packages.appPackages;
    }).nixosConfigurations.${base.hostname}.config;
    customVars = base // {
      offlineMedia = base.offlineMedia // {
        enable = true;
        accessGroup = "offline-media-users";
      };
    };
    disabledVars = customVars // {
      offlineMedia = customVars.offlineMedia // { enable = false; };
    };
    custom = mkConfig customVars;
    disabled = mkConfig disabledVars;
    homepageConfigDrv = builtins.head (builtins.attrNames (builtins.getContext
      (toString custom.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE)));
    enrollCommandDrv = builtins.head (builtins.attrNames (builtins.getContext
      (toString custom.systemd.services.homepage.environment.HOMEPAGE_OFFLINE_MEDIA_ENROLL_COMMAND)));
    removeCommandDrv = builtins.head (builtins.attrNames (builtins.getContext
      (toString custom.systemd.services.homepage.environment.HOMEPAGE_OFFLINE_MEDIA_REMOVE_COMMAND)));
    removedMatrix = import ./flake/module-removal-matrix.nix {
      inherit lib pkgs;
      vars = customVars;
      inherit (f.inputs) agenix impermanence filestashNix;
      inherit (packages) appPackages;
      sourcePath = f.outPath;
      requestedVariants = [ "without-offline-music" ];
    };
  in {
    customGroup = custom.services.kanidm.provision.groups.offline-media-users;
    customDescription = custom.nixhomeserver.kanidmGroupDescriptions.offline-media-users;
    gatewayScopes = builtins.attrNames custom.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps;
    homepageScopes = builtins.attrNames custom.services.kanidm.provision.systems.oauth2.homepage-web.scopeMaps;
    gatewayHomepageRoles = custom.repo.authGateway.protectedApps.homepage.allowedGroups;
    expectedHomepageRoles = lib.unique [
      "users"
      customVars.fileAccess.webAccessGroup
      customVars.fileAccess.sftpAccessGroup
      customVars.fileAccess.sharedAccessGroup
      customVars.fileAccess.usbAccessGroup
      customVars.backupStorageGroup
    ];
    inherit enrollCommandDrv homepageConfigDrv removeCommandDrv;
    disabled = {
      groupPresent = builtins.hasAttr "offline-media-users" disabled.services.kanidm.provision.groups;
      gatewayScopePresent = builtins.hasAttr "offline-media-users" disabled.services.kanidm.provision.systems.oauth2.auth-gateway-web.scopeMaps;
      homepageScopePresent = builtins.hasAttr "offline-media-users" disabled.services.kanidm.provision.systems.oauth2.homepage-web.scopeMaps;
      syncthingEnabled = disabled.services.syncthing.enable;
      cleanupPresent = builtins.hasAttr "offline-media-disabled-cleanup" disabled.systemd.services;
    };
    removed = removedMatrix.without-offline-music.offlineMediaSurface;
  }
')"

if ! jq -e '
  (.customGroup.members == [])
  and (.customGroup.overwriteMembers == false)
  and (.customDescription | contains("baseline users"))
  and (.gatewayScopes | index("offline-media-users") != null)
  and (.homepageScopes | index("offline-media-users") != null)
  and ((.expectedHomepageRoles - .gatewayScopes) == [])
  and ((.expectedHomepageRoles - .homepageScopes) == [])
  and ((.gatewayHomepageRoles | sort) == (.expectedHomepageRoles | sort))
  and (.disabled == {
    groupPresent: false,
    gatewayScopePresent: false,
    homepageScopePresent: false,
    syncthingEnabled: false,
    cleanupPresent: true
  })
  and (.removed.syncthingEnabled == false)
  and (.removed.gatewayRegistered == false)
  and (.removed.homepageEnvironmentPresent == false)
  and (.removed.disabledCleanupPresent == true)
  and (.removed.dedicatedAccessGroupPresent == false)
  and (.removed.dedicatedGatewayScopePresent == false)
  and (.removed.dedicatedHomepageScopePresent == false)
' <<<"$behavior_json" >/dev/null; then
  echo "❌ Offline-media group provisioning, claims, role coverage, disable, or removal behavior regressed." >&2
  jq . <<<"$behavior_json" >&2
  exit 1
fi

derivation_text() {
  local derivation="$1"

  nix derivation show "$derivation" | jq -er '
    (if has("derivations") then .derivations else . end)
    | to_entries
    | if length == 1 and (.[0].value.env.text | type) == "string" then
        .[0].value.env.text
      else
        error("expected one text derivation")
      end
  '
}

homepage_config="$(derivation_text "$(jq -er '.homepageConfigDrv' <<<"$behavior_json")")"
enroll_script_text="$(derivation_text "$(jq -er '.enrollCommandDrv' <<<"$behavior_json")")"
remove_script_text="$(derivation_text "$(jq -er '.removeCommandDrv' <<<"$behavior_json")")"
if ! jq -e '
  (.offlineMedia.requiredAllGroups == ["users"])
  and (.offlineMedia.requiredAnyGroups == ["offline-media-users"])
  and (.services[] | select(.id == "offline-media")
    | .requiredAllGroups == ["users"]
    and .requiredAnyGroups == ["offline-media-users"]
    and (.loginNotes | contains("baseline users membership")))
  and (.adminGuide[] | select(.title == "Revoke offline-media device access")
    | (.command | contains("offline-media-users"))
    and (.command | contains("offline-media-reconcile.service"))
    and (.detail | contains("never deletes source media")))
' <<<"$homepage_config" >/dev/null; then
  echo "❌ Homepage did not encode additive offline-media access and immediate offboarding reconciliation." >&2
  exit 1
fi

default_host="$(test_default_host)"
baseline_homepage_drv="$(NIXHOMESERVER_TEST_HOST="$default_host" nix eval --impure --raw --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
    cfg = (builtins.getAttr hostName f.nixosConfigurations).config;
  in builtins.head (builtins.attrNames (builtins.getContext
    (toString cfg.systemd.services.homepage.environment.HOMEPAGE_CONFIG_FILE)))
')"
baseline_homepage_config="$(derivation_text "$baseline_homepage_drv")"
if ! jq -e '
  .offlineMedia.requiredAnyGroups == ["users"]
  and (.services[] | select(.id == "offline-media")
    | (.loginNotes | contains("baseline users membership"))
    and ((.loginNotes | contains("plus users")) | not))
  and (.adminGuide[] | select(.title == "Revoke offline-media device access")
    | (has("command") | not)
    and (.detail | contains("Never remove that group"))
    and (.detail | contains("remove each enrolled device")))
' <<<"$baseline_homepage_config" >/dev/null; then
  echo "❌ Homepage offered an unsafe baseline-users removal command for offline-media revocation." >&2
  exit 1
fi

invalid_log="$(mktemp)"
test_dir="$(mktemp -d)"
cleanup() {
  rm -f "$invalid_log"
  rm -rf "$test_dir"
}
trap cleanup EXIT

enroll_script_file="$test_dir/homepage-offline-media-enroll"
remove_script_file="$test_dir/homepage-offline-media-remove"
printf '%s\n' "$enroll_script_text" >"$enroll_script_file"
printf '%s\n' "$remove_script_text" >"$remove_script_file"

state_commit_match="$(rg -n -m 1 -F 'mv "$state_tmp" "$state_file"' "$enroll_script_file" || true)"
first_syncthing_mutation_match="$(rg -n -m 1 -F 'api_json POST /rest/config/devices "$device_json"' "$enroll_script_file" || true)"
state_validation_match="$(rg -n -m 1 -F '"$state_file" >/dev/null; then' "$enroll_script_file" || true)"
first_acl_mutation_match="$(rg -n -m 1 -F 'setfacl' "$enroll_script_file" || true)"
state_commit_line="${state_commit_match%%:*}"
first_syncthing_mutation_line="${first_syncthing_mutation_match%%:*}"
state_validation_line="${state_validation_match%%:*}"
first_acl_mutation_line="${first_acl_mutation_match%%:*}"
if [[ ! "$state_commit_line" =~ ^[0-9]+$ || ! "$first_syncthing_mutation_line" =~ ^[0-9]+$ ]] \
  || (( state_commit_line >= first_syncthing_mutation_line )); then
  echo "❌ Generated enrollment helper can mutate Syncthing before durable enrollment intent is committed." >&2
  exit 1
fi
if [[ ! "$state_validation_line" =~ ^[0-9]+$ || ! "$first_acl_mutation_line" =~ ^[0-9]+$ ]] \
  || (( state_validation_line >= first_acl_mutation_line )); then
  echo "❌ Generated enrollment helper can mutate filesystem ACLs before validating enrollment state." >&2
  exit 1
fi

assert_atomic_state_initialisation() {
  local generated_helper="$1"
  local init_match validation_match mode_match owner_match commit_match
  local init_line validation_line mode_line owner_line commit_line

  init_match="$(rg -n -m 1 -F 'state_init_tmp="$(' "$generated_helper" || true)"
  validation_match="$(rg -n -m 1 -F '"$state_init_tmp" >/dev/null' "$generated_helper" || true)"
  mode_match="$(rg -n -m 1 -F 'chmod 0640 "$state_init_tmp"' "$generated_helper" || true)"
  owner_match="$(rg -n -m 1 -F 'chown root:root "$state_init_tmp"' "$generated_helper" || true)"
  commit_match="$(rg -n -m 1 -F 'mv "$state_init_tmp" "$state_file"' "$generated_helper" || true)"
  init_line="${init_match%%:*}"
  validation_line="${validation_match%%:*}"
  mode_line="${mode_match%%:*}"
  owner_line="${owner_match%%:*}"
  commit_line="${commit_match%%:*}"

  if [[ ! "$init_line" =~ ^[0-9]+$ || ! "$validation_line" =~ ^[0-9]+$ \
        || ! "$mode_line" =~ ^[0-9]+$ || ! "$owner_line" =~ ^[0-9]+$ \
        || ! "$commit_line" =~ ^[0-9]+$ ]] \
    || (( init_line >= validation_line || validation_line >= mode_line \
          || mode_line >= owner_line || owner_line >= commit_line )); then
    echo "❌ Generated helper does not atomically validate and install first-host enrollment state: $generated_helper" >&2
    exit 1
  fi
}

assert_atomic_state_initialisation "$enroll_script_file"
assert_atomic_state_initialisation "$remove_script_file"

device_inventory_match="$(rg -n -m 1 -F 'devices_json="$(api /rest/config/devices)"' "$remove_script_file" || true)"
device_presence_match="$(rg -n -m 1 -F 'any(.[]; .deviceID == $deviceId)' "$remove_script_file" || true)"
device_delete_match="$(rg -n -m 1 -F 'api /rest/config/devices/"$device_id" -X DELETE' "$remove_script_file" || true)"
folder_reference_match="$(rg -n -m 1 -F 'any(.[] | select(.id == $folderId) | (.devices // [])[]?; .deviceID == $deviceId)' "$remove_script_file" || true)"
folder_update_match="$(rg -n -m 1 -F 'api_json POST /rest/config/folders "$folder_json"' "$remove_script_file" || true)"
device_inventory_line="${device_inventory_match%%:*}"
device_presence_line="${device_presence_match%%:*}"
device_delete_line="${device_delete_match%%:*}"
folder_reference_line="${folder_reference_match%%:*}"
folder_update_line="${folder_update_match%%:*}"
if [[ ! "$device_inventory_line" =~ ^[0-9]+$ || ! "$device_presence_line" =~ ^[0-9]+$ \
      || ! "$device_delete_line" =~ ^[0-9]+$ ]] \
  || (( device_inventory_line >= device_presence_line || device_presence_line >= device_delete_line )); then
  echo "❌ Generated removal helper does not verify global device presence before DELETE." >&2
  exit 1
fi
if [[ ! "$folder_reference_line" =~ ^[0-9]+$ || ! "$folder_update_line" =~ ^[0-9]+$ ]] \
  || (( folder_reference_line >= folder_update_line )); then
  echo "❌ Generated removal helper can rewrite a folder after its device reference is already absent." >&2
  exit 1
fi
if [[ "$(rg -c -F -- '--argjson status' "$remove_script_file" || true)" != 1 ]]; then
  echo "❌ Generated removal response must pass its status JSON to jq exactly once." >&2
  exit 1
fi
for generated_helper in "$enroll_script_file" "$remove_script_file"; do
  require_fixed "$generated_helper" '^[a-z][a-z0-9._-]{0,63}$' \
    "generated offline-media helper must enforce canonical lowercase Kanidm usernames"
  require_fixed "$generated_helper" '^[A-Za-z0-9._ -]{1,64}$' \
    "generated offline-media helper must enforce printable device names"
done

invalid_group_expr='
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    lib = f.inputs.nixpkgs.lib;
    base = import ./vars.nix { inherit lib; };
    vars = base // {
      offlineMedia = base.offlineMedia // {
        enable = true;
        accessGroup = builtins.getEnv "NIXHOMESERVER_TEST_OFFLINE_GROUP";
      };
    };
    pkgs = f.inputs.nixpkgs.legacyPackages.${base.hostPlatform};
    packages = import ./flake/packages.nix { inherit lib pkgs; crane = f.inputs.crane; };
    system = import ./flake/system.nix {
      inputs = f.inputs;
      inherit lib vars pkgs;
      system = base.hostPlatform;
      appPackages = packages.appPackages;
    };
  in system.nixosConfigurations.${base.hostname}.config.system.build.toplevel.drvPath
'

assert_invalid_group() {
  local group_name="$1"
  local expected_message="$2"

  if NIXHOMESERVER_TEST_OFFLINE_GROUP="$group_name" \
      nix eval --impure --raw --expr "$invalid_group_expr" >"$invalid_log" 2>&1; then
    echo "❌ Invalid offlineMedia.accessGroup '$group_name' passed evaluation." >&2
    exit 1
  fi
  if ! rg -Fq "$expected_message" "$invalid_log"; then
    echo "❌ Invalid offlineMedia.accessGroup '$group_name' failed without actionable guidance." >&2
    cat "$invalid_log" >&2
    exit 1
  fi
}

assert_invalid_group 'Bad Group' 'offlineMedia.accessGroup must be a valid lowercase Kanidm group name'
backup_admin_group="$(nix eval --impure --raw --expr '
  let f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
      lib = f.inputs.nixpkgs.lib;
  in (import ./vars.nix { inherit lib; }).backupAdminGroup
')"
assert_invalid_group "$backup_admin_group" 'collides with a reserved, file-access, application, or exactly managed backup group'

reconcile_script=scripts/helpers/offline-media-reconcile.sh
for mutation_source in "$reconcile_script" modules/homepage/services.nix scripts/helpers/offline-media-disabled-cleanup.sh; do
  require_fixed "$mutation_source" '.devices.lock' \
    "offline-media mutations in $mutation_source must share the persistent lock"
  require_fixed "$mutation_source" 'flock -x 9' \
    "offline-media mutations in $mutation_source must acquire the shared lock exclusively"
done
require_fixed "$reconcile_script" 'snapshot_group_members users' \
  "reconciliation must snapshot baseline users membership"
require_fixed "$reconcile_script" 'snapshot_group_members "$OFFLINE_MEDIA_ACCESS_GROUP"' \
  "reconciliation must snapshot the configured dedicated group"
require_fixed scripts/helpers/offline-media-disabled-cleanup.sh 'Source media and devices.json' \
  "disabled cleanup must retain source media and enrollment state"
require_fixed scripts/helpers/offline-media-disabled-cleanup.sh '^[a-z][a-z0-9._-]{0,63}$' \
  "disabled cleanup must reject non-canonical persisted usernames"
require_fixed modules/Core_Modules/syncthing/default.nix 'offline-media-disabled-cleanup' \
  "disabled cleanup must live in a core module that survives optional-module removal"

# Keep every runtime boundary aligned with lib/name-validation.nix. A local
# Kanidm name starts with a lowercase letter and may otherwise contain dots;
# rejecting consecutive dots only in these helpers would make a valid host
# configuration fail later during self-service enrollment or reconciliation.
if rg -Fq 'contains("..")' \
    modules/homepage/services.nix \
    scripts/helpers/offline-media-reconcile.sh \
    scripts/helpers/offline-media-disabled-cleanup.sh \
  || rg -Fq '"$username" == *..*' \
    modules/homepage/services.nix \
    scripts/helpers/offline-media-reconcile.sh \
    scripts/helpers/offline-media-disabled-cleanup.sh; then
  echo "❌ Offline-media helpers impose a username rule that diverges from canonical Kanidm validation." >&2
  exit 1
fi

mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"
command_log="$test_dir/commands.log"
folders_file="$test_dir/folders.json"
devices_file="$test_dir/devices.json"
state_dir="$test_dir/state"
state_file="$state_dir/devices.json"
users_root="$test_dir/users"
mkdir -p "$state_dir" "$users_root/alice/_Music/.stfolder" "$users_root/bob/_Music/.stfolder"
printf 'test-password\n' >"$test_dir/kanidm-password"
printf '<configuration><gui><apikey>test</apikey></gui></configuration>\n' >"$test_dir/config.xml"

shared_id='AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA-AAAAAAA'
stale_id='BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB-BBBBBBB'
folder_specs='[{"key":"music","label":"Music","relativePath":"_Music","folderIdPrefix":"nixhomeserver-music","suggestedDevicePath":"Music/NixHomeServer"}]'

jq -n \
  --arg shared "$shared_id" \
  --arg stale "$stale_id" '
  {
    version: 2,
    users: {
      alice: {devices: [{deviceId: $shared, deviceName: "shared-phone", createdAt: "", updatedAt: ""}]},
      bob: {devices: [
        {deviceId: $shared, deviceName: "shared-phone", createdAt: "", updatedAt: ""},
        {deviceId: $stale, deviceName: "retired-phone", createdAt: "", updatedAt: ""}
      ]}
    }
  }' >"$test_dir/state.initial.json"
jq -n \
  --arg shared "$shared_id" \
  --arg stale "$stale_id" \
  --arg alicePath "$users_root/alice/_Music" \
  --arg bobPath "$users_root/bob/_Music" '[
    {
      id: "nixhomeserver-music-alice", label: "NixHomeServer Music - alice", path: $alicePath,
      type: "sendonly", paused: false, fsWatcherEnabled: true, rescanIntervalS: 300,
      devices: [{deviceID: $shared}]
    },
    {
      id: "nixhomeserver-music-bob", label: "NixHomeServer Music - bob", path: $bobPath,
      type: "sendonly", paused: false, fsWatcherEnabled: true, rescanIntervalS: 300,
      devices: [{deviceID: $shared}, {deviceID: $stale}]
    }
  ]' >"$test_dir/folders.initial.json"
jq -n --arg shared "$shared_id" --arg stale "$stale_id" '[
  {deviceID: $shared, name: "shared-phone", addresses: ["dynamic"]},
  {deviceID: $stale, name: "retired-phone", addresses: ["dynamic"]}
]' >"$test_dir/devices.initial.json"

cat >"$mock_bin/kanidm" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${MOCK_IDENTITY_FAIL:-0}" == 1 && "${1:-} ${2:-}" == "group get" ]]; then
  exit 42
fi
case "${1:-} ${2:-}" in
  "login "*) exit 0 ;;
  "group get")
    if [[ "${MOCK_MALFORMED_MEMBERS:-0}" == 1 ]]; then
      printf '{"attrs":{"member":[{}]}}\n'
      exit 0
    fi
    group_name="${3:-}"
    if [[ "$group_name" == users ]]; then
      members="${MOCK_BASELINE_MEMBERS_JSON}"
    else
      members="${MOCK_ACCESS_MEMBERS_JSON}"
    fi
    jq -cn --argjson members "$members" '{attrs:{member:$members}}'
    ;;
  *) exit 1 ;;
esac
EOF

cat >"$mock_bin/xmllint" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'test-api-key'
EOF

cat >"$mock_bin/runuser" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == -u && "${3:-}" == -- ]]
shift 3
if [[ "${1:-}" == find \
      && -n "${MOCK_FIND_TRAVERSAL_FAIL_ROOT:-}" \
      && "${2:-}" == "$MOCK_FIND_TRAVERSAL_FAIL_ROOT" ]]; then
  printf "find: '%s/inaccessible-nested': Permission denied\n" \
    "$MOCK_FIND_TRAVERSAL_FAIL_ROOT" >&2
  exit 45
fi
exec "$@"
EOF

cat >"$mock_bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
exit 0
EOF

cat >"$mock_bin/curl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
method=GET
url=
read_payload=false
while (($#)); do
  case "$1" in
    -X) method="$2"; shift 2 ;;
    -H|--connect-timeout|--max-time) shift 2 ;;
    --data-binary) read_payload=true; shift 2 ;;
    http://*) url="$1"; shift ;;
    *) shift ;;
  esac
done
payload=
if [[ "$read_payload" == true ]]; then
  payload="$(cat)"
fi
path="/${url#*://*/}"
if [[ "$method" != GET && "$path" == /rest/config/* ]]; then
  printf 'MUTATION %s %s\n' "$method" "$path" >>"$MOCK_COMMAND_LOG"
  if [[ -n "${MOCK_FAIL_MUTATION_PATH:-}" && "$path" == *"$MOCK_FAIL_MUTATION_PATH"* ]]; then
    exit 43
  fi
fi
replace_array_item() {
  local file="$1" key="$2" value="$3" temporary
  temporary="$(mktemp)"
  jq --arg key "$key" --arg value "$value" --argjson item "$payload" \
    '[.[] | select(.[$key] != $value)] + [$item]' "$file" >"$temporary"
  mv "$temporary" "$file"
}
case "$method $path" in
  "GET /rest/system/ping") printf '{}\n' ;;
  "GET /rest/config/folders") cat "$MOCK_FOLDERS_FILE" ;;
  "GET /rest/config/devices") cat "$MOCK_DEVICES_FILE" ;;
  "GET /rest/config/defaults/device") printf '{"addresses":["dynamic"]}\n' ;;
  "GET /rest/config/defaults/folder") printf '{"devices":[],"paused":false}\n' ;;
  "GET /rest/config/restart-required") printf '{"requiresRestart":false}\n' ;;
  "GET /rest/system/connections") printf '{"connections":{}}\n' ;;
  "GET /rest/stats/device") printf '{}\n' ;;
  "GET /rest/db/status"*|"GET /rest/db/status?"*) printf '{"error":""}\n' ;;
  "POST /rest/db/scan"*) printf '{}\n' ;;
  "POST /rest/config/folders")
    folder_id="$(jq -er .id <<<"$payload")"
    replace_array_item "$MOCK_FOLDERS_FILE" id "$folder_id"
    ;;
  "POST /rest/config/devices")
    device_id="$(jq -er .deviceID <<<"$payload")"
    replace_array_item "$MOCK_DEVICES_FILE" deviceID "$device_id"
    ;;
  "DELETE /rest/config/folders/"*)
    folder_id="${path##*/}"
    temporary="$(mktemp)"
    jq --arg id "$folder_id" '[.[] | select(.id != $id)]' "$MOCK_FOLDERS_FILE" >"$temporary"
    mv "$temporary" "$MOCK_FOLDERS_FILE"
    ;;
  "DELETE /rest/config/devices/"*)
    device_id="${path##*/}"
    temporary="$(mktemp)"
    jq --arg id "$device_id" '[.[] | select(.deviceID != $id)]' "$MOCK_DEVICES_FILE" >"$temporary"
    mv "$temporary" "$MOCK_DEVICES_FILE"
    ;;
  *)
    echo "unexpected mock curl request: $method $path" >&2
    exit 44
    ;;
esac
EOF
make_test_executable "$mock_bin/kanidm" "$mock_bin/xmllint" "$mock_bin/runuser" "$mock_bin/systemctl" "$mock_bin/curl"

reset_runtime_case() {
  cp "$test_dir/state.initial.json" "$state_file"
  cp "$test_dir/folders.initial.json" "$folders_file"
  cp "$test_dir/devices.initial.json" "$devices_file"
  : >"$command_log"
}

run_reconcile() {
  local access_members_json="${TEST_ACCESS_MEMBERS_JSON:-}"
  if [[ -z "$access_members_json" ]]; then
    access_members_json='["alice@example.test"]'
  fi

  PATH="$mock_bin:$PATH" \
  MOCK_COMMAND_LOG="$command_log" \
  MOCK_FOLDERS_FILE="$folders_file" \
  MOCK_DEVICES_FILE="$devices_file" \
  MOCK_FIND_TRAVERSAL_FAIL_ROOT="${TEST_FIND_TRAVERSAL_FAIL_ROOT:-}" \
  MOCK_BASELINE_MEMBERS_JSON='["alice@example.test","bob@example.test"]' \
  MOCK_ACCESS_MEMBERS_JSON="$access_members_json" \
  OFFLINE_MEDIA_ACCESS_GROUP=offline-media-users \
  OFFLINE_MEDIA_FOLDER_SPECS_JSON="$folder_specs" \
  OFFLINE_MEDIA_KANIDM_PASSWORD_FILE="$test_dir/kanidm-password" \
  OFFLINE_MEDIA_KANIDM_URL=https://identity.invalid:8443 \
  OFFLINE_MEDIA_LOCK_FILE="$state_dir/.devices.lock" \
  OFFLINE_MEDIA_STATE_FILE="$state_file" \
  OFFLINE_MEDIA_STATE_OWNER="$(id -u)" \
  OFFLINE_MEDIA_STATE_GROUP="$(id -g)" \
  OFFLINE_MEDIA_SYNCTHING_CONFIG="$test_dir/config.xml" \
  OFFLINE_MEDIA_USERS_ROOT="$users_root" \
  "$reconcile_script"
}

reset_runtime_case
mkdir -p "$users_root/alice/_Music/inaccessible-nested"
cp "$state_file" "$test_dir/state.before-traversal-failure.json"
cp "$folders_file" "$test_dir/folders.before-traversal-failure.json"
cp "$devices_file" "$test_dir/devices.before-traversal-failure.json"
if TEST_ACCESS_MEMBERS_JSON='["alice@example.test","bob@example.test"]' \
    TEST_FIND_TRAVERSAL_FAIL_ROOT="$users_root/alice/_Music" \
    run_reconcile >/dev/null 2>"$test_dir/traversal-failure.stderr"; then
  echo "❌ Reconciliation accepted an inaccessible nested source directory." >&2
  exit 1
fi
if ! rg -Fq 'Syncthing cannot fully traverse' "$test_dir/traversal-failure.stderr"; then
  echo "❌ Nested source-directory traversal failure lacked actionable diagnostics." >&2
  cat "$test_dir/traversal-failure.stderr" >&2
  exit 1
fi
if ! cmp -s "$state_file" "$test_dir/state.before-traversal-failure.json" \
  || ! cmp -s "$folders_file" "$test_dir/folders.before-traversal-failure.json" \
  || ! cmp -s "$devices_file" "$test_dir/devices.before-traversal-failure.json" \
  || rg -q '^MUTATION ' "$command_log"; then
  echo "❌ Nested source-directory traversal failure caused premature mutation." >&2
  exit 1
fi

reset_runtime_case
if ! run_reconcile >/dev/null 2>"$test_dir/reconcile.stderr"; then
  echo "❌ Active/stale/shared-device reconciliation failed unexpectedly." >&2
  cat "$test_dir/reconcile.stderr" >&2
  exit 1
fi
if ! jq -e --arg shared "$shared_id" '
    (.users | keys) == ["alice"]
    and .users.alice.devices[0].deviceId == $shared
  ' "$state_file" >/dev/null \
  || ! jq -e --arg shared "$shared_id" '
    length == 1 and .[0].deviceID == $shared
  ' "$devices_file" >/dev/null \
  || ! jq -e '
    length == 1 and .[0].id == "nixhomeserver-music-alice"
  ' "$folders_file" >/dev/null; then
  echo "❌ Reconciliation did not revoke the stale user while retaining the active user and shared device." >&2
  exit 1
fi

# A disabled cleanup removes runtime config but leaves enrollment state.  The
# next authorized reconcile must recreate the active peer and folder.
printf '[]\n' >"$folders_file"
printf '[]\n' >"$devices_file"
: >"$command_log"
if ! run_reconcile >/dev/null 2>"$test_dir/recreate.stderr"; then
  echo "❌ Authorized runtime recreation failed unexpectedly." >&2
  cat "$test_dir/recreate.stderr" >&2
  exit 1
fi
if ! jq -e --arg shared "$shared_id" 'length == 1 and .[0].deviceID == $shared' "$devices_file" >/dev/null \
  || ! jq -e 'length == 1 and .[0].id == "nixhomeserver-music-alice"' "$folders_file" >/dev/null; then
  echo "❌ Reconciliation did not recreate authorized runtime configuration after disabled cleanup." >&2
  exit 1
fi

reset_runtime_case
cp "$state_file" "$test_dir/state.before-identity-failure.json"
cp "$folders_file" "$test_dir/folders.before-identity-failure.json"
cp "$devices_file" "$test_dir/devices.before-identity-failure.json"
if MOCK_IDENTITY_FAIL=1 run_reconcile >/dev/null 2>&1; then
  echo "❌ Reconciliation succeeded after a mocked Kanidm failure." >&2
  exit 1
fi
if ! cmp -s "$state_file" "$test_dir/state.before-identity-failure.json" \
  || ! cmp -s "$folders_file" "$test_dir/folders.before-identity-failure.json" \
  || ! cmp -s "$devices_file" "$test_dir/devices.before-identity-failure.json" \
  || rg -q '^MUTATION ' "$command_log"; then
  echo "❌ Identity failure caused premature offline-media mutation." >&2
  exit 1
fi

reset_runtime_case
cp "$state_file" "$test_dir/state.before-malformed-members.json"
cp "$folders_file" "$test_dir/folders.before-malformed-members.json"
cp "$devices_file" "$test_dir/devices.before-malformed-members.json"
if MOCK_MALFORMED_MEMBERS=1 run_reconcile >/dev/null 2>&1; then
  echo "❌ Reconciliation accepted a Kanidm member array containing a non-string entry." >&2
  exit 1
fi
if ! cmp -s "$state_file" "$test_dir/state.before-malformed-members.json" \
  || ! cmp -s "$folders_file" "$test_dir/folders.before-malformed-members.json" \
  || ! cmp -s "$devices_file" "$test_dir/devices.before-malformed-members.json" \
  || rg -q '^MUTATION ' "$command_log"; then
  echo "❌ Malformed Kanidm membership caused premature Syncthing or enrollment-state mutation." >&2
  exit 1
fi

assert_invalid_state_rejected() {
  local label="$1"
  local state_filter="$2"

  reset_runtime_case
  jq "$state_filter" "$state_file" >"$test_dir/state.invalid.json"
  mv "$test_dir/state.invalid.json" "$state_file"
  cp "$state_file" "$test_dir/state.before-invalid-state.json"
  cp "$folders_file" "$test_dir/folders.before-invalid-state.json"
  cp "$devices_file" "$test_dir/devices.before-invalid-state.json"
  if run_reconcile >/dev/null 2>&1; then
    echo "❌ Reconciliation accepted invalid enrollment state: $label." >&2
    exit 1
  fi
  if ! cmp -s "$state_file" "$test_dir/state.before-invalid-state.json" \
    || ! cmp -s "$folders_file" "$test_dir/folders.before-invalid-state.json" \
    || ! cmp -s "$devices_file" "$test_dir/devices.before-invalid-state.json" \
    || rg -q '^MUTATION ' "$command_log"; then
    echo "❌ Invalid enrollment state caused a Syncthing or state mutation: $label." >&2
    exit 1
  fi
}

assert_invalid_state_rejected \
  'uppercase username' \
  '.users.Alice = .users.alice | del(.users.alice)'
assert_invalid_state_rejected \
  'username beginning with punctuation' \
  '.users["-alice"] = .users.alice | del(.users.alice)'
assert_invalid_state_rejected \
  'device name containing a path separator' \
  '.users.alice.devices[0].deviceName = "bad/name"'

reset_runtime_case
if MOCK_FAIL_MUTATION_PATH='nixhomeserver-music-bob' run_reconcile >/dev/null 2>&1; then
  echo "❌ Reconciliation succeeded after a mocked Syncthing detach failure." >&2
  exit 1
fi
if ! jq -e '.users | has("bob")' "$state_file" >/dev/null; then
  echo "❌ Syncthing API failure pruned enrollment state instead of retaining it for retry." >&2
  exit 1
fi

echo "✅ Offline-media provisioning, additive authorization, revocation, disable/removal cleanup, and guidance passed."
