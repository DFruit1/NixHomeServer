set -euo pipefail

mode="${1:-daemon}"
if [[ $# -gt 0 ]]; then
  shift
fi

staging_root="${UPLOAD_STAGING_ROOT:?UPLOAD_STAGING_ROOT is required}"
users_root="${UPLOAD_USERS_ROOT:?UPLOAD_USERS_ROOT is required}"
quarantine_root="${UPLOAD_QUARANTINE_ROOT:?UPLOAD_QUARANTINE_ROOT is required}"
kiwix_root="${UPLOAD_KIWIX_LIBRARY_ROOT:?UPLOAD_KIWIX_LIBRARY_ROOT is required}"
state_db="${UPLOAD_PROCESSOR_STATE_DB:-/var/lib/upload-processor/state.sqlite}"
queue_dir="${UPLOAD_PROCESSOR_QUEUE_DIR:-/run/upload-processor/queue}"
lock_file="${UPLOAD_PROCESSOR_LOCK_FILE:-$(dirname "$state_db")/processor.lock}"
vt_secret="${UPLOAD_VIRUSTOTAL_API_KEY_FILE:-}"
settle_seconds="${UPLOAD_SCAN_SETTLE_SECONDS:-30}"
clamav_timeout="${UPLOAD_CLAMAV_TIMEOUT_SECONDS:-300}"
vt_timeout="${UPLOAD_VIRUSTOTAL_TIMEOUT_SECONDS:-20}"
vt_malicious_threshold="${UPLOAD_VIRUSTOTAL_MALICIOUS_THRESHOLD:-1}"
vt_suspicious_threshold="${UPLOAD_VIRUSTOTAL_SUSPICIOUS_THRESHOLD:-1}"
rescan_sleep_seconds="${UPLOAD_PROCESSOR_DAEMON_SLEEP_SECONDS:-15}"
admin_users=" ${UPLOAD_ZIM_PROMOTION_USERS:-} "
low_risk_exts=" ${UPLOAD_LOW_RISK_EXTENSIONS:-pdf docx xlsx pptx jpg jpeg png gif webp mp3 flac m4a opus wav mp4 mkv webm} "
high_risk_exts=" ${UPLOAD_HIGH_RISK_EXTENSIONS:-exe dll scr com msi bat cmd ps1 psm1 vbs js jse hta jar apk deb rpm appimage iso img dmg zip 7z rar tar gz bz2 xz doc docm dotm xls xlsm xltm xlsb xlam ppt pptm potm pps ppsm html svg rtf zim} "
quarantine_owner="${UPLOAD_QUARANTINE_OWNER:-upload-processor}"
quarantine_group="${UPLOAD_QUARANTINE_GROUP:-upload-review}"
final_owner="${UPLOAD_FINAL_OWNER:-root}"
final_group="${UPLOAD_FINAL_GROUP:-users}"
kiwix_owner="${UPLOAD_KIWIX_OWNER:-root}"
kiwix_group="${UPLOAD_KIWIX_GROUP:-kiwix}"

mkdir -p "$(dirname "$state_db")" "$queue_dir"
exec 9>"$lock_file"
if ! flock -w 30 9; then
  exit 0
fi

install_managed_dir() {
  local mode="$1" owner="$2" group="$3" path="$4"
  install -d "$path"
  chown "${owner}:${group}" "$path" >/dev/null 2>&1 || true
  chmod "$mode" "$path" >/dev/null 2>&1 || true
}

init_state() {
  sqlite3 -cmd ".timeout 30000" "$state_db" <<'SQL'
CREATE TABLE IF NOT EXISTS uploads (
  path TEXT PRIMARY KEY,
  uploader TEXT,
  size INTEGER,
  mtime INTEGER,
  sha256 TEXT,
  extension TEXT,
  state TEXT NOT NULL,
  last_error TEXT,
  retry_count INTEGER NOT NULL DEFAULT 0,
  last_scan_time INTEGER,
  destination_path TEXT,
  quarantine_path TEXT
);
SQL
}

record_state() {
  local path="$1" uploader="$2" size="$3" mtime="$4" sha="$5" ext="$6" state="$7" error="$8" destination="$9" quarantine="${10}"
  sql_quote() {
    local value="$1"
    printf "'%s'" "${value//\'/\'\'}"
  }
  sqlite3 -cmd ".timeout 30000" "$state_db" <<SQL
INSERT INTO uploads(path,uploader,size,mtime,sha256,extension,state,last_error,retry_count,last_scan_time,destination_path,quarantine_path)
VALUES($(sql_quote "$path"),$(sql_quote "$uploader"),$size,$mtime,$(sql_quote "$sha"),$(sql_quote "$ext"),$(sql_quote "$state"),$(sql_quote "$error"),CASE WHEN $(sql_quote "$state") = 'retry' THEN 1 ELSE 0 END,strftime('%s','now'),$(sql_quote "$destination"),$(sql_quote "$quarantine"))
ON CONFLICT(path) DO UPDATE SET
  uploader=excluded.uploader,
  size=excluded.size,
  mtime=excluded.mtime,
  sha256=excluded.sha256,
  extension=excluded.extension,
  state=excluded.state,
  last_error=excluded.last_error,
  retry_count=CASE WHEN excluded.state = 'retry' THEN uploads.retry_count + 1 ELSE uploads.retry_count END,
  last_scan_time=excluded.last_scan_time,
  destination_path=excluded.destination_path,
  quarantine_path=excluded.quarantine_path;
SQL
}

canonical_path() {
  realpath -m -- "$1"
}

is_under_root() {
  local path="$1" root="$2"
  [[ "$path" == "$root"/* ]]
}

is_internal_staging_path() {
  local rel="$1"
  [[ "$rel" == .hist/* || "$rel" == */.hist/* ]]
}

safe_component() {
  local value="$1"
  value="${value//[^A-Za-z0-9._-]/_}"
  value="${value#.}"
  [[ -n "$value" ]] || value="upload"
  printf '%s' "$value"
}

safe_relative_path() {
  local rel="$1" part safe=""
  [[ "$rel" != /* ]] || return 1
  IFS='/' read -r -a parts <<<"$rel"
  for part in "${parts[@]}"; do
    [[ -n "$part" && "$part" != "." && "$part" != ".." ]] || return 1
    if [[ -n "$safe" ]]; then
      safe+="/"
    fi
    safe+="$(safe_component "$part")"
  done
  [[ -n "$safe" ]] || return 1
  printf '%s' "$safe"
}

extension_for() {
  local base="${1##*/}"
  if [[ "$base" == *.* && "$base" != .* ]]; then
    printf '%s' "${base##*.}" | tr '[:upper:]' '[:lower:]'
  fi
}

is_low_risk() {
  [[ "$low_risk_exts" == *" $1 "* ]]
}

is_high_risk() {
  [[ "$high_risk_exts" == *" $1 "* ]] || ! is_low_risk "$1"
}

file_stable() {
  local file="$1" now mtime age
  now="$(date +%s)"
  mtime="$(stat -c %Y -- "$file")"
  age=$((now - mtime))
  (( age >= settle_seconds ))
}

sha256_for() {
  sha256sum -- "$1" | awk '{print $1}'
}

collision_safe_path() {
  local path="$1" dir base stem ext candidate n
  if [[ ! -e "$path" ]]; then
    printf '%s' "$path"
    return 0
  fi
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  if [[ "$base" == *.* && "$base" != .* ]]; then
    stem="${base%.*}"
    ext=".${base##*.}"
  else
    stem="$base"
    ext=""
  fi
  n=1
  while :; do
    candidate="${dir}/${stem} (${n})${ext}"
    if [[ ! -e "$candidate" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
    n=$((n + 1))
  done
}

write_metadata() {
  local meta_path="$1" uploader="$2" original="$3" virtual="$4" sha="$5" ext="$6" clamav="$7" vt="$8" reason="$9"
  jq -n \
    --arg uploader "$uploader" \
    --arg originalPath "$original" \
    --arg virtualPath "$virtual" \
    --arg sha256 "$sha" \
    --arg extension "$ext" \
    --arg clamavResult "$clamav" \
    --argjson virusTotalResult "$vt" \
    --arg reason "$reason" \
    --arg timestamp "$(date --iso-8601=seconds)" \
    '{
      uploader:$uploader,
      originalPath:$originalPath,
      originalVirtualPath:$virtualPath,
      sha256:(if $sha256 == "" then null else $sha256 end),
      extension:$extension,
      clamavResult:$clamavResult,
      virusTotalHashResult:$virusTotalResult,
      reason:$reason,
      timestamp:$timestamp
    }' >"$meta_path"
}

quarantine_file() {
  local file="$1" uploader="$2" virtual="$3" sha="$4" ext="$5" clamav="$6" vt="$7" reason="$8"
  local ts safe_name dest_dir dest
  ts="$(date -u +%Y%m%dT%H%M%SZ)"
  safe_name="$(safe_component "$(basename -- "$file")")"
  dest_dir="${quarantine_root}/${reason}/${uploader}"
  install_managed_dir 0750 "$quarantine_owner" "$quarantine_group" "$dest_dir"
  dest="$(collision_safe_path "${dest_dir}/${ts}-${safe_name}")"
  mv -- "$file" "$dest"
  chown "${quarantine_owner}:${quarantine_group}" "$dest" >/dev/null 2>&1 || true
  chmod 0640 "$dest" >/dev/null 2>&1 || true
  write_metadata "${dest}.json" "$uploader" "$file" "$virtual" "$sha" "$ext" "$clamav" "$vt" "$reason"
  chown "${quarantine_owner}:${quarantine_group}" "${dest}.json" >/dev/null 2>&1 || true
  chmod 0640 "${dest}.json" >/dev/null 2>&1 || true
  printf '%s' "$dest"
}

promote_file() {
  local file="$1" uploader="$2" rel="$3"
  local safe_rel dest_dir dest
  safe_rel="$(safe_relative_path "$rel")"
  dest="${users_root}/${uploader}/files/${safe_rel}"
  dest_dir="$(dirname -- "$dest")"
  install_managed_dir 2770 "$final_owner" "$final_group" "$dest_dir"
  chmod 2770 "$dest_dir" >/dev/null 2>&1 || true
  dest="$(collision_safe_path "$dest")"
  mv -- "$file" "$dest"
  chown "${final_owner}:${final_group}" "$dest" >/dev/null 2>&1 || true
  chmod 0660 "$dest" >/dev/null 2>&1 || true
  printf '%s' "$dest"
}

user_can_promote_zim() {
  local uploader="$1"
  [[ "$admin_users" == *" $uploader "* ]]
}

promote_zim() {
  local file="$1" uploader="$2"
  local tmp_library dest
  tmp_library="$(mktemp)"
  trap 'rm -f "$tmp_library"' RETURN
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><library version="20110515"></library>' >"$tmp_library"
  if ! kiwix-manage "$tmp_library" add "$file" >/dev/null 2>&1; then
    return 1
  fi
  install_managed_dir 0750 "$kiwix_owner" "$kiwix_group" "$kiwix_root"
  dest="$(collision_safe_path "${kiwix_root}/$(safe_component "$(basename -- "$file")")")"
  mv -- "$file" "$dest"
  chown "${kiwix_owner}:${kiwix_group}" "$dest" >/dev/null 2>&1 || true
  chmod 0660 "$dest" >/dev/null 2>&1 || true
  systemctl --no-block start kiwix-library-sync.service >/dev/null 2>&1 || true
  printf '%s' "$dest"
}

run_clamav() {
  local file="$1" output status
  set +e
  output="$(timeout "$clamav_timeout" clamdscan --fdpass --no-summary "$file" 2>&1)"
  status=$?
  set -e
  printf '%s\n%s' "$status" "$output"
}

classify_clamav_result() {
  local status="$1" output="$2"
  if [[ "$status" == "0" ]]; then
    printf 'clean'
  elif [[ "$status" == "124" || "$status" == "137" ]]; then
    printf 'retry'
  elif grep -Eiq 'connect|connection|socket|service|daemon|temporar|unavailable' <<<"$output"; then
    printf 'retry'
  elif grep -Eiq 'encrypted|password|Heuristics\.Encrypted' <<<"$output"; then
    printf 'encrypted'
  elif [[ "$status" == "1" ]]; then
    printf 'infected'
  else
    printf 'scan-error'
  fi
}

vt_lookup() {
  local sha="$1" api_key response status body curl_status
  if [[ -z "$vt_secret" || ! -s "$vt_secret" ]]; then
    jq -cn '{state:"retry", error:"missing VirusTotal API key"}'
    return 0
  fi
  api_key="$(tr -d '\r\n' <"$vt_secret")"
  set +e
  response="$(curl --silent --show-error --max-time "$vt_timeout" \
    -H "x-apikey: ${api_key}" \
    --write-out $'\n%{http_code}' \
    "https://www.virustotal.com/api/v3/files/${sha}" 2>&1)"
  curl_status=$?
  set -e
  if [[ "$curl_status" != "0" ]]; then
    jq -cn --arg error "$response" '{state:"retry", error:$error}'
    return 0
  fi
  status="${response##*$'\n'}"
  body="${response%$'\n'*}"
  if [[ "$status" == "404" ]]; then
    jq -cn '{state:"unknown", status:404}'
  elif [[ "$status" == "200" ]]; then
    jq -cn --argjson body "$body" \
      --argjson malicious "$vt_malicious_threshold" \
      --argjson suspicious "$vt_suspicious_threshold" '
      ($body.data.attributes.last_analysis_stats // {}) as $stats
      | {
          state: (if (($stats.malicious // 0) >= $malicious or ($stats.suspicious // 0) >= $suspicious) then "flagged" else "clean" end),
          status: 200,
          stats: $stats
        }'
  elif [[ "$status" =~ ^5 || "$status" == "429" ]]; then
    jq -cn --arg status "$status" --arg body "$body" '{state:"retry", status:($status|tonumber), body:$body}'
  else
    jq -cn --arg status "$status" --arg body "$body" '{state:"retry", status:($status|tonumber), body:$body}'
  fi
}

process_file() {
  local input_path="$1" hook_uploader="${2:-}" virtual="${3:-}"
  local file rel username rel_after_user ext size mtime clamav_raw clamav_status clamav_output clamav_class sha vt_json vt_state destination quarantine
  file="$(canonical_path "$input_path")"
  staging_root="$(canonical_path "$staging_root")"
  [[ -f "$file" ]] || return 0
  if ! is_under_root "$file" "$staging_root"; then
    return 0
  fi
  rel="${file#"$staging_root"/}"
  if is_internal_staging_path "$rel"; then
    return 0
  fi
  username="${hook_uploader:-${rel%%/*}}"
  username="$(safe_component "$username")"
  rel_after_user="${rel#*/}"
  [[ "$rel_after_user" != "$rel" ]] || rel_after_user="$(basename -- "$file")"
  if ! safe_relative_path "$rel_after_user" >/dev/null; then
    quarantine="$(quarantine_file "$file" "$username" "$virtual" "" "" "not-scanned" "null" "unsafe-path")"
    record_state "$file" "$username" 0 0 "" "" "quarantined" "unsafe path" "" "$quarantine"
    return 0
  fi
  if ! file_stable "$file"; then
    size="$(stat -c %s -- "$file")"
    mtime="$(stat -c %Y -- "$file")"
    ext="$(extension_for "$file")"
    record_state "$file" "$username" "$size" "$mtime" "" "$ext" "pending" "waiting for file to settle" "" ""
    return 0
  fi

  ext="$(extension_for "$file")"
  size="$(stat -c %s -- "$file")"
  mtime="$(stat -c %Y -- "$file")"
  clamav_raw="$(run_clamav "$file")"
  clamav_status="$(head -n1 <<<"$clamav_raw")"
  clamav_output="$(tail -n +2 <<<"$clamav_raw")"
  clamav_class="$(classify_clamav_result "$clamav_status" "$clamav_output")"

  case "$clamav_class" in
    clean) ;;
    retry)
      record_state "$file" "$username" "$size" "$mtime" "" "$ext" "retry" "$clamav_output" "" ""
      return 0
      ;;
    infected|encrypted|scan-error)
      quarantine="$(quarantine_file "$file" "$username" "$virtual" "" "$ext" "$clamav_output" "null" "clamav-${clamav_class}")"
      record_state "$file" "$username" "$size" "$mtime" "" "$ext" "quarantined" "$clamav_class" "" "$quarantine"
      return 0
      ;;
  esac

  if [[ "$ext" == "zim" ]]; then
    sha="$(sha256_for "$file")"
    vt_json="$(vt_lookup "$sha")"
    vt_state="$(jq -r '.state' <<<"$vt_json")"
    case "$vt_state" in
      retry)
        record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "retry" "$(jq -c . <<<"$vt_json")" "" ""
        return 0
        ;;
      unknown)
        quarantine="$(quarantine_file "$file" "$username" "$virtual" "$sha" "$ext" "$clamav_output" "$vt_json" "vt-unknown-manual-review")"
        record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "quarantined" "vt unknown" "" "$quarantine"
        return 0
        ;;
      flagged)
        quarantine="$(quarantine_file "$file" "$username" "$virtual" "$sha" "$ext" "$clamav_output" "$vt_json" "virustotal-flagged")"
        record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "quarantined" "virustotal flagged" "" "$quarantine"
        return 0
        ;;
    esac
    if ! user_can_promote_zim "$username"; then
      quarantine="$(quarantine_file "$file" "$username" "$virtual" "$sha" "$ext" "$clamav_output" "$vt_json" "zim-admin-required")"
      record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "quarantined" "zim admin required" "" "$quarantine"
      return 0
    fi
    if destination="$(promote_zim "$file" "$username")"; then
      record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "promoted-kiwix" "" "$destination" ""
    else
      quarantine="$(quarantine_file "$file" "$username" "$virtual" "$sha" "$ext" "$clamav_output" "$vt_json" "zim-invalid")"
      record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "quarantined" "zim invalid" "" "$quarantine"
    fi
    return 0
  fi

  if is_low_risk "$ext"; then
    destination="$(promote_file "$file" "$username" "$rel_after_user")"
    record_state "$file" "$username" "$size" "$mtime" "" "$ext" "promoted" "" "$destination" ""
    return 0
  fi

  sha="$(sha256_for "$file")"
  vt_json="$(vt_lookup "$sha")"
  vt_state="$(jq -r '.state' <<<"$vt_json")"
  case "$vt_state" in
    clean)
      destination="$(promote_file "$file" "$username" "$rel_after_user")"
      record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "promoted" "" "$destination" ""
      ;;
    flagged)
      quarantine="$(quarantine_file "$file" "$username" "$virtual" "$sha" "$ext" "$clamav_output" "$vt_json" "virustotal-flagged")"
      record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "quarantined" "virustotal flagged" "" "$quarantine"
      ;;
    unknown)
      quarantine="$(quarantine_file "$file" "$username" "$virtual" "$sha" "$ext" "$clamav_output" "$vt_json" "vt-unknown-manual-review")"
      record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "quarantined" "vt unknown" "" "$quarantine"
      ;;
    retry|*)
      record_state "$file" "$username" "$size" "$mtime" "$sha" "$ext" "retry" "$(jq -c . <<<"$vt_json")" "" ""
      ;;
  esac
}

process_queue() {
  local job path uploader virtual
  shopt -s nullglob
  for job in "$queue_dir"/*.json; do
    path="$(jq -r '.path // .ap // .vp // empty' "$job" 2>/dev/null || true)"
    uploader="$(jq -r '.user // .un // .uploader // empty' "$job" 2>/dev/null || true)"
    virtual="$(jq -r '.virtualPath // .vp // .vpath // empty' "$job" 2>/dev/null || true)"
    if [[ -n "$path" ]]; then
      process_file "$path" "$uploader" "$virtual"
    fi
    rm -f -- "$job"
  done
}

rescan_staging() {
  while IFS= read -r -d '' file; do
    process_file "$file" "" ""
  done < <(find "$staging_root" -path '*/.hist/*' -prune -o -type f -print0)
}

init_state

case "$mode" in
  once|rescan)
    process_queue
    rescan_staging
    ;;
  file)
    process_file "$@"
    ;;
  daemon)
    while :; do
      process_queue
      rescan_staging
      sleep "$rescan_sleep_seconds"
    done
    ;;
  *)
    echo "usage: upload-processor.sh [daemon|once|rescan|file <path> [uploader] [virtual-path]]" >&2
    exit 64
    ;;
esac
