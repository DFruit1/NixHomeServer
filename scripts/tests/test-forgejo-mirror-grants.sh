#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2016
# Offline regression for the declarative Forgejo mirror collaborator grants.
#
# The production reconciler runs unchanged with real bash, jq and coreutils.
# Only its curl and forgejo CLI boundaries are replaced by a finite fake that
# records every call and refuses anything it does not expect. Mirror
# configuration, the API token and the resulting grant state are synthetic.
#
# Version-bound API contract (Forgejo 16.0.3, the version this checkout's
# nixpkgs input pins, read from the v16.0.3 source tag):
#   PUT /api/v1/repos/{owner}/{repo}/collaborators/{collaborator}
#     body {"permission":"read"}
#     -> 204 No Content when the grant is applied, including a repeated grant
#        for an existing collaborator (modules/repository/collaborator.go
#        returns early for an existing collaboration and
#        models/repo/collaboration.go then applies the requested mode).
#     403/404/422/500 are documented or emitted failures and never mean a
#     completed grant. No asynchronous 202 or other 2xx is a success.

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools bash grep mktemp ln

reconciler=modules/forgejo/reconcile-mirrors.sh
api='http://forgejo.invalid'
mirror_user='mirror-owner'
token_sentinel='synthetic-fixture-token-sentinel-not-a-credential'
converged='All declarative Forgejo mirrors are reconciled.'

test_root="$(mktemp -d)"
trap 'rm -rf "$test_root"' EXIT
bin_dir="$test_root/bin"
mkdir -p "$bin_dir"

cat >"$bin_dir/boundary" <<'FAKE'
#!/usr/bin/env bash
# Finite curl/forgejo boundary. Records safe call metadata only: no header
# values, no token contents and no response bodies are ever stored or printed.
set -uo pipefail

case_dir="${FJ_CASE:?FJ_CASE is required}"
api="${FJ_API:?FJ_API is required}"
mirror_user="${FJ_MIRROR_USER:?FJ_MIRROR_USER is required}"
program="${0##*/}"
events="$case_dir/events.log"

record() { printf '%s\n' "$*" >>"$events"; }
refuse() {
  record "unexpected-call ${program}"
  printf 'fake boundary: unexpected call\n' >&2
  exit 97
}

if [[ "$program" == forgejo ]]; then
  [[ "$*" == 'admin user list' ]] || refuse
  record 'user-list'
  printf 'ID Name Email IsActive IsAdmin\n'
  printf '1 %s %s@example.invalid true true\n' "$mirror_user" "$mirror_user"
  exit 0
fi

out_file=''
write_fmt=''
method='GET'
auth_headers=0
data=''
url=''

while (( $# > 0 )); do
  case "$1" in
    -s | -fsS)
      shift
      ;;
    -o | -w | --max-time | -X | -H | -d)
      (( $# >= 2 )) || refuse
      case "$1" in
        -o) out_file="$2" ;;
        -w) write_fmt="$2" ;;
        --max-time) ;;
        -X) method="$2" ;;
        -d) data="$2" ;;
        -H)
          case "$2" in
            'Authorization: token '*) auth_headers=$((auth_headers + 1)) ;;
            'Content-Type: application/json') ;;
            *) refuse ;;
          esac
          ;;
      esac
      shift 2
      ;;
    -*) refuse ;;
    *)
      [[ -z "$url" ]] || refuse
      url="$1"
      shift
      ;;
  esac
done

[[ -n "$url" ]] || refuse

status_only() {
  # The reconciler may ask for the status code with -w or discard it entirely;
  # both are valid curl shapes against this boundary.
  [[ "$out_file" == '/dev/null' ]] || refuse
  case "$write_fmt" in
    '' | '%{http_code}') ;;
    *) refuse ;;
  esac
}

emit_status() {
  [[ "$write_fmt" == '%{http_code}' ]] || return 0
  printf '%s' "$1"
}

if [[ "$method" == 'GET' && "$url" == "$api/api/v1/version" ]]; then
  [[ -z "$write_fmt" ]] || refuse
  record 'readiness'
  printf '{"version":"synthetic"}'
  exit 0
fi

if [[ "$method" == 'GET' && "$url" == "$api/api/v1/user" ]]; then
  status_only
  record 'token-check status=200'
  emit_status 200
  exit 0
fi

repos_prefix="$api/api/v1/repos/"

if [[ "$method" == 'GET' && "$url" == "$repos_prefix"* ]]; then
  rest="${url#"$repos_prefix"}"
  [[ "$rest" == */* && "$rest" != */*/* ]] || refuse
  [[ "${rest%%/*}" == "$mirror_user" ]] || refuse
  status_only
  record "repository-check $rest"
  emit_status 200
  exit 0
fi

if [[ "$method" == 'PUT' && "$url" == "$repos_prefix"* ]]; then
  rest="${url#"$repos_prefix"}"
  [[ "$rest" == */collaborators/* ]] || refuse
  repo="${rest%%/collaborators/*}"
  user="${rest##*/collaborators/}"
  [[ "$repo" == */* && -n "$user" && "$user" != */* ]] || refuse
  status_only
  (( auth_headers == 1 )) || refuse
  [[ "$data" == '{"permission":"read"}' ]] || refuse
  matched=false
  rule_status=''
  rule_exit=''
  while IFS='|' read -r rule_repo rule_user candidate_status candidate_exit; do
    [[ "$rule_repo" == "$repo" && "$rule_user" == "$user" ]] || continue
    matched=true
    rule_status="$candidate_status"
    rule_exit="$candidate_exit"
    break
  done <"$case_dir/rules.tsv"
  [[ "$matched" == true ]] || refuse
  record "collaborator-put $repo/$user permission=read status=${rule_status} curl-exit=${rule_exit}"
  if [[ "$rule_status" == '204' ]]; then
    # Only a completed success response applies the synthetic read grant.
    printf '%s|%s|read\n' "$repo" "$user" >>"$case_dir/access.tsv"
    emit_status 204
  elif [[ "$rule_status" != 'none' ]]; then
    # An HTTP error still exits 0 because the request does not use curl -f.
    emit_status "$rule_status"
  fi
  exit "$rule_exit"
fi

refuse
FAKE
make_test_executable "$bin_dir/boundary"
ln -s boundary "$bin_dir/curl"
ln -s boundary "$bin_dir/forgejo"

case_counter=0
case_dir=''

failure() {
  printf '❌ %s\n' "$*" >&2
  exit 1
}

new_case() {
  ((case_counter++)) || true
  case_dir="$test_root/case-$case_counter"
  mkdir -p "$case_dir"
  : >"$case_dir/events.log"
  : >"$case_dir/access.tsv"
  printf '%s\n' "$token_sentinel" >"$case_dir/token"
  chmod 0600 "$case_dir/token"
}

write_mirrors() {
  local dir="$1"
  shift
  printf '%s\n' "$1" >"$dir/mirrors.json"
}

write_rules() {
  local dir="$1"
  shift
  printf '%s\n' "$@" >"$dir/rules.tsv"
}

clear_events() {
  : >"$1/events.log"
}

run_reconciler() {
  local dir="$1"
  local tag="$2"
  local collaborators="$3"
  PATH="$bin_dir:$PATH" \
    FORGEJO_API_URL="$api" \
    FORGEJO_MIRROR_USER="$mirror_user" \
    FORGEJO_MIRROR_EMAIL="$mirror_user@example.invalid" \
    FORGEJO_MIRROR_TOKEN_FILE="$dir/token" \
    FORGEJO_MIRRORS_FILE="$dir/mirrors.json" \
    FORGEJO_MIRROR_COLLABORATORS="$collaborators" \
    FORGEJO_MIRRORS_HAS_GITHUB_TOKEN=0 \
    FORGEJO_BIN="$bin_dir/forgejo" \
    FJ_CASE="$dir" \
    FJ_API="$api" \
    FJ_MIRROR_USER="$mirror_user" \
    bash "$reconciler" >"$dir/output.$tag.log" 2>&1
}

reconcile_rc=0

run_case() {
  local dir="$1"
  local tag="$2"
  local collaborators="$3"
  set +e
  run_reconciler "$dir" "$tag" "$collaborators"
  reconcile_rc=$?
  set -e
}

expect_rc() {
  local want="$1"
  local label="$2"
  [[ "$reconcile_rc" == "$want" ]] ||
    failure "$label: expected reconciler exit ${want}, got ${reconcile_rc}"
}

expect_nonzero() {
  local label="$1"
  ((reconcile_rc != 0)) ||
    failure "$label: reconciler reported success (exit 0) for a failed grant"
}

expect_output() {
  local file="$1"
  local text="$2"
  local label="$3"
  grep -Fq -- "$text" "$file" || failure "$label: output is missing '${text}'"
}

expect_no_output() {
  local file="$1"
  local text="$2"
  local label="$3"
  if grep -Fq -- "$text" "$file"; then
    failure "$label: output must not contain '${text}'"
  fi
}

expect_access() {
  local dir="$1"
  local line="$2"
  local label="$3"
  grep -Fxq -- "$line" "$dir/access.tsv" ||
    failure "$label: synthetic read grant is missing '${line}'"
}

expect_no_access() {
  local dir="$1"
  local pattern="$2"
  local label="$3"
  if grep -Fq -- "$pattern" "$dir/access.tsv"; then
    failure "$label: synthetic read grant must be absent for '${pattern}'"
  fi
}

expect_events() {
  local dir="$1"
  local expected="$2"
  local label="$3"
  printf '%s\n' "$expected" >"$dir/expected-events.txt"
  if ! diff -u "$dir/expected-events.txt" "$dir/events.log" >"$dir/events.diff"; then
    failure "$label: boundary operations differ from the expected sequence:
$(cat "$dir/events.diff")"
  fi
}

expect_no_unexpected_calls() {
  local dir="$1"
  local label="$2"
  if grep -Fq 'unexpected-call' "$dir/events.log"; then
    failure "$label: the reconciler made an unexpected boundary call"
  fi
}

expect_safe_output() {
  local file="$1"
  local label="$2"
  expect_no_output "$file" "$token_sentinel" "$label"
  expect_no_output "$file" 'Authorization' "$label"
  expect_no_output "$file" 'synthetic-fixture-token' "$label"
}

single_mirror='[{"url":"https://upstream.invalid/pub/repo-one.git","owner":"mirror-owner"}]'
single_mirror_events='readiness
user-list
token-check status=200
repository-check mirror-owner/repo-one'

# A completed 204 grant succeeds and converges; repeating it stays green
# because Forgejo answers 204 for an already-existing collaborator.
new_case
write_mirrors "$case_dir" "$single_mirror"
write_rules "$case_dir" 'mirror-owner/repo-one|reader-one|204|0'
run_case "$case_dir" first 'reader-one'
expect_rc 0 'grant success'
expect_output "$case_dir/output.first.log" "$converged" 'grant success'
expect_access "$case_dir" 'mirror-owner/repo-one|reader-one|read' 'grant success'
clear_events "$case_dir"
run_case "$case_dir" second 'reader-one'
expect_rc 0 'repeated grant success'
expect_output "$case_dir/output.second.log" "$converged" 'repeated grant success'
expect_events "$case_dir" "$single_mirror_events
collaborator-put mirror-owner/repo-one/reader-one permission=read status=204 curl-exit=0" 'repeated grant success'
expect_access "$case_dir" 'mirror-owner/repo-one|reader-one|read' 'repeated grant success'
success_case="$case_dir"

# HTTP error responses arrive with curl exit 0; each one must fail the run.
for http_status in 403 500 404; do
  new_case
  write_mirrors "$case_dir" "$single_mirror"
  write_rules "$case_dir" "mirror-owner/repo-one|reader-one|${http_status}|0"
  run_case "$case_dir" run 'reader-one'
  label="HTTP ${http_status} grant"
  expect_nonzero "$label"
  expect_output "$case_dir/output.run.log" 'Failed to grant read access to mirror-owner/repo-one for reader-one' "$label"
  expect_output "$case_dir/output.run.log" "HTTP ${http_status}" "$label"
  expect_output "$case_dir/output.run.log" 'mirror(s) could not be reconciled' "$label"
  expect_no_output "$case_dir/output.run.log" "$converged" "$label"
  expect_no_access "$case_dir" 'reader-one' "$label"
  expect_safe_output "$case_dir/output.run.log" "$label"
  expect_events "$case_dir" "$single_mirror_events
collaborator-put mirror-owner/repo-one/reader-one permission=read status=${http_status} curl-exit=0" "$label"
  expect_no_unexpected_calls "$case_dir" "$label"
done

# A transport failure (no HTTP status at all) must also fail the run.
new_case
write_mirrors "$case_dir" "$single_mirror"
write_rules "$case_dir" 'mirror-owner/repo-one|reader-one|none|7'
run_case "$case_dir" run 'reader-one'
label='transport failure grant'
expect_nonzero "$label"
expect_output "$case_dir/output.run.log" 'Failed to grant read access to mirror-owner/repo-one for reader-one' "$label"
expect_output "$case_dir/output.run.log" 'curl exit 7' "$label"
expect_output "$case_dir/output.run.log" 'mirror(s) could not be reconciled' "$label"
expect_no_output "$case_dir/output.run.log" "$converged" "$label"
expect_no_access "$case_dir" 'reader-one' "$label"
expect_safe_output "$case_dir/output.run.log" "$label"
expect_no_unexpected_calls "$case_dir" "$label"

# A failed first collaborator does not stop the remaining configured users.
new_case
write_mirrors "$case_dir" "$single_mirror"
write_rules "$case_dir" \
  'mirror-owner/repo-one|blocked-reader|403|0' \
  'mirror-owner/repo-one|allowed-reader|204|0'
run_case "$case_dir" run 'blocked-reader,allowed-reader'
label='mixed collaborators'
expect_nonzero "$label"
expect_output "$case_dir/output.run.log" 'for blocked-reader' "$label"
expect_no_output "$case_dir/output.run.log" "$converged" "$label"
expect_events "$case_dir" "$single_mirror_events
collaborator-put mirror-owner/repo-one/blocked-reader permission=read status=403 curl-exit=0
collaborator-put mirror-owner/repo-one/allowed-reader permission=read status=204 curl-exit=0" "$label"
expect_access "$case_dir" 'mirror-owner/repo-one|allowed-reader|read' "$label"
expect_no_access "$case_dir" 'blocked-reader' "$label"
expect_safe_output "$case_dir/output.run.log" "$label"
expect_no_unexpected_calls "$case_dir" "$label"

# A failed first mirror does not stop later configured mirrors.
new_case
write_mirrors "$case_dir" '[{"url":"https://upstream.invalid/pub/repo-one.git","owner":"mirror-owner"},{"url":"https://upstream.invalid/pub/repo-two.git","owner":"mirror-owner"}]'
write_rules "$case_dir" \
  'mirror-owner/repo-one|reader-one|403|0' \
  'mirror-owner/repo-one|reader-two|204|0' \
  'mirror-owner/repo-two|reader-one|204|0' \
  'mirror-owner/repo-two|reader-two|204|0'
run_case "$case_dir" run 'reader-one,reader-two'
label='mixed mirrors'
expect_nonzero "$label"
expect_no_output "$case_dir/output.run.log" "$converged" "$label"
expect_output "$case_dir/output.run.log" '1 mirror(s) could not be reconciled' "$label"
expect_events "$case_dir" "readiness
user-list
token-check status=200
repository-check mirror-owner/repo-one
collaborator-put mirror-owner/repo-one/reader-one permission=read status=403 curl-exit=0
collaborator-put mirror-owner/repo-one/reader-two permission=read status=204 curl-exit=0
repository-check mirror-owner/repo-two
collaborator-put mirror-owner/repo-two/reader-one permission=read status=204 curl-exit=0
collaborator-put mirror-owner/repo-two/reader-two permission=read status=204 curl-exit=0" "$label"
expect_access "$case_dir" 'mirror-owner/repo-one|reader-two|read' "$label"
expect_access "$case_dir" 'mirror-owner/repo-two|reader-one|read' "$label"
expect_access "$case_dir" 'mirror-owner/repo-two|reader-two|read' "$label"
expect_no_access "$case_dir" 'mirror-owner/repo-one|reader-one' "$label"
expect_safe_output "$case_dir/output.run.log" "$label"
expect_no_unexpected_calls "$case_dir" "$label"

# No configured collaborators issues no grant request and still converges.
new_case
write_mirrors "$case_dir" "$single_mirror"
write_rules "$case_dir" 'mirror-owner/repo-one|reader-one|204|0'
run_case "$case_dir" run ''
label='no collaborators'
expect_rc 0 "$label"
expect_output "$case_dir/output.run.log" "$converged" "$label"
expect_events "$case_dir" "$single_mirror_events" "$label"
expect_no_access "$case_dir" 'reader' "$label"
expect_no_unexpected_calls "$case_dir" "$label"

# The mirror owner is never granted collaborator access on its own repository.
new_case
write_mirrors "$case_dir" "$single_mirror"
write_rules "$case_dir" 'mirror-owner/repo-one|mirror-owner|204|0'
run_case "$case_dir" run 'mirror-owner'
label='owner skip'
expect_rc 0 "$label"
expect_output "$case_dir/output.run.log" "$converged" "$label"
expect_events "$case_dir" "$single_mirror_events" "$label"
expect_no_access "$case_dir" 'mirror-owner' "$label"
expect_no_unexpected_calls "$case_dir" "$label"

# Omitting owner still resolves to the dedicated mirror account, so an entry
# naming that account is skipped instead of requesting a grant for it.
new_case
write_mirrors "$case_dir" '[{"url":"https://upstream.invalid/pub/repo-one.git"}]'
write_rules "$case_dir" 'mirror-owner/repo-one|mirror-owner|204|0'
run_case "$case_dir" run 'mirror-owner'
label='default owner skip'
expect_rc 0 "$label"
expect_output "$case_dir/output.run.log" "$converged" "$label"
expect_events "$case_dir" "$single_mirror_events" "$label"
expect_no_unexpected_calls "$case_dir" "$label"

# A failed grant is not sticky: a later run against the same mirror converges.
new_case
write_mirrors "$case_dir" "$single_mirror"
write_rules "$case_dir" 'mirror-owner/repo-one|reader-one|403|0'
run_case "$case_dir" first 'reader-one'
label='retry after failure'
expect_nonzero "$label"
expect_no_output "$case_dir/output.first.log" "$converged" "$label"
clear_events "$case_dir"
write_rules "$case_dir" 'mirror-owner/repo-one|reader-one|204|0'
run_case "$case_dir" second 'reader-one'
expect_rc 0 "$label"
expect_output "$case_dir/output.second.log" "$converged" "$label"
expect_events "$case_dir" "$single_mirror_events
collaborator-put mirror-owner/repo-one/reader-one permission=read status=204 curl-exit=0" "$label"
expect_access "$case_dir" 'mirror-owner/repo-one|reader-one|read' "$label"
expect_no_unexpected_calls "$case_dir" "$label"

# The passing control must not have leaked the synthetic token either.
expect_safe_output "$success_case/output.first.log" 'grant success'

echo '✅ Forgejo mirror grants fail visibly and continue remaining work.'
