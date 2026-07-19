#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"

ensure_tools awk jq rg sed

fileshare_module=modules/Core_Modules/storage/fileshare-user-roots.nix
jellyfin_module=modules/jellyfin/bootstrap.nix
kavita_module=modules/kavita/bootstrap.nix
immich_module=modules/immich/admin-reconcile.nix

assert_before() {
  local file="$1"
  local first="$2"
  local second="$3"
  local description="$4"
  local first_line second_line

  first_line="$(rg -n -F -- "$first" "$file" | head -n 1 | cut -d: -f1)"
  second_line="$(rg -n -F -- "$second" "$file" | tail -n 1 | cut -d: -f1)"
  if [[ -z "$first_line" || -z "$second_line" || "$first_line" -ge "$second_line" ]]; then
    echo "❌ $description"
    echo "   Expected '$first' before '$second' in $file."
    exit 1
  fi
}

for module in "$fileshare_module" "$jellyfin_module" "$kavita_module" "$immich_module"; do
  require_fixed "$module" 'Unable to read Kanidm group' \
    "identity group query failures in $module must be fatal"
  require_fixed "$module" 'Kanidm returned an invalid membership document' \
    "malformed identity group snapshots in $module must be fatal"
done

forbid_match "$jellyfin_module" "printf[[:space:]]+'\\[\\]" \
  "Jellyfin must not translate a failed group query into empty membership"
forbid_match "$kavita_module" "printf[[:space:]]+'\\[\\]" \
  "Kavita must not translate a failed group query into empty membership"
forbid_match "$immich_module" 'mapfile[^\n]*< <\(' \
  "Immich snapshot command failures must not be hidden by process substitution"
require_fixed "$immich_module" 'if ! email="$(snapshot_person_email "$username")"; then' \
  "Immich person lookup failures must be checked explicitly"
require_fixed "$immich_module" 'Unable to read current Immich admins; refusing to change admin privileges' \
  "Immich database snapshot failures must abort privilege reconciliation"

assert_before "$fileshare_module" \
  'if ! snapshot_group_members "$group_name"; then' \
  'apply_shared_root_acl' \
  "fileshare must snapshot every group before changing ACLs or mounts"
assert_before "$jellyfin_module" \
  'if ! jellyfin_members_json="$(snapshot_group_members_json jellyfin-users)"; then' \
  'INSERT INTO $api_keys_table' \
  "Jellyfin must snapshot identity before provisioning or mutating state"
assert_before "$kavita_module" \
  'if ! shared_members_json="$(snapshot_group_members_json "$shared_access_group")"; then' \
  'run_sqlite_write "update ServerSetting' \
  "Kavita must snapshot identity before its first database write"
assert_before "$immich_module" \
  'snapshot_group_members "immich-users" "$immich_members_file"' \
  'run_immich_admin grant-admin' \
  "Immich must stage group and person snapshots before admin changes"

test_dir="$(mktemp -d)"
trap 'rm -rf "$test_dir"' EXIT
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"

printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "KANIDM %s\n" "$*" >>"$MOCK_COMMAND_LOG"' \
  'case "${1:-} ${2:-}" in' \
  '  "group get") exit 42 ;;' \
  '  "person get") exit 43 ;;' \
  '  *) exit 0 ;;' \
  'esac' \
  >"$mock_bin/kanidm"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  'printf "MUTATION %s\n" "$*" >>"$MOCK_COMMAND_LOG"' \
  >"$mock_bin/mutation"
make_test_executable "$mock_bin/kanidm" "$mock_bin/mutation"

extract_function() {
  local file="$1"
  local function_name="$2"
  local indentation="$3"
  local output_file="$4"
  local start end

  printf -v start '%*s%s() {' "$indentation" '' "$function_name"
  printf -v end '%*s}' "$indentation" ''
  awk -v start="$start" -v end="$end" -v trim="$indentation" '
    $0 == start { copying = 1 }
    copying { print substr($0, trim + 1) }
    copying && $0 == end { exit }
  ' "$file" \
    | sed -E \
      -e 's#\$\{pkgs\.[^}]+\}/bin/kanidm#kanidm#g' \
      -e 's#\$\{pkgs\.[^}]+\}/bin/jq#jq#g' \
      -e 's#\$\{kanidmCliUrl\}#https://identity.invalid:8443#g' \
    >"$output_file"

  if ! rg -q -F -- "$function_name() {" "$output_file"; then
    echo "❌ Failed to extract $function_name from $file."
    exit 1
  fi
}

run_failure_case() {
  local label="$1"
  local functions_file="$2"
  local setup="$3"
  local invocation="$4"
  local mutation_command="$5"
  local harness="$test_dir/$label.sh"
  local command_log="$test_dir/$label.log"

  : >"$command_log"
  {
    printf '%s\n' '#!/usr/bin/env bash' 'set -euo pipefail'
    printf '%s\n' "$setup"
    sed -n '1,$p' "$functions_file"
    printf '%s\n' "$invocation" "$mutation_command"
  } >"$harness"
  chmod +x "$harness"

  if PATH="$mock_bin:$PATH" MOCK_COMMAND_LOG="$command_log" bash "$harness" >/dev/null 2>&1; then
    echo "❌ $label unexpectedly succeeded after the mocked identity query failure."
    exit 1
  fi
  if rg -q -F -- 'MUTATION ' "$command_log"; then
    echo "❌ $label reached a destructive operation after the mocked identity query failure."
    sed -n '1,$p' "$command_log"
    exit 1
  fi
}

fileshare_functions="$test_dir/fileshare-functions.sh"
jellyfin_functions="$test_dir/jellyfin-functions.sh"
kavita_functions="$test_dir/kavita-functions.sh"
immich_group_functions="$test_dir/immich-group-functions.sh"
immich_person_functions="$test_dir/immich-person-functions.sh"

extract_function "$fileshare_module" snapshot_group_members 4 "$fileshare_functions"
extract_function "$jellyfin_module" snapshot_group_members_json 8 "$jellyfin_functions"
extract_function "$kavita_module" snapshot_group_members_json 8 "$kavita_functions"
extract_function "$immich_module" snapshot_group_members 6 "$immich_group_functions"
extract_function "$immich_module" snapshot_person_email 6 "$immich_person_functions"

run_failure_case fileshare-group "$fileshare_functions" \
  'declare -A group_members_by_name=()' \
  'if ! snapshot_group_members files-shared-users; then exit 1; fi' \
  'mutation mount-or-user'
run_failure_case jellyfin-group "$jellyfin_functions" '' \
  'if ! members="$(snapshot_group_members_json jellyfin-users)"; then exit 1; fi' \
  'mutation delete-library-or-disable-user'
run_failure_case kavita-group "$kavita_functions" '' \
  'if ! members="$(snapshot_group_members_json files-shared-users)"; then exit 1; fi' \
  'mutation revoke-library-or-admin'
run_failure_case immich-group "$immich_group_functions" '' \
  'snapshot_group_members immich-users "$MOCK_COMMAND_LOG.snapshot"' \
  'mutation revoke-admin'
run_failure_case immich-person "$immich_person_functions" '' \
  'if ! email="$(snapshot_person_email alice)"; then exit 1; fi' \
  'mutation revoke-admin'

echo "✅ Identity reconciliation fails closed under mocked command errors."
