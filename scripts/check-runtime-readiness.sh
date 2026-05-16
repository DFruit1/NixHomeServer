#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$script_dir/helpers/repo-common.sh"
source "$script_dir/helpers/runtime-health-common.sh"
init_repo_root "RUNTIME_READINESS_REPO_ROOT"
cd_repo_root
source "$script_dir/helpers/storage-health-common.sh"
ensure_default_nix_config

usage() {
  cat <<'EOF'
Usage: scripts/check-runtime-readiness.sh [--profile manual|deploy|monitor] [--deep] [--format text|json] [--require-online-zpool]

Read-only runtime validation for the active host. It checks core units,
entrypoints, Unbound answers, storage state, app-state roots, and backup
freshness against vars.nix and the evaluated host config.

Examples:
  sudo ./scripts/check-runtime-readiness.sh
  sudo ./scripts/check-runtime-readiness.sh --profile deploy
  sudo ./scripts/check-runtime-readiness.sh --profile manual --deep
EOF
}

profile="manual"
output_format="text"
deep_checks=0
host_cmd="${RUNTIME_READINESS_HOST_CMD:-host}"

while (($# > 0)); do
  case "$1" in
    --profile)
      profile="${2:-}"
      shift 2
      ;;
    --format)
      output_format="${2:-}"
      shift 2
      ;;
    --deep)
      deep_checks=1
      shift
      ;;
    --require-online-zpool)
      profile="deploy"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 1
      ;;
  esac
done

case "$profile" in
  manual|deploy|monitor)
    ;;
  *)
    echo "❌ --profile must be manual, deploy, or monitor." >&2
    exit 1
    ;;
esac

case "$output_format" in
  text|json)
    ;;
  *)
    echo "❌ --format must be text or json." >&2
    exit 1
    ;;
esac

need curl systemctl findmnt blkid jq smartctl journalctl zpool zfs runuser stat date readlink getent id sort
need "$host_cmd"

if [[ -z "${RUNTIME_HEALTH_SNAPSHOT_JSON_FILE:-}" ]]; then
  need nix
fi

runtime_health_load_snapshot

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
units_file="${tmpdir}/units.jsonl"
edge_http_file="${tmpdir}/edge-http.jsonl"
internal_http_file="${tmpdir}/internal-http.jsonl"
dns_file="${tmpdir}/dns.jsonl"
mounts_file="${tmpdir}/mounts.jsonl"
app_state_file="${tmpdir}/app-state.jsonl"
paths_file="${tmpdir}/paths.jsonl"
persistence_file="${tmpdir}/persistence.jsonl"
deep_file="${tmpdir}/deep.jsonl"
access_local_file="${tmpdir}/access-local.jsonl"
access_authed_file="${tmpdir}/access-authed.jsonl"
backup_file="${tmpdir}/backup.json"
discovery_json_file="${tmpdir}/storage-discovery.json"
disk_specs_file="${tmpdir}/smart-disk-specs.json"

: >"$units_file"
: >"$edge_http_file"
: >"$internal_http_file"
: >"$dns_file"
: >"$mounts_file"
: >"$app_state_file"
: >"$paths_file"
: >"$persistence_file"
: >"$deep_file"
: >"$access_local_file"
: >"$access_authed_file"

failed=0

emit_text() {
  if [[ "$output_format" == "text" ]]; then
    printf '%s\n' "$*"
  fi
}

result_is_critical() {
  [[ "$1" == "CRITICAL" ]]
}

mark_failed_if_critical() {
  if result_is_critical "$1"; then
    failed=1
  fi
}

append_json() {
  runtime_health_append_json_line "$1" "$2"
}

unit_result_json() {
  jq -nc \
    --arg unit "$1" \
    --arg active "$2" \
    --arg severity "$3" \
    --arg detail "$4" \
    '{ unit: $unit, activeState: $active, severity: $severity, detail: $detail }'
}

http_result_json() {
  jq -nc \
    --arg scope "$1" \
    --arg name "$2" \
    --arg url "$3" \
    --arg code "$4" \
    --arg severity "$5" \
    --arg detail "$6" \
    --argjson expected "$7" \
    '{ scope: $scope, name: $name, url: $url, httpCode: $code, severity: $severity, detail: $detail, expected: $expected }'
}

dns_result_json() {
  jq -nc \
    --arg kind "$1" \
    --arg host "$2" \
    --arg answer "$3" \
    --arg severity "$4" \
    --arg detail "$5" \
    '{ kind: $kind, host: $host, answer: $answer, severity: $severity, detail: $detail }'
}

path_result_json() {
  jq -nc \
    --arg category "$1" \
    --arg label "$2" \
    --arg path "$3" \
    --arg severity "$4" \
    --arg detail "$5" \
    --argjson present "$6" \
    '{ category: $category, label: $label, path: $path, severity: $severity, detail: $detail, present: $present }'
}

backup_result_json() {
  jq -nc \
    --arg service "$1" \
    --arg timer "$2" \
    --arg serviceResult "$3" \
    --arg timerActive "$4" \
    --arg timerEnabled "$5" \
    --arg selectionState "$6" \
    --arg selectedDevice "$7" \
    --arg mountSource "$8" \
    --arg timestamp "$9" \
    --arg ageSeconds "${10}" \
    --arg severity "${11}" \
    --arg detail "${12}" \
    --argjson targetPresent "${13}" \
    '{
      service: $service,
      timer: $timer,
      serviceResult: $serviceResult,
      timerActive: $timerActive,
      timerEnabled: $timerEnabled,
      selectionState: $selectionState,
      selectedDevice: $selectedDevice,
      mountSource: $mountSource,
      timestamp: $timestamp,
      ageSeconds: (if $ageSeconds == "" then null else ($ageSeconds | tonumber) end),
      severity: $severity,
      detail: $detail,
      targetPresent: $targetPresent
    }'
}

deep_result_json() {
  jq -nc \
    --arg kind "$1" \
    --arg name "$2" \
    --arg target "$3" \
    --arg severity "$4" \
    --arg detail "$5" \
    '{ kind: $kind, name: $name, target: $target, severity: $severity, detail: $detail }'
}

access_result_json() {
  jq -nc \
    --arg scope "$1" \
    --arg app "$2" \
    --arg canary "$3" \
    --arg severity "$4" \
    --arg detail "$5" \
    --arg finalUrl "$6" \
    --arg httpCode "$7" \
    '{
      scope: $scope,
      app: $app,
      canary: (if $canary == "" then null else $canary end),
      severity: $severity,
      detail: $detail,
      finalUrl: (if $finalUrl == "" then null else $finalUrl end),
      httpCode: (if $httpCode == "" then null else $httpCode end)
    }'
}

check_unit() {
  local unit="$1"
  local active_state severity detail

  active_state="$(systemctl is-active "$unit" 2>/dev/null || true)"
  if [[ "$active_state" == "active" ]]; then
    severity="OK"
    detail="unit active"
    emit_text "✅ unit active: $unit"
  else
    severity="CRITICAL"
    detail="active=${active_state:-unknown}"
    emit_text "❌ unit inactive: $unit"
  fi

  append_json "$units_file" "$(unit_result_json "$unit" "$active_state" "$severity" "$detail")"
  mark_failed_if_critical "$severity"
}

check_http() {
  local scope="$1"
  local name="$2"
  local url="$3"
  local expected_json="$4"
  local code severity detail
  local allowed

  code="$(curl -sk -o /dev/null -w '%{http_code}' "$url" || true)"
  severity="CRITICAL"
  detail="unexpected http ${code:-<no response>}"

  while IFS= read -r allowed; do
    if [[ "$code" == "$allowed" ]]; then
      severity="OK"
      detail="http ${code}"
      break
    fi
  done < <(jq -r '.[]' <<<"$expected_json")

  if [[ "$severity" == "OK" ]]; then
    emit_text "✅ http $code: $url"
  else
    emit_text "❌ unexpected http ${code:-<no response>}: $url (expected one of: $(jq -r 'join(", ")' <<<"$expected_json"))"
  fi

  if [[ "$scope" == "edge" ]]; then
    append_json "$edge_http_file" "$(http_result_json "$scope" "$name" "$url" "$code" "$severity" "$detail" "$expected_json")"
  else
    append_json "$internal_http_file" "$(http_result_json "$scope" "$name" "$url" "$code" "$severity" "$detail" "$expected_json")"
  fi
  mark_failed_if_critical "$severity"
}

check_local_access_unauth() {
  local app_json="$1"
  local app_name host_name path expected_json redirect_prefix url
  local headers_file code location severity detail allowed

  app_name="$(jq -r '.name' <<<"$app_json")"
  host_name="$(jq -r '.localUnauthCheck.host' <<<"$app_json")"
  path="$(jq -r '.localUnauthCheck.path' <<<"$app_json")"
  expected_json="$(jq -c '.localUnauthCheck.expected' <<<"$app_json")"
  redirect_prefix="$(jq -r '.localUnauthCheck.redirectPrefix // ""' <<<"$app_json")"
  headers_file="$(mktemp "${tmpdir}/access-local-headers.XXXXXX")"
  url="https://${host_name}${path}"

  code="$(curl -sk -D "$headers_file" -o /dev/null -w '%{http_code}' --resolve "${host_name}:443:127.0.0.1" "$url" || true)"
  location="$(awk 'BEGIN{IGNORECASE=1} /^Location:/ { sub(/\r$/, "", $2); print $2; exit }' "$headers_file")"
  rm -f "$headers_file"

  severity="CRITICAL"
  detail="unexpected http ${code:-<no response>}"
  while IFS= read -r allowed; do
    if [[ "$code" == "$allowed" ]]; then
      severity="OK"
      detail="http ${code}"
      break
    fi
  done < <(jq -r '.[]' <<<"$expected_json")

  if [[ "$severity" == "OK" && -n "$redirect_prefix" ]]; then
    if [[ "$location" == "$redirect_prefix"* ]]; then
      detail="http ${code}, redirect ${location}"
    else
      severity="CRITICAL"
      detail="http ${code}, redirect ${location:-<missing>} did not match ${redirect_prefix}"
    fi
  fi

  if [[ "$severity" == "OK" ]]; then
    emit_text "✅ local access edge ${app_name}: ${detail}"
  else
    emit_text "❌ local access edge ${app_name}: ${detail}"
  fi

  append_json "$access_local_file" "$(access_result_json "local-unauth" "$app_name" "" "$severity" "$detail" "$location" "$code")"
  mark_failed_if_critical "$severity"
}

check_dns_resolves() {
  local host_name="$1"
  local answer severity detail

  answer="$("$host_cmd" "$host_name" 127.0.0.1 2>/dev/null | awk '/has address/ { print $4; exit }')"
  if [[ -n "$answer" ]]; then
    severity="OK"
    detail="resolved"
    emit_text "✅ dns ${host_name} -> ${answer}"
  else
    severity="CRITICAL"
    detail="no answer"
    emit_text "❌ dns ${host_name} -> <no answer>"
  fi

  append_json "$dns_file" "$(dns_result_json "resolve" "$host_name" "${answer:-}" "$severity" "$detail")"
  mark_failed_if_critical "$severity"
}

check_private_dns() {
  local host_name="$1"
  local expected_ip="$2"
  local answer severity detail

  answer="$("$host_cmd" "$host_name" 127.0.0.1 2>/dev/null | awk '/has address/ { print $4; exit }')"
  if [[ "$answer" == "$expected_ip" ]]; then
    severity="OK"
    detail="matched expected private answer"
    emit_text "✅ dns ${host_name} -> ${answer}"
  else
    severity="CRITICAL"
    detail="expected ${expected_ip}, got ${answer:-<no answer>}"
    emit_text "❌ dns ${host_name} -> ${answer:-<no answer>} (expected ${expected_ip})"
  fi

  append_json "$dns_file" "$(dns_result_json "private" "$host_name" "${answer:-}" "$severity" "$detail")"
  mark_failed_if_critical "$severity"
}

check_public_dns() {
  local host_name="$1"
  local forbidden_ip="$2"
  local answer severity detail

  answer="$("$host_cmd" "$host_name" 127.0.0.1 2>/dev/null | awk '/has address/ { print $4; exit }')"
  if [[ -n "$answer" && "$answer" != "$forbidden_ip" ]]; then
    severity="OK"
    detail="resolved to public answer"
    emit_text "✅ dns ${host_name} -> ${answer} (public path)"
  else
    severity="CRITICAL"
    detail="expected non-${forbidden_ip} answer, got ${answer:-<no answer>}"
    emit_text "❌ dns ${host_name} -> ${answer:-<no answer>} (expected non-${forbidden_ip} public answer)"
  fi

  append_json "$dns_file" "$(dns_result_json "public" "$host_name" "${answer:-}" "$severity" "$detail")"
  mark_failed_if_critical "$severity"
}

check_ptr_dns() {
  local ip="$1"
  local expected_name="$2"
  local answer severity detail

  answer="$("$host_cmd" "$ip" 127.0.0.1 2>/dev/null | awk '/domain name pointer/ { print $5; exit }' | sed 's/\.$//')"
  if [[ "$answer" == "$expected_name" ]]; then
    severity="OK"
    detail="matched expected PTR"
    emit_text "✅ ptr ${ip} -> ${answer}"
  else
    severity="CRITICAL"
    detail="expected ${expected_name}, got ${answer:-<no answer>}"
    emit_text "❌ ptr ${ip} -> ${answer:-<no answer>} (expected ${expected_name})"
  fi

  append_json "$dns_file" "$(dns_result_json "ptr" "$ip" "${answer:-}" "$severity" "$detail")"
  mark_failed_if_critical "$severity"
}

check_path_exists() {
  local category="$1"
  local label="$2"
  local path="$3"
  local severity detail present

  if [[ -e "$path" ]]; then
    severity="OK"
    detail="present"
    present=true
    emit_text "✅ ${category}: ${path}"
  else
    severity="CRITICAL"
    detail="missing"
    present=false
    emit_text "❌ ${category} missing: ${path}"
  fi

  append_json "$paths_file" "$(path_result_json "$category" "$label" "$path" "$severity" "$detail" "$present")"
  mark_failed_if_critical "$severity"
}

check_persist_binding() {
  local path="$1"
  local source severity detail present

  if [[ ! -e "$path" ]]; then
    severity="WARN"
    detail="missing persistence target"
    present=false
    emit_text "⚠️  persistence target missing: ${path}"
  else
    source="$(findmnt -nro SOURCE --target "$path" 2>/dev/null || true)"
    if [[ "$source" == *"[/persist/"* ]]; then
      severity="OK"
      detail="persistent binding present"
      present=true
      emit_text "✅ persistent binding: ${path}"
    else
      severity="CRITICAL"
      detail="unexpected binding source: ${source:-missing}"
      present=true
      emit_text "❌ persistent binding unexpected for ${path}: ${source:-missing}"
    fi
  fi

  append_json "$persistence_file" "$(path_result_json "persistence" "$path" "$path" "$severity" "$detail" "$present")"
  mark_failed_if_critical "$severity"
}

run_as_user() {
  local user="$1"
  shift

  if (( EUID == 0 )); then
    runuser -u "$user" -- "$@"
  else
    sudo -u "$user" "$@"
  fi
}

check_copyparty_upload_permissions() {
  local access_json service_user required_group upload_roots_parent upload_subdir
  local group_entry group_members id_groups upload_dir probe_path detail severity present found_upload_root=0

  access_json="$(runtime_health_snapshot_query '.uploadAccess.copyparty')"
  service_user="$(jq -r '.serviceUser' <<<"$access_json")"
  required_group="$(jq -r '.requiredGroup' <<<"$access_json")"
  upload_roots_parent="$(jq -r '.uploadRootsParent' <<<"$access_json")"
  upload_subdir="$(jq -r '.uploadSubdir' <<<"$access_json")"

  group_entry="$(getent group "$required_group" 2>/dev/null || true)"
  group_members="$(awk -F: '{ print $4 }' <<<"$group_entry")"
  if [[ -n "$group_entry" && ",${group_members}," == *",${service_user},"* ]]; then
    severity="OK"
    detail="group contains ${service_user}"
    present=true
    emit_text "✅ upload group ${required_group} contains ${service_user}"
  else
    severity="CRITICAL"
    detail="group is missing ${service_user}"
    present=false
    emit_text "❌ upload group ${required_group} is missing ${service_user}"
  fi
  append_json "$paths_file" "$(path_result_json "upload permission" "copyparty-group-membership" "group:${required_group}" "$severity" "$detail" "$present")"
  mark_failed_if_critical "$severity"

  id_groups="$(id -nG "$service_user" 2>/dev/null || true)"
  if [[ -n "$id_groups" && " ${id_groups} " == *" ${required_group} "* ]]; then
    severity="OK"
    detail="identity includes ${required_group}"
    present=true
    emit_text "✅ upload identity ${service_user} includes ${required_group}"
  else
    severity="CRITICAL"
    detail="identity is missing ${required_group}"
    present=false
    emit_text "❌ upload identity ${service_user} is missing ${required_group}"
  fi
  append_json "$paths_file" "$(path_result_json "upload permission" "copyparty-identity-groups" "user:${service_user}" "$severity" "$detail" "$present")"
  mark_failed_if_critical "$severity"

  while IFS= read -r upload_dir; do
    [[ -n "$upload_dir" ]] || continue
    found_upload_root=1
    probe_path="${upload_dir}/.copyparty-runtime-write-probe.$$"
    if run_as_user "$service_user" sh -lc 'probe_path="$1"; : >"$probe_path" && rm -f "$probe_path"' sh "$probe_path" >/dev/null 2>&1; then
      severity="OK"
      detail="service user can create and remove files"
      present=true
      emit_text "✅ upload path writable: ${upload_dir}"
    else
      severity="CRITICAL"
      detail="service user cannot create and remove files"
      present=true
      emit_text "❌ upload path not writable by ${service_user}: ${upload_dir}"
    fi
    append_json "$paths_file" "$(path_result_json "upload permission" "copyparty-upload-root" "$upload_dir" "$severity" "$detail" "$present")"
    mark_failed_if_critical "$severity"
  done < <(
    find "$upload_roots_parent" -mindepth 2 -maxdepth 2 -type d -name "$upload_subdir" -print 2>/dev/null \
      | sort
  )

  if (( found_upload_root == 0 )); then
    emit_text "ℹ️ No managed Copyparty upload roots exist yet under ${upload_roots_parent}; skipping write probe."
    append_json "$paths_file" "$(path_result_json "upload permission" "copyparty-upload-root" "${upload_roots_parent}/${upload_subdir}" "OK" "no managed upload roots discovered yet" "false")"
  fi
}

check_mail_archive_filebrowser_permissions() {
  local access_json service_user store_root visible_file hidden_root
  local detail severity present found_hidden_root=0

  access_json="$(runtime_health_snapshot_query '.mailArchiveFilebrowser // {}')"
  service_user="$(jq -r '.serviceUser // empty' <<<"$access_json")"
  store_root="$(jq -r '.storeRoot // empty' <<<"$access_json")"
  if [[ -z "$service_user" || -z "$store_root" ]]; then
    return 0
  fi

  visible_file="$(
    find "$store_root" \
      -path '*/emails/.internal-sync' -prune \
      -o -path '*/emails/*.eml' -type f -print 2>/dev/null \
      | sort \
      | sed -n '1p'
  )"
  if [[ -n "$visible_file" ]]; then
    if run_as_user "$service_user" test -r "$visible_file" >/dev/null 2>&1; then
      severity="OK"
      detail="visible email mirror file is readable by ${service_user}"
      present=true
      emit_text "✅ mail archive visible mirror readable by ${service_user}: ${visible_file}"
    else
      severity="CRITICAL"
      detail="visible email mirror file is not readable by ${service_user}"
      present=true
      emit_text "❌ mail archive visible mirror not readable by ${service_user}: ${visible_file}"
    fi
  else
    severity="WARN"
    detail="no visible .eml mirror files discovered yet"
    present=false
    visible_file="${store_root}/*/emails/*.eml"
    emit_text "⚠️  no visible mail archive .eml files found; skipping FileBrowser read probe"
  fi
  append_json "$paths_file" "$(path_result_json "mail archive permission" "mail-archive-visible-eml-readable" "$visible_file" "$severity" "$detail" "$present")"
  mark_failed_if_critical "$severity"

  while IFS= read -r hidden_root; do
    [[ -n "$hidden_root" ]] || continue
    found_hidden_root=1
    if run_as_user "$service_user" test ! -x "$hidden_root" >/dev/null 2>&1; then
      severity="OK"
      detail="hidden sync root is not traversable by ${service_user}"
      present=true
      emit_text "✅ mail archive hidden sync root blocked from ${service_user}: ${hidden_root}"
    else
      severity="CRITICAL"
      detail="hidden sync root is traversable by ${service_user}"
      present=true
      emit_text "❌ mail archive hidden sync root traversable by ${service_user}: ${hidden_root}"
    fi
    append_json "$paths_file" "$(path_result_json "mail archive permission" "mail-archive-hidden-sync-not-traversable" "$hidden_root" "$severity" "$detail" "$present")"
    mark_failed_if_critical "$severity"
  done < <(
    find "$store_root" -path '*/emails/.internal-sync' -type d -print 2>/dev/null \
      | sort
  )

  if (( found_hidden_root == 0 )); then
    emit_text "⚠️  no hidden mail archive sync roots found; skipping FileBrowser traversal probe"
    append_json "$paths_file" "$(path_result_json "mail archive permission" "mail-archive-hidden-sync-not-traversable" "${store_root}/*/emails/.internal-sync" "WARN" "no hidden sync roots discovered yet" "false")"
  fi
}

check_app_state_entry() {
  local entry_json="$1"
  local app component state_root severity detail
  local payload_roots payload_root missing_payloads=0

  app="$(jq -r '.app' <<<"$entry_json")"
  component="$(jq -r '.component' <<<"$entry_json")"
  state_root="$(jq -r '.stateRoot' <<<"$entry_json")"

  if [[ ! -e "$state_root" ]]; then
    severity="CRITICAL"
    detail="state root missing"
    emit_text "❌ app-state missing: ${state_root} (${app}/${component})"
  else
    severity="OK"
    detail="state root present"
    emit_text "✅ app-state: ${state_root} (${app}/${component})"
  fi

  while IFS= read -r payload_root; do
    [[ -n "$payload_root" ]] || continue
    if [[ ! -e "$payload_root" ]]; then
      missing_payloads=1
      if [[ "$severity" != "CRITICAL" ]]; then
        severity="CRITICAL"
        detail="payload root missing"
      fi
      emit_text "❌ payload root missing: ${payload_root} (${app}/${component})"
    fi
  done < <(jq -r '.payloadRoots[]?' <<<"$entry_json")

  append_json "$app_state_file" "$(jq -nc \
    --arg app "$app" \
    --arg component "$component" \
    --arg stateRoot "$state_root" \
    --arg severity "$severity" \
    --arg detail "$detail" \
    '{
      app: $app,
      component: $component,
      stateRoot: $stateRoot,
      severity: $severity,
      detail: $detail
    }')"
  mark_failed_if_critical "$severity"
}

run_backup_checks() {
  local backup_json timer service selection_file mount_point timestamp_file repository_path max_age_seconds
  local service_result timer_active timer_enabled timestamp age_seconds selected_device mounted_source severity detail
  local selection_state="configured"
  local selected_real="" mounted_real="" target_present=false
  local selected_uuid="" mounted_uuid="" selected_partuuid="" mounted_partuuid=""
  local mount_info="" mount_target="" mounted_fstype=""

  backup_json="$(runtime_health_snapshot_query '.backup')"
  timer="$(jq -r '.timer' <<<"$backup_json")"
  service="$(jq -r '.service' <<<"$backup_json")"
  selection_file="$(jq -r '.selectionFile' <<<"$backup_json")"
  mount_point="$(jq -r '.mountPoint' <<<"$backup_json")"
  timestamp_file="$(jq -r '.timestampFile' <<<"$backup_json")"
  repository_path="$(jq -r '.repositoryPath' <<<"$backup_json")"
  max_age_seconds="$(jq -r '.maxAgeSeconds' <<<"$backup_json")"

  timer_active="$(systemctl is-active "$timer" 2>/dev/null || true)"
  timer_enabled="$(systemctl is-enabled "$timer" 2>/dev/null || true)"
  service_result="$(systemctl show -p Result --value "$service" 2>/dev/null || true)"
  severity="OK"
  detail="recent backup metadata present"

  if [[ "$timer_active" != "active" || "$timer_enabled" != "enabled" ]]; then
    severity="CRITICAL"
    detail="backup timer not active and enabled"
  fi

  selected_device=""
  if [[ ! -r "$selection_file" ]]; then
    selection_state="missing"
  else
    selected_device="$(tr -d '\n' <"$selection_file")"
    if [[ -z "$selected_device" ]]; then
      selection_state="empty"
    fi
  fi

  mount_info="$(findmnt -rn -o TARGET,SOURCE,FSTYPE --target "$mount_point" 2>/dev/null || true)"
  if [[ -n "$mount_info" ]]; then
    read -r mount_target mounted_source mounted_fstype <<<"$mount_info"
    if [[ "$mount_target" != "$mount_point" ]]; then
      mounted_source=""
      mounted_fstype=""
    fi
  else
    mounted_source=""
    mounted_fstype=""
  fi
  if [[ -n "$mounted_source" || ( -n "$selected_device" && -e "$selected_device" ) ]]; then
    target_present=true
  fi

  if [[ -n "$selected_device" && -n "$mounted_source" ]]; then
    selected_real="$(readlink -f "$selected_device" 2>/dev/null || true)"
    mounted_real="$(readlink -f "$mounted_source" 2>/dev/null || printf '%s' "$mounted_source")"
    if [[ -n "$selected_real" && "$mounted_real" != "$selected_real" ]]; then
      selected_uuid="$(blkid -s UUID -o value "$selected_device" 2>/dev/null || true)"
      mounted_uuid="$(blkid -s UUID -o value "$mounted_source" 2>/dev/null || true)"
      selected_partuuid="$(blkid -s PARTUUID -o value "$selected_device" 2>/dev/null || true)"
      mounted_partuuid="$(blkid -s PARTUUID -o value "$mounted_source" 2>/dev/null || true)"
      if ! {
        [[ -n "$selected_uuid" && "$selected_uuid" == "$mounted_uuid" ]] ||
        [[ -n "$selected_partuuid" && "$selected_partuuid" == "$mounted_partuuid" ]]
      }; then
        severity="CRITICAL"
        detail="mounted backup target does not match the selected device"
      fi
    fi
  fi

  timestamp=""
  age_seconds=""
  if [[ -r "$timestamp_file" ]]; then
    timestamp="$(tr -d '\n' <"$timestamp_file")"
  fi

  if [[ -n "$timestamp" ]]; then
    timestamp_epoch="$(date --date="$timestamp" +%s 2>/dev/null || true)"
    now_epoch="$(date +%s)"
    if [[ -n "$timestamp_epoch" ]]; then
      age_seconds="$((now_epoch - timestamp_epoch))"
      if (( age_seconds > max_age_seconds )); then
        if [[ "$target_present" == true ]]; then
          severity="CRITICAL"
          detail="backup metadata is stale while the target is present"
        elif [[ "$severity" != "CRITICAL" ]]; then
          severity="WARN"
          detail="backup metadata is stale, but the removable target is absent"
        fi
      fi
    fi
  else
    if [[ "$target_present" == true ]]; then
      severity="CRITICAL"
      detail="backup metadata timestamp is missing while the target is present"
    elif [[ "$severity" != "CRITICAL" ]]; then
      severity="WARN"
      detail="backup metadata timestamp is missing; a removable target may not have been attached yet"
    fi
  fi

  if [[ -n "$service_result" && "$service_result" != "success" && "$severity" != "CRITICAL" ]]; then
    severity="WARN"
    detail="last backup service result was ${service_result}"
  fi

  if [[ "$output_format" == "text" ]]; then
    if [[ "$severity" == "OK" ]]; then
      emit_text "✅ backup timer active: ${timer}"
      if [[ -n "$timestamp" ]]; then
        emit_text "✅ recent backup metadata timestamp: ${timestamp}"
      fi
    elif [[ "$severity" == "WARN" ]]; then
      emit_text "⚠️  backup state: ${detail}"
    else
      emit_text "❌ backup state: ${detail}"
    fi
  fi

  printf '%s\n' "$(backup_result_json \
    "$service" \
    "$timer" \
    "$service_result" \
    "$timer_active" \
    "$timer_enabled" \
    "$selection_state" \
    "$selected_device" \
    "$mounted_source" \
    "$timestamp" \
    "$age_seconds" \
    "$severity" \
    "$detail" \
    "$target_present")" >"$backup_file"
  mark_failed_if_critical "$severity"

  if (( deep_checks != 0 )); then
    if [[ "$target_present" == true && ! -d "$repository_path" ]]; then
      emit_text "❌ backup repository missing: ${repository_path}"
      append_json "$deep_file" "$(deep_result_json "backup-repository" "repository" "$repository_path" "CRITICAL" "backup repository path missing while target present")"
      failed=1
    fi
  fi
}

emit_access_matrix() {
  local matrix_json canary_json canary_name app_names

  emit_text
  emit_text "== Access Matrix =="

  matrix_json="$(runtime_health_snapshot_query '.accessChecks.canaries')"
  while IFS= read -r canary_json; do
    canary_name="$(jq -r '.accountId' <<<"$canary_json")"
    app_names="$(jq -r '(.expectedApps | map(.name) | join(", ")) // ""' <<<"$canary_json")"
    if [[ -n "$app_names" ]]; then
      emit_text "✅ access matrix ${canary_name}: ${app_names}"
    else
      emit_text "⚠️  access matrix ${canary_name}: no expected app access"
    fi
  done < <(jq -c '.[]' <<<"$matrix_json")
}

run_local_access_checks() {
  local app_json

  emit_text
  emit_text "== Local Access Edges =="

  while IFS= read -r app_json; do
    check_local_access_unauth "$app_json"
  done < <(runtime_health_snapshot_query '.accessChecks.apps[] | select(.localUnauthCheck != null)')
}

run_deep_access_checks() {
  local bootstrap_state_file helper_path helper_json_file helper_results helper_status helper_stderr_file
  local playwright_module
  local access_result
  local bootstrap_failure_summary

  bootstrap_state_file="$(runtime_health_snapshot_query '.accessChecks.bootstrapStateFile' | jq -r '.')"
  helper_path="$(runtime_health_snapshot_query '.accessChecks.browserHelper' | jq -r '.')"

  if [[ ! -f "$bootstrap_state_file" ]]; then
    emit_text "❌ access canary bootstrap state missing: ${bootstrap_state_file}"
    append_json "$access_authed_file" "$(access_result_json "authed" "" "" "CRITICAL" "missing bootstrap state; run sudo ./scripts/bootstrap-access-canaries.sh" "" "")"
    failed=1
    return 0
  fi

  bootstrap_failure_summary="$(
    jq -r '
      ([.resetResults[]?, .warmupResults[]?]
       | map(select(.severity != "OK"))
       | if length == 0 then empty else map((.accountId // .canary // "unknown") + ": " + (.detail // .severity)) | join("; ") end)
    ' "$bootstrap_state_file" 2>/dev/null || true
  )"
  if [[ -n "$bootstrap_failure_summary" ]]; then
    emit_text "❌ access canary bootstrap state contains failures: ${bootstrap_failure_summary}"
    append_json "$access_authed_file" "$(access_result_json "authed" "" "" "CRITICAL" "bootstrap state contains failures: ${bootstrap_failure_summary}" "" "")"
    failed=1
    return 0
  fi

  helper_json_file="${RUNTIME_ACCESS_BROWSER_CHECK_JSON_FILE:-}"
  if [[ -n "$helper_json_file" ]]; then
    helper_results="$(cat "$helper_json_file")"
  else
    if [[ ! -f "$repo_root/$helper_path" ]]; then
      emit_text "❌ access browser helper missing: ${repo_root}/${helper_path}"
      append_json "$access_authed_file" "$(access_result_json "authed" "" "" "CRITICAL" "missing access browser helper ${helper_path}" "" "")"
      failed=1
      return 0
    fi

    playwright_module="$(nix eval --raw nixpkgs#playwright-driver.outPath)/index.mjs"
    helper_stderr_file="$(mktemp "${tmpdir}/access-browser-stderr.XXXXXX")"
    set +e
    helper_results="$(
      env \
        PLAYWRIGHT_NODE_MODULE="$playwright_module" \
        RUNTIME_HEALTH_SNAPSHOT="$RUNTIME_HEALTH_SNAPSHOT" \
        RUNTIME_ACCESS_BOOTSTRAP_STATE_FILE="$bootstrap_state_file" \
        nix shell nixpkgs#nodejs nixpkgs#playwright-driver nixpkgs#chromium -c \
        bash -c '
          set -euo pipefail
          export RUNTIME_ACCESS_BROWSER_EXECUTABLE="$(command -v chromium)"
          node "$1" verify
        ' bash "$repo_root/$helper_path" 2>"$helper_stderr_file"
    )"
    helper_status=$?
    set -e

    if (( helper_status != 0 )); then
      helper_results="$(cat "$helper_stderr_file"; printf '%s\n' "$helper_results")"
      emit_text "❌ access browser helper failed"
      append_json "$access_authed_file" "$(access_result_json "authed" "" "" "CRITICAL" "${helper_results//$'\n'/ }" "" "")"
      failed=1
      return 0
    fi
  fi

  while IFS= read -r access_result; do
    [[ -n "$access_result" ]] || continue
    append_json "$access_authed_file" "$access_result"
    if [[ "$(jq -r '.severity' <<<"$access_result")" == "OK" ]]; then
      emit_text "✅ access $(jq -r '.canary // "check"' <<<"$access_result") -> $(jq -r '.app // "runtime"' <<<"$access_result"): $(jq -r '.detail' <<<"$access_result")"
    else
      emit_text "❌ access $(jq -r '.canary // "check"' <<<"$access_result") -> $(jq -r '.app // "runtime"' <<<"$access_result"): $(jq -r '.detail' <<<"$access_result")"
      failed=1
    fi
  done < <(jq -c '.[]' <<<"$helper_results")

}

check_immich_smart_search_runtime() {
  local immich_json immich_enabled ml_url ping_result pg_json psql_binary db_name coverage_threshold
  local smart_sql query_result active_assets smart_rows clip_index_present coverage_percent detail

  immich_json="$(runtime_health_snapshot_query '.immich // {"enabled":false}')"
  immich_enabled="$(jq -r '.enabled // false' <<<"$immich_json")"
  [[ "$immich_enabled" == "true" ]] || return 0

  ml_url="$(jq -r '.machineLearningUrl // ""' <<<"$immich_json")"
  if [[ -z "$ml_url" ]]; then
    emit_text "❌ immich machine-learning URL missing from runtime snapshot"
    append_json "$deep_file" "$(deep_result_json "immich" "machine-learning" "" "CRITICAL" "machine-learning URL missing from runtime snapshot")"
    failed=1
  else
    ping_result="$(curl -fsS --max-time 5 "${ml_url%/}/ping" 2>&1 || true)"
    if [[ "$ping_result" == "pong" ]]; then
      emit_text "✅ immich machine-learning ping: ${ml_url%/}/ping"
      append_json "$deep_file" "$(deep_result_json "immich" "machine-learning" "${ml_url%/}/ping" "OK" "ping returned pong")"
    else
      emit_text "❌ immich machine-learning ping failed: ${ml_url%/}/ping"
      append_json "$deep_file" "$(deep_result_json "immich" "machine-learning" "${ml_url%/}/ping" "CRITICAL" "${ping_result//$'\n'/ }")"
      failed=1
    fi
  fi

  pg_json="$(runtime_health_snapshot_query '.databases.postgresql')"
  psql_binary="$(jq -r '.psqlBinary // ""' <<<"$pg_json")"
  db_name="$(jq -r '.databaseName // ""' <<<"$immich_json")"
  coverage_threshold="$(jq -r '.smartSearchCoverageWarnPercent // 95' <<<"$immich_json")"

  if [[ -z "$psql_binary" || -z "$db_name" ]]; then
    emit_text "❌ immich smart-search database check unavailable"
    append_json "$deep_file" "$(deep_result_json "immich" "smart-search-query" "$db_name" "CRITICAL" "psql binary or database name missing from runtime snapshot")"
    failed=1
    return 0
  fi

  smart_sql='
with counts as (
  select
    count(*) filter (where asset."deletedAt" is null and asset.visibility = '"'"'timeline'"'"') as active_assets,
    count(smart_search."assetId") filter (where asset."deletedAt" is null and asset.visibility = '"'"'timeline'"'"') as smart_rows
  from asset
  left join smart_search on asset.id = smart_search."assetId"
),
index_state as (
  select exists (
    select 1
    from pg_class c
    join pg_index i on i.indexrelid = c.oid
    join pg_class t on t.oid = i.indrelid
    where c.relname = '"'"'clip_index'"'"'
      and t.relname = '"'"'smart_search'"'"'
  ) as clip_index_present
)
select active_assets, smart_rows, clip_index_present
from counts
cross join index_state;
'

  if ! query_result="$(run_as_user postgres "$psql_binary" -X -A -F $'\t' -t -d "$db_name" -c "$smart_sql" 2>&1)"; then
    emit_text "❌ immich smart-search database query failed"
    append_json "$deep_file" "$(deep_result_json "immich" "smart-search-query" "$db_name" "CRITICAL" "${query_result//$'\n'/ }")"
    failed=1
    return 0
  fi

  query_result="${query_result//$'\r'/}"
  query_result="$(head -n 1 <<<"$query_result")"
  IFS=$'\t' read -r active_assets smart_rows clip_index_present <<<"$query_result"

  if ! [[ "$active_assets" =~ ^[0-9]+$ && "$smart_rows" =~ ^[0-9]+$ ]]; then
    emit_text "❌ immich smart-search database query returned unexpected output"
    append_json "$deep_file" "$(deep_result_json "immich" "smart-search-query" "$db_name" "CRITICAL" "unexpected query output: ${query_result//$'\n'/ }")"
    failed=1
    return 0
  fi

  if (( active_assets == 0 )); then
    emit_text "⚠️  immich smart-search coverage: no active timeline assets"
    append_json "$deep_file" "$(deep_result_json "immich" "smart-search-coverage" "$db_name" "WARN" "no active timeline assets found")"
  else
    coverage_percent=$(( smart_rows * 100 / active_assets ))
    detail="${smart_rows}/${active_assets} active timeline assets have smart_search rows (${coverage_percent}%)"
    if (( smart_rows * 100 < active_assets * coverage_threshold )); then
      emit_text "⚠️  immich smart-search coverage low: ${detail}"
      append_json "$deep_file" "$(deep_result_json "immich" "smart-search-coverage" "$db_name" "WARN" "$detail")"
    else
      emit_text "✅ immich smart-search coverage: ${detail}"
      append_json "$deep_file" "$(deep_result_json "immich" "smart-search-coverage" "$db_name" "OK" "$detail")"
    fi
  fi

  if [[ "$clip_index_present" == "t" || "$clip_index_present" == "true" ]]; then
    emit_text "✅ immich smart-search clip_index present"
    append_json "$deep_file" "$(deep_result_json "immich" "clip-index" "$db_name" "OK" "clip_index exists on smart_search")"
  else
    emit_text "❌ immich smart-search clip_index missing"
    append_json "$deep_file" "$(deep_result_json "immich" "clip-index" "$db_name" "CRITICAL" "clip_index missing on smart_search")"
    failed=1
  fi
}

run_deep_checks() {
  local sqlite_binary sqlite_entry db_name db_path quick_check
  local pg_json pg_enabled pg_binary pg_data_dir pg_dump_file metadata_file

  emit_text
  emit_text "== Deep Checks =="

  run_deep_access_checks

  sqlite_binary="$(runtime_health_snapshot_query '.databases.sqliteBinary' | jq -r '.')"
  while IFS= read -r sqlite_entry; do
    db_name="$(jq -r '.name' <<<"$sqlite_entry")"
    db_path="$(jq -r '.path' <<<"$sqlite_entry")"
    if [[ ! -f "$db_path" ]]; then
      emit_text "❌ sqlite database missing: ${db_path}"
      append_json "$deep_file" "$(deep_result_json "sqlite" "$db_name" "$db_path" "CRITICAL" "database file missing")"
      failed=1
      continue
    fi
    quick_check="$("$sqlite_binary" "$db_path" 'PRAGMA quick_check;' 2>&1 || true)"
    if [[ "$quick_check" == "ok" ]]; then
      emit_text "✅ sqlite quick_check: ${db_name}"
      append_json "$deep_file" "$(deep_result_json "sqlite" "$db_name" "$db_path" "OK" "quick_check ok")"
    else
      emit_text "❌ sqlite quick_check failed: ${db_name}"
      append_json "$deep_file" "$(deep_result_json "sqlite" "$db_name" "$db_path" "CRITICAL" "${quick_check//$'\n'/ }")"
      failed=1
    fi
  done < <(runtime_health_snapshot_query '.databases.sqlite[]?')

  pg_json="$(runtime_health_snapshot_query '.databases.postgresql')"
  pg_enabled="$(jq -r '.enabled' <<<"$pg_json")"
  if [[ "$pg_enabled" == "true" ]]; then
    pg_binary="$(jq -r '.pgIsReadyBinary' <<<"$pg_json")"
    pg_data_dir="$(jq -r '.dataDir' <<<"$pg_json")"
    pg_dump_file="$(runtime_health_snapshot_query '.backup.postgresqlDumpFile' | jq -r '.')"

    if [[ -n "$pg_binary" ]] && run_as_user postgres "$pg_binary" -q -d postgres >/dev/null 2>&1; then
      emit_text "✅ postgresql connectivity: ${pg_data_dir}"
      append_json "$deep_file" "$(deep_result_json "postgresql" "connectivity" "$pg_data_dir" "OK" "pg_isready passed")"
    else
      emit_text "❌ postgresql connectivity failed: ${pg_data_dir}"
      append_json "$deep_file" "$(deep_result_json "postgresql" "connectivity" "$pg_data_dir" "CRITICAL" "pg_isready failed")"
      failed=1
    fi

    if [[ -f "$pg_dump_file" ]]; then
      emit_text "✅ postgresql dump artifact: ${pg_dump_file}"
      append_json "$deep_file" "$(deep_result_json "postgresql" "dump" "$pg_dump_file" "OK" "logical dump artifact present")"
    else
      emit_text "❌ postgresql dump artifact missing: ${pg_dump_file}"
      append_json "$deep_file" "$(deep_result_json "postgresql" "dump" "$pg_dump_file" "CRITICAL" "logical dump artifact missing")"
      failed=1
    fi
  fi

  check_immich_smart_search_runtime

  while IFS= read -r metadata_file; do
    if [[ -f "$metadata_file" ]]; then
      emit_text "✅ backup metadata artifact: ${metadata_file}"
      append_json "$deep_file" "$(deep_result_json "backup-metadata" "$metadata_file" "$metadata_file" "OK" "artifact present")"
    else
      emit_text "❌ backup metadata artifact missing: ${metadata_file}"
      append_json "$deep_file" "$(deep_result_json "backup-metadata" "$metadata_file" "$metadata_file" "CRITICAL" "artifact missing")"
      failed=1
    fi
  done < <(runtime_health_snapshot_query '[.backup.timestampFile, .backup.appStateFile, .backup.criticalPathsFile, .backup.zpoolStatusFile, .backup.zpoolListFile, .backup.zfsListFile][]' | jq -r '.')
}

emit_text "Host: $(runtime_health_snapshot_query '.host.hostname' | jq -r '.')"
emit_text
emit_text "== Units =="
while IFS= read -r unit; do
  check_unit "$unit"
done < <(runtime_health_snapshot_query '.services.requiredUnits[]' | jq -r '.')

emit_text
emit_text "== HTTPS endpoints =="
while IFS= read -r check_json; do
  check_http "edge" \
    "$(jq -r '.name' <<<"$check_json")" \
    "$(jq -r '.url' <<<"$check_json")" \
    "$(jq -c '.expected' <<<"$check_json")"
done < <(runtime_health_snapshot_query '.services.edgeHttp[]')

emit_text
emit_text "== Internal HTTP =="
while IFS= read -r check_json; do
  check_http "internal" \
    "$(jq -r '.name' <<<"$check_json")" \
    "$(jq -r '.url' <<<"$check_json")" \
    "$(jq -c '.expected' <<<"$check_json")"
done < <(runtime_health_snapshot_query '.services.internalHttp[]')

emit_access_matrix
run_local_access_checks

emit_text
emit_text "== DNS via Unbound =="
emit_text "ℹ️ Validating the server-local Unbound view; LAN client DNS policy may still be mediated by the router."
while IFS= read -r host_name; do
  check_dns_resolves "$host_name"
done < <(runtime_health_snapshot_query '.services.dns.resolve[]' | jq -r '.')

if [[ "$(runtime_health_snapshot_query '.host.dnsMode' | jq -r '.')" == "split-horizon" ]]; then
  while IFS= read -r dns_json; do
    check_private_dns "$(jq -r '.host' <<<"$dns_json")" "$(jq -r '.expected' <<<"$dns_json")"
  done < <(runtime_health_snapshot_query '.services.dns.splitHorizon.private[]')
  while IFS= read -r ptr_json; do
    check_ptr_dns "$(jq -r '.ip' <<<"$ptr_json")" "$(jq -r '.expected' <<<"$ptr_json")"
  done < <(runtime_health_snapshot_query '.services.dns.splitHorizon.ptr[]')
else
  while IFS= read -r dns_json; do
    check_public_dns "$(jq -r '.host' <<<"$dns_json")" "$(jq -r '.forbidden' <<<"$dns_json")"
  done < <(runtime_health_snapshot_query '.services.dns.netbirdOnly.public[]')
fi
while IFS= read -r dns_json; do
  check_private_dns "$(jq -r '.host' <<<"$dns_json")" "$(jq -r '.expected' <<<"$dns_json")"
done < <(runtime_health_snapshot_query '.services.dns.private[]')

emit_text
emit_text "== Storage =="
if [[ "$(runtime_health_snapshot_query '.persistence.enabled' | jq -r '.')" == "true" ]]; then
  mount_json="$(runtime_health_check_mount_json "persist" "/persist" "btrfs")"
  append_json "$mounts_file" "$mount_json"
  if [[ "$(jq -r '.severity' <<<"$mount_json")" == "OK" ]]; then
    emit_text "✅ mount /persist (btrfs)"
  else
    emit_text "❌ mount /persist ($(jq -r '.actualFstype // "missing"' <<<"$mount_json")) expected btrfs"
    failed=1
  fi
fi

data_pool_mount="$(runtime_health_snapshot_query '.storage.dataPool.mountPoint' | jq -r '.')"
mount_json="$(runtime_health_check_mount_json "dataPool" "$data_pool_mount" "zfs")"
append_json "$mounts_file" "$mount_json"
if [[ "$(jq -r '.severity' <<<"$mount_json")" == "OK" ]]; then
  emit_text "✅ mount ${data_pool_mount} (zfs)"
else
  emit_text "❌ mount ${data_pool_mount} ($(jq -r '.actualFstype // "missing"' <<<"$mount_json")) expected zfs"
  failed=1
fi

while IFS= read -r dataset_mount; do
  mount_json="$(runtime_health_check_mount_json "$(basename "$dataset_mount")" "$dataset_mount" "zfs")"
  append_json "$mounts_file" "$mount_json"
  if [[ "$(jq -r '.severity' <<<"$mount_json")" == "OK" ]]; then
    emit_text "✅ mount ${dataset_mount} (zfs)"
  else
    emit_text "❌ mount ${dataset_mount} ($(jq -r '.actualFstype // "missing"' <<<"$mount_json")) expected zfs"
    failed=1
  fi
done < <(runtime_health_snapshot_query '.storage.dataPool.datasetMounts[]' | jq -r '.')

emit_text
emit_text "== App State =="
while IFS= read -r entry_json; do
  check_app_state_entry "$entry_json"
done < <(runtime_health_snapshot_query '.appState.entries[]')

emit_text
emit_text "== Required Paths =="
while IFS= read -r path_json; do
  check_path_exists "required path" "$(jq -r '.label' <<<"$path_json")" "$(jq -r '.path' <<<"$path_json")"
done < <(runtime_health_snapshot_query '.appState.requiredPaths[]')

emit_text
emit_text "== Copyparty Upload Permissions =="
check_copyparty_upload_permissions
check_mail_archive_filebrowser_permissions

emit_text
emit_text "== Backups =="
run_backup_checks

emit_text
emit_text "== SMART =="
bash "$repo_root/scripts/discover-storage-devices.sh" --format json >"$discovery_json_file"
jq '.allSmartDisks' "$discovery_json_file" >"$disk_specs_file"
smart_disk_count="$(jq 'length' "$disk_specs_file")"
if [[ "$smart_disk_count" == "0" ]]; then
  emit_text "⚠️  no storage devices configured for SMART checks"
  smart_json='{"disks":[]}'
else
  smart_json="$(bash "$repo_root/scripts/helpers/storage-health-common.sh" --mode warn --format json --disk-spec-file "$disk_specs_file")"
  printf '%s\n' "$smart_json" | jq -r '
    .disks[] |
    if .severity == "OK" then
      "✅ smart " + .label + ": " + .detail
    elif .severity == "WARN" then
      "⚠️  smart " + .label + ": " + .detail
    else
      "❌ smart " + .label + ": " + .detail
    end
  ' | while IFS= read -r line; do
    emit_text "$line"
  done
  if jq -e '.disks[] | select(.severity == "CRITICAL")' <<<"$smart_json" >/dev/null 2>&1; then
    failed=1
  fi
fi

emit_text
emit_text "== ZFS =="
data_pool_name="$(runtime_health_snapshot_query '.storage.dataPool.name' | jq -r '.')"
zpool_health="$(zpool list -H -o health "$data_pool_name" 2>/dev/null || true)"
zpool_status_severity="OK"
zpool_status_summary="ONLINE"
if [[ "$zpool_health" == "ONLINE" ]]; then
  emit_text "✅ zpool health ONLINE: ${data_pool_name}"
elif [[ "$zpool_health" == "DEGRADED" ]]; then
  zpool_status_summary="DEGRADED"
  if [[ "$profile" == "deploy" ]]; then
    zpool_status_severity="CRITICAL"
    emit_text "❌ zpool health DEGRADED: ${data_pool_name}"
    emit_text "❌ deploy profile requires ONLINE zpool health."
    failed=1
  else
    zpool_status_severity="WARN"
    emit_text "⚠️  zpool health DEGRADED: ${data_pool_name}"
    emit_text "⚠️  continuing because the mirrored pool is still available, but redundancy is lost."
  fi
elif [[ -n "$zpool_health" ]]; then
  zpool_status_summary="$zpool_health"
  zpool_status_severity="CRITICAL"
  emit_text "❌ zpool health unexpected for ${data_pool_name}: ${zpool_health}"
  failed=1
else
  zpool_status_summary="pool missing"
  zpool_status_severity="CRITICAL"
  emit_text "❌ zpool health unexpected for ${data_pool_name}: pool missing"
  failed=1
fi

zfs_dataset_output="$(zfs list -H -r -o name,mountpoint "$data_pool_name" 2>/dev/null || true)"
zfs_dataset_summary="expected datasets listed"
zfs_dataset_severity="OK"
while IFS= read -r dataset_mount; do
  if ! grep -Fq "$dataset_mount" <<<"$zfs_dataset_output"; then
    zfs_dataset_summary="missing expected dataset mounts"
    zfs_dataset_severity="CRITICAL"
    emit_text "❌ zfs list is missing expected dataset mountpoint: ${dataset_mount}"
    failed=1
  fi
done < <(runtime_health_snapshot_query '.storage.dataPool.datasetMounts[]' | jq -r '.')
if [[ "$zfs_dataset_severity" == "OK" ]]; then
  emit_text "✅ zfs list returned datasets for ${data_pool_name}"
fi

if [[ "$zpool_status_summary" == "ONLINE" && "$zfs_dataset_severity" == "OK" ]]; then
  zfs_runtime_state="operational"
elif [[ "$zpool_status_summary" == "DEGRADED" && "$zfs_dataset_severity" == "OK" ]]; then
  zfs_runtime_state="degraded"
else
  zfs_runtime_state="failed"
fi
zfs_json="$(runtime_health_zfs_status_json "$zpool_status_summary" "$zpool_status_severity" "$zfs_dataset_summary" "$zfs_dataset_severity" "$zpool_status_summary" "$zfs_runtime_state")"

if [[ "$(runtime_health_snapshot_query '.persistence.enabled' | jq -r '.')" == "true" ]]; then
  emit_text
  emit_text "== Persistence =="
  while IFS= read -r path; do
    check_persist_binding "$path"
  done < <(runtime_health_snapshot_query '.persistence.directories[]' | jq -r '.')
  while IFS= read -r path; do
    check_persist_binding "$path"
  done < <(runtime_health_snapshot_query '.persistence.files[]' | jq -r '.')
fi

if (( deep_checks != 0 )); then
  run_deep_checks
fi

units_json="$(jq -s '.' "$units_file")"
edge_http_json="$(jq -s '.' "$edge_http_file")"
internal_http_json="$(jq -s '.' "$internal_http_file")"
dns_json="$(jq -s '.' "$dns_file")"
mounts_json="$(jq -s '.' "$mounts_file")"
app_state_json="$(jq -s '.' "$app_state_file")"
paths_json="$(jq -s '.' "$paths_file")"
persistence_json="$(jq -s '.' "$persistence_file")"
deep_json="$(jq -s '.' "$deep_file")"
access_matrix_json="$(runtime_health_snapshot_query '.accessChecks.canaries' | jq '.')"
access_local_json="$(jq -s '.' "$access_local_file")"
access_authed_json="$(jq -s '.' "$access_authed_file")"
backup_json="$(cat "$backup_file")"

overall_severity="$(
  jq -nr \
    --argjson units "$units_json" \
    --argjson edge "$edge_http_json" \
    --argjson internal "$internal_http_json" \
    --argjson dns "$dns_json" \
    --argjson mounts "$mounts_json" \
    --argjson appState "$app_state_json" \
    --argjson paths "$paths_json" \
    --argjson persistence "$persistence_json" \
    --argjson backup "$backup_json" \
    --argjson smart "$smart_json" \
    --argjson zfs "$zfs_json" \
    --argjson deep "$deep_json" \
    --argjson accessLocal "$access_local_json" \
    --argjson accessAuthed "$access_authed_json" \
    '
      def escalate($current; $next):
        if $current == "CRITICAL" or $next == "CRITICAL" then "CRITICAL"
        elif $current == "WARN" or $next == "WARN" then "WARN"
        else "OK"
        end;

      reduce (
        ($units | map(.severity))
        + ($edge | map(.severity))
        + ($internal | map(.severity))
        + ($dns | map(.severity))
        + ($mounts | map(.severity))
        + ($appState | map(.severity))
        + ($paths | map(.severity))
        + ($persistence | map(.severity))
        + ($smart.disks | map(.severity))
        + ($deep | map(.severity))
        + ($accessLocal | map(.severity))
        + ($accessAuthed | map(.severity))
        + [$backup.severity, $zfs.statusSeverity, $zfs.datasetSeverity]
      )[] as $severity ("OK"; escalate(.; $severity))
    '
)"

if [[ "$output_format" == "json" ]]; then
  jq -n \
    --arg timestamp "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --arg profile "$profile" \
    --arg overallSeverity "$overall_severity" \
    --arg hostname "$(runtime_health_snapshot_query '.host.hostname' | jq -r '.')" \
    --argjson units "$units_json" \
    --argjson edge "$edge_http_json" \
    --argjson internal "$internal_http_json" \
    --argjson dns "$dns_json" \
    --argjson mounts "$mounts_json" \
    --argjson appState "$app_state_json" \
    --argjson requiredPaths "$paths_json" \
    --argjson persistence "$persistence_json" \
    --argjson backup "$backup_json" \
    --argjson smart "$smart_json" \
    --argjson zfs "$zfs_json" \
    --argjson deep "$deep_json" \
    --argjson accessMatrix "$access_matrix_json" \
    --argjson accessLocal "$access_local_json" \
    --argjson accessAuthed "$access_authed_json" \
    '{
      timestamp: $timestamp,
      profile: $profile,
      hostname: $hostname,
      overallSeverity: $overallSeverity,
      units: $units,
      edgeHttp: $edge,
      internalHttp: $internal,
      dns: $dns,
      mounts: $mounts,
      appState: $appState,
      requiredPaths: $requiredPaths,
      persistence: $persistence,
      backup: $backup,
      smart: $smart.disks,
      zfs: $zfs,
      deepChecks: $deep,
      accessChecks: {
        matrix: $accessMatrix,
        localUnauth: $accessLocal,
        authed: $accessAuthed
      }
    }'
fi

if (( failed != 0 )); then
  if [[ "$output_format" == "text" ]]; then
    emit_text
    emit_text "❌ Runtime readiness checks failed."
  fi
  exit 1
fi

if [[ "$output_format" == "text" ]]; then
  emit_text
  emit_text "✅ Runtime readiness checks passed."
fi
