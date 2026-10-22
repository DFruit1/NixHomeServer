#!/usr/bin/env bash
# Lean-tier test: SFTP key helper authorization hardening.
#
# Verifies that the install and revoke helpers:
#   1. Validate the target username shape before any Kanidm lookup.
#   2. Acquire the per-user flock before performing the Kanidm re-check.
#   3. Perform the Kanidm re-check (membership for install, existence for
#      revoke) under the same lock, before any key-file mutation.
#   4. Fail closed on Kanidm lookup failure and on malformed or schema-invalid
#      group responses (no key written / no key removed).
#   5. Do not accept an actor argument (only the target username).
#   6. Are reachable via the existing NOPASSWD sudoers rules (no broadening).
#
# The authorization matrix is exercised behaviorally: multiple-group answers
# (per-group match, per-group failure, malformed/schema-invalid responses that
# must not be masked by a later match), targeted existing-key preservation on
# every denial, forged actor claims versus target eligibility, malformed
# username/key/fingerprint input, exact success receipts, and competing
# same-user mutations serialized by the per-user lock. Offboarding (revoke for a
# person removed from every SFTP group) and realm-qualified members stay
# covered.
#
# Behavioral tests execute the rendered helpers with path-substituted mocks
# for kanidm, the agenix secret, the SFTP authorized-keys directory, and the
# standard utilities. No real Kanidm instance is contacted; no agenix
# plaintext is read.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"

ensure_tools jq rg sed bash ssh-keygen cmp flock

# ---------------------------------------------------------------------------
# Render the helpers via nix derivation show (same pattern as
# test-offline-media-reliability.sh).
# ---------------------------------------------------------------------------

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

behavior_json="$(flake_eval_json '
  vars = import ./vars.nix { inherit lib; };
  pkgs = f.inputs.nixpkgs.legacyPackages.${vars.hostPlatform};
  packages = import ./flake/packages.nix { inherit lib pkgs; crane = f.inputs.crane; };
  system = import ./flake/system.nix {
    inputs = f.inputs;
    inherit lib vars pkgs;
    system = vars.hostPlatform;
    appPackages = packages.appPackages;
  };
  cfg = system.nixosConfigurations.${vars.hostname}.config;
  in {
    installCommandDrv = builtins.toString cfg.systemd.services.homepage.environment.HOMEPAGE_SFTP_KEY_INSTALL_COMMAND;
    revokeCommandDrv = builtins.toString cfg.systemd.services.homepage.environment.HOMEPAGE_SFTP_KEY_REVOKE_COMMAND;
    sudoRules = let
      rules = builtins.filter (r: builtins.elem "homepage" r.users) cfg.security.sudo.extraRules;
    in builtins.concatMap (r: map (c: { command = c.command; options = c.options; }) r.commands) rules;
  }
')"

install_drv="$(jq -er '.installCommandDrv' <<<"$behavior_json")"
revoke_drv="$(jq -er '.revokeCommandDrv' <<<"$behavior_json")"
sudo_rules="$(jq -cer '.sudoRules' <<<"$behavior_json")"
install_text="$(derivation_text "$install_drv")"
revoke_text="$(derivation_text "$revoke_drv")"

# ---------------------------------------------------------------------------
# Static assertions on the rendered helper text.
# ---------------------------------------------------------------------------

test_dir="$(mktemp -d)"
cleanup() { rm -rf "$test_dir"; }
trap cleanup EXIT

install_file="$test_dir/install-sftp-key"
revoke_file="$test_dir/revoke-sftp-key"
printf '%s\n' "$install_text" >"$install_file"
printf '%s\n' "$revoke_text" >"$revoke_file"

# 1. Username validation before Kanidm lookup.
for helper in "$install_file" "$revoke_file"; do
  username_check_line="$(rg -n -m 1 -F "grep -Eq '^[a-z][a-z0-9._-]{0,63}\$'" "$helper" | cut -d: -f1)"
  kanidm_login_line="$(rg -n -m 1 -F "kanidm login" "$helper" | cut -d: -f1)"
  if [[ ! "$username_check_line" =~ ^[0-9]+$ || ! "$kanidm_login_line" =~ ^[0-9]+$ ]] \
    || (( username_check_line >= kanidm_login_line )); then
    echo "❌ $(basename "$helper"): username validation must precede Kanidm login." >&2
    exit 1
  fi
done
printf 'ok - username validation precedes Kanidm login in both helpers\n'

# 2. flock before Kanidm re-check.
for helper in "$install_file" "$revoke_file"; do
  flock_line="$(rg -n -m 1 -F 'flock -x 9' "$helper" | cut -d: -f1)"
  kanidm_login_line="$(rg -n -m 1 -F 'kanidm login' "$helper" | cut -d: -f1)"
  if [[ ! "$flock_line" =~ ^[0-9]+$ || ! "$kanidm_login_line" =~ ^[0-9]+$ ]] \
    || (( flock_line >= kanidm_login_line )); then
    echo "❌ $(basename "$helper"): Kanidm re-check must occur under the per-user flock." >&2
    exit 1
  fi
done
printf 'ok - per-user flock precedes the Kanidm re-check in both helpers\n'

# 3. Kanidm re-check before key-file mutation.
#    Install: before mv "$tmp" "$target"
#    Revoke:  before mv "$tmp" "$target"
install_kanidm_line="$(rg -n -m 1 -F 'kanidm login' "$install_file" | cut -d: -f1)"
install_mutation_line="$(rg -n -m 1 -F 'mv "$tmp" "$target"' "$install_file" | cut -d: -f1)"
if [[ ! "$install_kanidm_line" =~ ^[0-9]+$ || ! "$install_mutation_line" =~ ^[0-9]+$ ]] \
  || (( install_kanidm_line >= install_mutation_line )); then
  echo "❌ install helper: Kanidm re-check must precede the key-file write." >&2
  exit 1
fi

revoke_kanidm_line="$(rg -n -m 1 -F 'kanidm login' "$revoke_file" | cut -d: -f1)"
revoke_mutation_line="$(rg -n -m 1 -F 'mv "$tmp" "$target"' "$revoke_file" | cut -d: -f1)"
if [[ ! "$revoke_kanidm_line" =~ ^[0-9]+$ || ! "$revoke_mutation_line" =~ ^[0-9]+$ ]] \
  || (( revoke_kanidm_line >= revoke_mutation_line )); then
  echo "❌ revoke helper: Kanidm re-check must precede the key-file write." >&2
  exit 1
fi
printf 'ok - Kanidm re-check precedes the key-file write in both helpers\n'

# 4. Fail-closed messages present.
require_fixed "$install_file" "unable to verify current SFTP membership; no key was installed" \
  "install helper must fail closed on Kanidm lookup failure"
require_fixed "$install_file" "current Kanidm membership does not permit SFTP access; no key was installed" \
  "install helper must reject non-eligible targets"
require_fixed "$revoke_file" "unable to verify current Kanidm state; no key was revoked" \
  "revoke helper must fail closed on Kanidm lookup failure"
require_fixed "$revoke_file" "target user is not a current Kanidm person; no key was revoked" \
  "revoke helper must reject nonexistent targets"
printf 'ok - fail-closed and eligibility refusal messages present in both helpers\n'

# 4b. The malformed-response closure is a distinct refusal from the
#     authoritative nonmatch: the membership answer must be read through the
#     jq exit status, so the refusal branch is not an `if` fall-through.
install_refusal_count="$(grep -cF "unable to verify current SFTP membership; no key was installed" "$install_file")"
if (( install_refusal_count < 2 )); then
  echo "❌ install helper: malformed and failed group lookups must both refuse with the fail-closed message." >&2
  exit 1
fi
if rg -q -F 'elif ((.attrs.member // []) | type) != "array" then' "$install_file" \
  && ! rg -q -F 'membership_status' "$install_file"; then
  echo "❌ install helper: jq must not be used as a bare `if` condition (errors would read as nonmatches)." >&2
  exit 1
fi
printf 'ok - malformed group responses refuse through the jq exit status\n'

# 5. No actor argument. The helpers accept exactly one (install) or two
#    (revoke: username + fingerprint) positional args, neither of which is
#    an actor/identity argument.
if rg -q --multiline 'actor|acting_user|caller_username' <<<"$install_text"; then
  echo "❌ install helper must not accept an actor/identity argument." >&2
  exit 1
fi
if rg -q --multiline 'actor|acting_user|caller_username' <<<"$revoke_text"; then
  echo "❌ revoke helper must not accept an actor/identity argument." >&2
  exit 1
fi
require_fixed "$install_file" 'username="${1:-}"' \
  "install helper must read the target username as its only positional parameter"
if rg -q -F '${2' "$install_file"; then
  echo "❌ install helper must not read a second positional parameter." >&2
  exit 1
fi
require_fixed "$revoke_file" 'username="${1:-}"' \
  "revoke helper must read the target username as its first positional parameter"
require_fixed "$revoke_file" 'fingerprint="${2:-}"' \
  "revoke helper must read the key fingerprint as its second positional parameter"
if rg -q -F '${3' "$revoke_file"; then
  echo "❌ revoke helper must not read a third positional parameter." >&2
  exit 1
fi
printf 'ok - neither helper accepts an actor or extra positional argument\n'

# 6. Sudo scope unchanged: the two helpers stay in the homepage NOPASSWD rule
#    set as exact store paths, with no argument/wildcard or option broadening.
require_fixed "$TESTS_REPO_ROOT/modules/Core_Modules/homepage/services.nix" \
  'NOPASSWD' \
  "SFTP helper sudoers rules must retain NOPASSWD (no broadening)"
for sudo_command in "$install_drv:$install_file" "$revoke_drv:$revoke_file"; do
  sudo_path="${sudo_command%%:*}"
  sudo_options="$(jq -er --arg cmd "$sudo_path" '
    [.[] | select(.command == $cmd)]
    | if length == 1 then .[0].options else error("expected exactly one sudo rule") end
    | join(",")
  ' <<<"$sudo_rules")" || {
    echo "❌ $(basename "${sudo_command#*:}"): missing or duplicated sudo rule." >&2
    exit 1
  }
  if [[ "$sudo_options" != "NOPASSWD" ]]; then
    echo "❌ $(basename "${sudo_command#*:}"): sudo rule options are '$sudo_options', expected exactly NOPASSWD." >&2
    exit 1
  fi
done
if ! jq -e 'all(.[]; (.options == ["NOPASSWD"]))' <<<"$sudo_rules" >/dev/null; then
  echo "❌ homepage sudo rules must all stay NOPASSWD-only (no ALL/setenv broadening)." >&2
  exit 1
fi
if jq -e '[.[] | select(.command | test("[[:space:]]"))] | length > 0' <<<"$sudo_rules" >/dev/null; then
  echo "❌ homepage sudo rules must name exact helper paths, never commands with arguments." >&2
  exit 1
fi
printf 'ok - homepage sudo rules remain exact NOPASSWD helper paths (install and revoke present)\n'

# ---------------------------------------------------------------------------
# Behavioral tests: execute the rendered helpers with path-substituted mocks.
# ---------------------------------------------------------------------------

sftp_dir="$test_dir/sftp-keys"
mkdir -p "$sftp_dir"
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"
group_dir="$test_dir/groups"
mkdir -p "$group_dir"
call_log="$test_dir/kanidm-calls.log"
: >"$call_log"
mock_secret="$test_dir/kanidm-admin-pass"
printf 'test-admin-pass\n' >"$mock_secret"

# Mock kanidm: controlled by env vars.
#   MOCK_KANIDM_LOGIN_FAIL=1   → login fails
#   MOCK_KANIDM_GROUP_JSON     → JSON for every group get
#   MOCK_KANIDM_GROUP_DIR      → per-group JSON responses; "<dir>/<group>"
#                                holds the raw response body and
#                                "<dir>/<group>.fail" makes that lookup fail.
#                                Groups with no file fall back to
#                                MOCK_KANIDM_GROUP_JSON.
#   MOCK_KANIDM_DELAY          → seconds to stall inside a group lookup
#   MOCK_KANIDM_CALL_LOG       → append every invocation ("login", "group:<g>",
#                                "person:<user>") so call order is assertable
#   MOCK_KANIDM_PERSON_EXIST=1 → person get succeeds (default)
#   MOCK_KANIDM_PERSON_FAIL=1  → person get fails
cat >"$mock_bin/kanidm" <<'MOCK_EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
subcmd="${2:-}"
record_call() {
  [[ -n "${MOCK_KANIDM_CALL_LOG:-}" ]] || return 0
  printf '%s\n' "$1" >>"$MOCK_KANIDM_CALL_LOG"
}
case "$cmd $subcmd" in
  "login "*)
    record_call "login"
    if [[ "${MOCK_KANIDM_LOGIN_FAIL:-0}" == 1 ]]; then
      echo "kanidm: login failed" >&2
      exit 1
    fi
    exit 0
    ;;
  "group get")
    group_name="${3:-}"
    record_call "group:$group_name"
    if [[ -n "${MOCK_EXPECT_LOCK:-}" ]] \
      && flock -n "$SFTP_TEST_DIR/.$MOCK_EXPECT_LOCK.lock" -c true 2>/dev/null; then
      echo "kanidm: group lookup did not hold the per-user lock" >&2
      exit 97
    fi
    if [[ -n "${MOCK_KANIDM_DELAY:-}" ]]; then
      sleep "$MOCK_KANIDM_DELAY"
    fi
    if [[ -n "${MOCK_KANIDM_GROUP_DIR:-}" ]]; then
      if [[ -f "$MOCK_KANIDM_GROUP_DIR/$group_name.fail" ]]; then
        echo "kanidm: group get for $group_name failed" >&2
        exit 1
      fi
      if [[ -f "$MOCK_KANIDM_GROUP_DIR/$group_name" ]]; then
        cat "$MOCK_KANIDM_GROUP_DIR/$group_name"
        exit 0
      fi
    fi
    if [[ "${MOCK_KANIDM_GROUP_FAIL:-0}" == 1 ]]; then
      echo "kanidm: group get failed" >&2
      exit 1
    fi
    if [[ -n "${MOCK_KANIDM_GROUP_JSON:-}" ]]; then
      printf '%s\n' "$MOCK_KANIDM_GROUP_JSON"
    else
      printf '%s\n' '{"attrs":{"member":[]}}'
    fi
    exit 0
    ;;
  "person get")
    record_call "person:${3:-}"
    if [[ -n "${MOCK_EXPECT_LOCK:-}" ]] \
      && flock -n "$SFTP_TEST_DIR/.$MOCK_EXPECT_LOCK.lock" -c true 2>/dev/null; then
      echo "kanidm: person lookup did not hold the per-user lock" >&2
      exit 97
    fi
    if [[ "${MOCK_KANIDM_PERSON_FAIL:-0}" == 1 ]]; then
      echo "kanidm: person not found" >&2
      exit 1
    fi
    printf '{"id":"person-1"}\n'
    exit 0
    ;;
  *)
    echo "kanidm: unexpected command: $cmd $subcmd" >&2
    exit 1
    ;;
esac
MOCK_EOF
chmod +x "$mock_bin/kanidm"

# Mock install: the helpers run `install -d -m 0755 -o root -g root <dir>`,
# which a non-root test user cannot perform. Strip the ownership flags.
cat >"$mock_bin/install" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-d" ]]; then
  dir="${@: -1}"
  mkdir -p "$dir"
  exit 0
fi
exit 0
MOCK_EOF
chmod +x "$mock_bin/install"

# Mock chown: the helpers run `chown root:root <file>`.
cat >"$mock_bin/chown" <<'MOCK_EOF'
#!/usr/bin/env bash
exit 0
MOCK_EOF
chmod +x "$mock_bin/chown"

# Mock stat: the helpers check `stat -c '%U:%G'` == root:root. Report
# root:root for the ownership query; delegate mode queries to real stat.
cat >"$mock_bin/stat" <<'MOCK_EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "-c" && "${2:-}" == "%U:%G" ]]; then
  echo "root:root"
  exit 0
fi
exec /usr/bin/stat "$@"
MOCK_EOF
chmod +x "$mock_bin/stat"

# Generate test SSH key pairs for the behavioral tests.
test_key_file="$test_dir/test-key"
ssh-keygen -t ed25519 -N "" -f "$test_dir/test-keypair" -q
test_pub_key="$(awk '{print $1" "$2}' "$test_dir/test-keypair.pub")"
test_fingerprint="$(ssh-keygen -lf "$test_dir/test-keypair.pub" | awk '{print $2}')"
ssh-keygen -t ed25519 -N "" -f "$test_dir/other-keypair" -q
other_pub_key="$(awk '{print $1" "$2}' "$test_dir/other-keypair.pub")"
other_fingerprint="$(ssh-keygen -lf "$test_dir/other-keypair.pub" | awk '{print $2}')"
if [[ "$test_pub_key" == "$other_pub_key" || "$test_fingerprint" == "$other_fingerprint" ]]; then
  echo "❌ generated test key pairs are not distinct." >&2
  exit 1
fi

# Path-substitution function: replace store paths in the rendered helper text
# with test/mock paths. kanidm, install, chown, and stat use the mocks; the
# remaining utilities map to their system locations.
substitute_paths() {
  local text="$1"
  # Replace the kanidm binary path (store path + /bin/kanidm).
  text="$(sed "s|/nix/store/[^ ]*/bin/kanidm|$mock_bin/kanidm|g" <<<"$text")"
  # Replace the agenix secret path.
  text="$(sed "s|/run/agenix/kanidmAdminPass|$mock_secret|g" <<<"$text")"
  # Replace the SFTP authorized-keys directory (matches the canonical value
  # from modules/Core_Modules/homepage/services.nix).
  text="$(sed "s|/persist/appdata/files-sftp-authorized-keys|$sftp_dir|g" <<<"$text")"
  # Route ownership-sensitive utilities to the mocks.
  for mock_util in install chown stat; do
    text="$(sed "s|/nix/store/[^ ]*/bin/$mock_util|$mock_bin/$mock_util|g" <<<"$text")"
  done
  # Map the remaining utilities to their system locations.
  for util in jq flock ssh-keygen grep sed mktemp cat chmod mv rm printf tr cut; do
    local real_path
    real_path="$(command -v "$util" 2>/dev/null || true)"
    if [[ -n "$real_path" ]]; then
      text="$(sed "s|/nix/store/[^ ]*/bin/$util|$real_path|g" <<<"$text")"
    fi
  done
  printf '%s' "$text"
}

install_exec="$test_dir/install-exec"
revoke_exec="$test_dir/revoke-exec"
substitute_paths "$install_text" >"$install_exec"
substitute_paths "$revoke_text" >"$revoke_exec"
chmod +x "$install_exec" "$revoke_exec"

# The install helper's SFTP access groups come from the module (five distinct
# groups here). Read them from the rendered helper so the per-group cases use
# the real order instead of a hard-coded list.
group_list_line="$(grep -m1 -F 'sftp_access_groups=' "$install_exec")"
group_list_literal="${group_list_line#*sftp_access_groups=}"
group_list_literal="${group_list_literal#\'}"
group_list_literal="${group_list_literal%\'}"
read -r -a sftp_access_groups <<<"$group_list_literal"
if (( ${#sftp_access_groups[@]} < 3 )); then
  echo "❌ rendered helper must expose at least three SFTP access groups for the multi-group matrix; got '${group_list_literal}'." >&2
  exit 1
fi
first_group="${sftp_access_groups[0]}"
second_group="${sftp_access_groups[1]}"
last_group="${sftp_access_groups[${#sftp_access_groups[@]} - 1]}"

member_json() {
  local user="$1"
  printf '{"attrs":{"member":["%s"]}}\n' "$user"
}

reset_group_dir() {
  rm -rf "$group_dir"
  mkdir -p "$group_dir"
  : >"$call_log"
}

expect_rc_one() {
  local label="$1" rc
  shift
  if "$@" >/dev/null 2>&1; then
    echo "❌ $label unexpectedly succeeded." >&2
    return 1
  else
    rc=$?
  fi
  if (( rc != 1 )); then
    echo "❌ $label returned $rc; expected exit 1." >&2
    return 1
  fi
  printf 'ok - %s rejected with exit 1\n' "$label"
}

# expect_denied <label> <log> <cmd...>
# Requires exit 1 and keeps the combined output for message assertions.
expect_denied() {
  local label="$1" log="$2" rc=0
  shift 2
  "$@" >"$log" 2>&1 || rc=$?
  if (( rc != 1 )); then
    echo "❌ $label returned $rc; expected exit 1." >&2
    cat "$log" >&2 || true
    exit 1
  fi
  printf 'ok - %s rejected with exit 1\n' "$label"
}

assert_absent() {
  local label="$1" path="$2"
  if [[ -e "$path" ]]; then
    echo "❌ $label: $path exists after a refused operation." >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

# assert_preserved <label> <snapshot> <path>
assert_preserved() {
  local label="$1" snapshot="$2" path="$3"
  if [[ ! -e "$path" ]]; then
    echo "❌ $label: $path was removed by a refused operation." >&2
    exit 1
  fi
  if ! cmp -s "$snapshot" "$path"; then
    echo "❌ $label: $path changed on a refused operation." >&2
    diff -u "$snapshot" "$path" >&2 || true
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

# assert_same_bytes <label> <expected-file> <actual-file>
assert_same_bytes() {
  local label="$1" expected="$2" actual="$3"
  if ! cmp -s "$expected" "$actual"; then
    echo "❌ $label: $actual does not match $expected." >&2
    diff -u "$expected" "$actual" >&2 || true
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

assert_group_calls() {
  local label="$1" log="$2"
  shift 2
  local line expected actual=()
  expected="$*"
  if [[ -s "$log" ]]; then
    while IFS= read -r line; do
      if [[ "$line" == group:* ]]; then
        actual+=("${line#group:}")
      fi
    done <"$log"
  fi
  if [[ "${actual[*]:-}" != "$expected" ]]; then
    echo "❌ $label: group lookups were [${actual[*]:-}]; expected [$expected]." >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

assert_no_kanidm_calls() {
  local label="$1" log="$2"
  if [[ -s "$log" ]]; then
    echo "❌ $label: Kanidm was contacted before input validation." >&2
    cat "$log" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

assert_calls_exact() {
  local label="$1" log="$2"
  shift 2
  local -a actual=()
  if [[ -s "$log" ]]; then
    mapfile -t actual <"$log"
  fi
  if [[ "${actual[*]:-}" != "$*" ]]; then
    echo "❌ $label: Kanidm calls were [${actual[*]:-}]; expected [$*]." >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

# Pre-populate the SFTP authorized-keys dir for the tests that need an
# existing key file for the target under test.
alice_key_file="$sftp_dir/alice"
printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"

group_json_with_alice='{"attrs":{"member":["alice","bob"]}}'

# ---------------------------------------------------------------------------
# Install: allowed paths.
# ---------------------------------------------------------------------------

rm -f "$sftp_dir/alice"
MOCK_EXPECT_LOCK=alice SFTP_TEST_DIR="$sftp_dir" MOCK_KANIDM_GROUP_JSON="$group_json_with_alice" \
  bash "$install_exec" alice <<<"$test_pub_key" >"$test_dir/install-allowed.log" 2>&1 \
  && [[ -f "$sftp_dir/alice" ]] \
  || { echo "❌ Install: eligible user's key was not written." >&2; cat "$test_dir/install-allowed.log" >&2; exit 1; }
if [[ "$(<"$sftp_dir/alice")" != "$test_pub_key" ]] \
  || [[ "$(<"$test_dir/install-allowed.log")" != "saved $sftp_dir/alice owner=root:root mode=644 registered-keys=1" ]]; then
  echo "❌ Install: success did not produce the exact expected key and receipt." >&2
  exit 1
fi

# A realm-qualified Kanidm member resolves to its local username component.
rm -f "$sftp_dir/alice"
MOCK_KANIDM_GROUP_JSON='{"attrs":{"member":["alice@example.test"]}}' \
  bash "$install_exec" alice <<<"$test_pub_key" >"$test_dir/install-realm.log" 2>&1 \
  || { echo "❌ Install: realm-qualified eligible member was rejected." >&2; exit 1; }
if [[ "$(<"$sftp_dir/alice")" != "$test_pub_key" ]]; then
  echo "❌ Install: realm-qualified member produced unexpected key content." >&2
  exit 1
fi

# A group with no members legitimately omits the member attribute: a
# well-formed response for a group the target does not belong to is an
# authoritative nonmatch, not a malformed response.
rm -f "$sftp_dir/alice"
MOCK_KANIDM_GROUP_JSON='{"attrs":{"class":["group"],"name":["g"],"gidnumber":["1"]}}' \
  expect_denied "install against a group without a member attribute" "$test_dir/install-no-member-attr.log" \
  bash "$install_exec" alice <<<"$test_pub_key"
require_fixed "$test_dir/install-no-member-attr.log" \
  "current Kanidm membership does not permit SFTP access; no key was installed" \
  "a group without a member attribute must read as an authoritative nonmatch"
assert_absent "install without a member attribute writes no key" "$sftp_dir/alice"

# ---------------------------------------------------------------------------
# Install: per-group answers across the configured group list.
# ---------------------------------------------------------------------------

# Every group answers as a nonmatch: the helper walks the whole list, then
# refuses with the eligibility message.
reset_group_dir
expect_denied "nonmember install across every SFTP group" "$test_dir/install-nonmember.log" \
  env MOCK_KANIDM_CALL_LOG="$call_log" bash "$install_exec" mallory <<<"$test_pub_key"
require_fixed "$test_dir/install-nonmember.log" \
  "current Kanidm membership does not permit SFTP access; no key was installed" \
  "install must refuse a target absent from every group"
assert_group_calls "every group is consulted for a nonmember" "$call_log" "${sftp_access_groups[@]}"
assert_absent "nonmember install creates no key file" "$sftp_dir/mallory"

# A later group matches: earlier nonmatches continue, the match short-circuits
# so the remaining groups are never queried.
reset_group_dir
member_json bob >"$group_dir/$first_group"
member_json alice >"$group_dir/$second_group"
rm -f "$sftp_dir/alice"
MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_CALL_LOG="$call_log" \
  bash "$install_exec" alice <<<"$test_pub_key" >"$test_dir/install-second-group.log" 2>&1 \
  || { echo "❌ Install: a match in a later SFTP group was rejected." >&2; cat "$test_dir/install-second-group.log" >&2; exit 1; }
if [[ "$(<"$sftp_dir/alice")" != "$test_pub_key" ]] \
  || [[ "$(<"$test_dir/install-second-group.log")" != "saved $sftp_dir/alice owner=root:root mode=644 registered-keys=1" ]]; then
  echo "❌ Install: later-group match did not produce the exact key bytes and receipt." >&2
  exit 1
fi
assert_group_calls "a matching group stops the lookup" "$call_log" "$first_group" "$second_group"

# A per-group lookup failure refuses without falling through to later groups.
reset_group_dir
: >"$group_dir/$first_group.fail"
member_json alice >"$group_dir/$second_group"
rm -f "$sftp_dir/alice"
expect_denied "group lookup failure followed by a matching group" "$test_dir/install-group-fail.log" \
  env MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_CALL_LOG="$call_log" \
  bash "$install_exec" alice <<<"$test_pub_key"
require_fixed "$test_dir/install-group-fail.log" \
  "unable to verify current SFTP membership; no key was installed" \
  "a failed group lookup must refuse even when a later group would match"
assert_group_calls "a failed group lookup stops the walk" "$call_log" "$first_group"
assert_absent "a failed group lookup writes no key" "$sftp_dir/alice"

# ---------------------------------------------------------------------------
# Install: malformed and schema-invalid group responses fail closed.
# Each case returns jq exit status > 1, which is not an answer, so a later
# positive group must never be reached.
# ---------------------------------------------------------------------------

malformed_install_case() {
  local label="$1" body="$2" log="$3"
  reset_group_dir
  printf '%s\n' "$body" >"$group_dir/$first_group"
  member_json alice >"$group_dir/$second_group"
  rm -f "$sftp_dir/alice"
  expect_denied "$label" "$log" \
    env MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_CALL_LOG="$call_log" \
    bash "$install_exec" alice <<<"$test_pub_key"
  require_fixed "$log" \
    "unable to verify current SFTP membership; no key was installed" \
    "$label must refuse with the fail-closed message"
  assert_group_calls "$label stops at the malformed response" "$call_log" "$first_group"
  assert_absent "$label writes no key" "$sftp_dir/alice"
}

malformed_install_case "unparseable first group response" \
  'not-json' "$test_dir/install-not-json.log"
malformed_install_case "empty first group response" \
  '' "$test_dir/install-empty-json.log"
malformed_install_case "non-object first group response" \
  '[]' "$test_dir/install-array-json.log"
malformed_install_case "null first group response" \
  'null' "$test_dir/install-null-json.log"
malformed_install_case "group response without attrs" \
  '{"className":"group"}' "$test_dir/install-no-attrs.log"
malformed_install_case "member attribute that is not an array" \
  '{"attrs":{"member":"alice"}}' "$test_dir/install-member-string.log"
malformed_install_case "member entry that is not a string" \
  '{"attrs":{"member":[42]}}' "$test_dir/install-member-number.log"
malformed_install_case "member entry with an invalid local username" \
  '{"attrs":{"member":["Not_A_User@example.test"]}}' "$test_dir/install-member-bad-user.log"

# ---------------------------------------------------------------------------
# Install: denial never disturbs a targeted existing key.
# ---------------------------------------------------------------------------

printf '%s\n' "$other_pub_key" >"$sftp_dir/bob"
chmod 0644 "$sftp_dir/bob"
cp "$sftp_dir/bob" "$test_dir/bob-before"

expect_denied "install for a target outside every SFTP group" "$test_dir/install-bob-denied.log" \
  bash "$install_exec" bob <<<"$test_pub_key"
require_fixed "$test_dir/install-bob-denied.log" \
  "current Kanidm membership does not permit SFTP access; no key was installed" \
  "install must refuse a target outside every group"
assert_preserved "denied install preserves the existing key file" "$test_dir/bob-before" "$sftp_dir/bob"

expect_denied "install with a Kanidm login failure" "$test_dir/install-login-failure.log" \
  env MOCK_KANIDM_LOGIN_FAIL=1 bash "$install_exec" bob <<<"$test_pub_key"
require_fixed "$test_dir/install-login-failure.log" \
  "unable to verify current SFTP membership; no key was installed" \
  "install must refuse when Kanidm login fails"
assert_preserved "login failure preserves the existing key file" "$test_dir/bob-before" "$sftp_dir/bob"

reset_group_dir
printf 'not-json\n' >"$group_dir/$first_group"
member_json bob >"$group_dir/$second_group"
expect_denied "install with a malformed group response" "$test_dir/install-bob-malformed.log" \
  env MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_CALL_LOG="$call_log" \
  bash "$install_exec" bob <<<"$test_pub_key"
assert_preserved "malformed response preserves the existing key file" "$test_dir/bob-before" "$sftp_dir/bob"

# An existing authorized-keys file with a widened mode is refused untouched.
printf '%s\n' "$other_pub_key" >"$alice_key_file"
chmod 0600 "$alice_key_file"
cp "$alice_key_file" "$test_dir/alice-unsafe-before"
expect_denied "install over an authorized-keys file with an unsafe mode" "$test_dir/install-unsafe-mode.log" \
  env MOCK_KANIDM_GROUP_JSON="$group_json_with_alice" \
  bash "$install_exec" alice <<<"$test_pub_key"
require_fixed "$test_dir/install-unsafe-mode.log" \
  "existing authorized-keys file has unsafe ownership, mode, or type" \
  "install must refuse an existing file with an unsafe mode"
assert_preserved "unsafe-mode install leaves the file untouched" "$test_dir/alice-unsafe-before" "$alice_key_file"
if [[ "$(stat -c '%a' "$alice_key_file")" != "600" ]]; then
  echo "❌ unsafe-mode install changed the existing file mode." >&2
  exit 1
fi

# The ten-key ceiling refuses without touching the existing file.
{
  key_index=0
  while (( key_index < 10 )); do
    printf '%s\n' "$other_pub_key"
    key_index=$((key_index + 1))
  done
} >"$alice_key_file"
chmod 0644 "$alice_key_file"
cp "$alice_key_file" "$test_dir/alice-cap-before"
expect_denied "install past the ten-key ceiling" "$test_dir/install-cap.log" \
  env MOCK_KANIDM_GROUP_JSON="$group_json_with_alice" \
  bash "$install_exec" alice <<<"$test_pub_key"
require_fixed "$test_dir/install-cap.log" \
  "at most 10 SFTP device keys may be registered" \
  "install must refuse an eleventh key"
assert_preserved "key-ceiling install preserves the existing file" "$test_dir/alice-cap-before" "$alice_key_file"

# ---------------------------------------------------------------------------
# Install: malformed key input is rejected before any Kanidm contact.
# ---------------------------------------------------------------------------

malformed_key_case() {
  local label="$1" key="$2" log="$3" expected="$4"
  : >"$call_log"
  rm -f "$sftp_dir/frank"
  expect_denied "$label" "$log" \
    env MOCK_KANIDM_CALL_LOG="$call_log" bash "$install_exec" frank <<<"$key"
  require_fixed "$log" "$expected" "$label must refuse with the documented message"
  assert_no_kanidm_calls "$label is rejected before any Kanidm contact" "$call_log"
  assert_absent "$label writes no key" "$sftp_dir/frank"
}

malformed_key_case "install with a non-key payload" 'not-an-ssh-key' \
  "$test_dir/install-key-garbage.log" "invalid OpenSSH public key"
malformed_key_case "install with an empty key" '' \
  "$test_dir/install-key-empty.log" "invalid OpenSSH public key"
malformed_key_case "install with an unexpected key type" 'ssh-dss AAAAB3NzaC1kc3M=' \
  "$test_dir/install-key-type.log" "invalid OpenSSH public key"
malformed_key_case "install with a control character in the key" \
  "$(printf 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI%s\001' 'x')" \
  "$test_dir/install-key-control.log" "invalid control character in public key"
malformed_key_case "install with a corrupt key body" 'ssh-ed25519 !!!not-base64!!!' \
  "$test_dir/install-key-corrupt.log" "invalid or corrupted OpenSSH public key"

# ---------------------------------------------------------------------------
# Install and revoke: a forged actor claim never changes target eligibility.
# The helpers receive only the target username (plus revoke fingerprint); an
# environment or extra argument claiming a privileged actor must not grant a
# key for a target that is not eligible.
# ---------------------------------------------------------------------------

: >"$call_log"
rm -f "$sftp_dir/mallory"
expect_denied "install for an ineligible target with forged actor claims" "$test_dir/install-forged-actor.log" \
  env MOCK_KANIDM_CALL_LOG="$call_log" SUDO_USER=root SUDO_UID=0 ACTOR=admin CALLER=admin ACTING_USER=admin \
  bash "$install_exec" mallory <<<"$test_pub_key"
require_fixed "$test_dir/install-forged-actor.log" \
  "current Kanidm membership does not permit SFTP access; no key was installed" \
  "a forged actor claim must not confer eligibility"
assert_absent "forged actor claim writes no key" "$sftp_dir/mallory"

rm -f "$sftp_dir/mallory"
expect_denied "install for an ineligible target with an appended actor argument" "$test_dir/install-extra-arg.log" \
  bash "$install_exec" mallory admin <<<"$test_pub_key"
require_fixed "$test_dir/install-extra-arg.log" \
  "current Kanidm membership does not permit SFTP access; no key was installed" \
  "an appended actor argument must not confer eligibility"
assert_absent "appended actor argument writes no key" "$sftp_dir/mallory"

# A forged claim does not redirect an eligible install to another target.
rm -f "$sftp_dir/alice"
MOCK_KANIDM_GROUP_JSON="$group_json_with_alice" SUDO_USER=root ACTOR=admin CALLER=admin ACTING_USER=admin \
  bash "$install_exec" alice <<<"$test_pub_key" >"$test_dir/install-eligible-forged.log" 2>&1 \
  || { echo "❌ Install: forged actor claim blocked an eligible target." >&2; cat "$test_dir/install-eligible-forged.log" >&2; exit 1; }
for claimed in admin root; do
  assert_absent "eligible install writes no file for forged actor '$claimed'" "$sftp_dir/$claimed"
done
if [[ "$(<"$sftp_dir/alice")" != "$test_pub_key" ]]; then
  echo "❌ Install: eligible install with a forged actor claim wrote unexpected bytes." >&2
  exit 1
fi

printf '%s\n' "$other_pub_key" >"$sftp_dir/ghost"
chmod 0644 "$sftp_dir/ghost"
cp "$sftp_dir/ghost" "$test_dir/ghost-before"
: >"$call_log"
expect_denied "revoke for a nonexistent person with forged actor claims" "$test_dir/revoke-forged-actor.log" \
  env MOCK_KANIDM_CALL_LOG="$call_log" MOCK_KANIDM_PERSON_FAIL=1 SUDO_USER=root ACTOR=admin CALLER=admin \
  bash "$revoke_exec" ghost "$other_fingerprint"
require_fixed "$test_dir/revoke-forged-actor.log" \
  "target user is not a current Kanidm person; no key was revoked" \
  "a forged actor claim must not authorize revoking for a nonexistent person"
assert_preserved "forged actor revoke preserves the targeted file" "$test_dir/ghost-before" "$sftp_dir/ghost"

# ---------------------------------------------------------------------------
# Revoke: allowed paths, exact receipts and exact final content.
# ---------------------------------------------------------------------------

# Offboarding: the person still exists in Kanidm but belongs to no SFTP group,
# so no group lookup is performed and the revoke proceeds.
printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
: >"$call_log"
MOCK_EXPECT_LOCK=alice SFTP_TEST_DIR="$sftp_dir" MOCK_KANIDM_CALL_LOG="$call_log" \
  MOCK_KANIDM_GROUP_JSON='{"attrs":{"member":[]}}' \
  bash "$revoke_exec" alice "$test_fingerprint" >"$test_dir/revoke-offboarding.log" 2>&1 \
  || { echo "❌ Revoke: offboarding a user removed from every SFTP group failed." >&2; cat "$test_dir/revoke-offboarding.log" >&2; exit 1; }
if [[ "$(<"$test_dir/revoke-offboarding.log")" != "revoked 1 key(s) for alice" ]]; then
  echo "❌ Revoke: offboarding did not produce the exact receipt." >&2
  cat "$test_dir/revoke-offboarding.log" >&2
  exit 1
fi
assert_calls_exact "offboarding revoke only checks person existence" "$call_log" "login" "person:alice"
if [[ ! -f "$alice_key_file" || -s "$alice_key_file" ]]; then
  echo "❌ Revoke: offboarding left key material behind." >&2
  exit 1
fi

# Only the targeted fingerprint is removed; the remaining key survives byte
# exactly and the receipt reports one removal.
printf '%s\n%s\n' "$other_pub_key" "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
printf '%s\n' "$other_pub_key" >"$test_dir/alice-expected-after-revoke"
bash "$revoke_exec" alice "$test_fingerprint" >"$test_dir/revoke-targeted.log" 2>&1 \
  || { echo "❌ Revoke: targeted removal failed." >&2; cat "$test_dir/revoke-targeted.log" >&2; exit 1; }
if [[ "$(<"$test_dir/revoke-targeted.log")" != "revoked 1 key(s) for alice" ]]; then
  echo "❌ Revoke: targeted removal did not produce the exact receipt." >&2
  exit 1
fi
assert_preserved "targeted revoke keeps the other key byte-exactly" "$test_dir/alice-expected-after-revoke" "$alice_key_file"

# A fingerprint that is not registered is refused and the file is untouched.
printf '%s\n' "$other_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
cp "$alice_key_file" "$test_dir/alice-unregistered-before"
expect_denied "revoke of an unregistered fingerprint" "$test_dir/revoke-unregistered.log" \
  bash "$revoke_exec" alice "$test_fingerprint"
require_fixed "$test_dir/revoke-unregistered.log" \
  "key fingerprint is not registered for this user" \
  "revoke must refuse an unregistered fingerprint"
assert_preserved "unregistered fingerprint leaves the file untouched" "$test_dir/alice-unregistered-before" "$alice_key_file"

# A missing authorized-keys file is refused, never created.
rm -f "$sftp_dir/nofile"
expect_denied "revoke for a person without an authorized-keys file" "$test_dir/revoke-no-file.log" \
  bash "$revoke_exec" nofile "$test_fingerprint"
require_fixed "$test_dir/revoke-no-file.log" \
  "authorized-keys file does not exist or is not a regular file" \
  "revoke must refuse a missing authorized-keys file"
assert_absent "revoke does not create an authorized-keys file" "$sftp_dir/nofile"

# ---------------------------------------------------------------------------
# Revoke: denials never disturb the targeted existing key.
# ---------------------------------------------------------------------------

# A nonexistent Kanidm person keeps its own pre-existing key file intact.
printf '%s\n' "$other_pub_key" >"$sftp_dir/ghost"
chmod 0644 "$sftp_dir/ghost"
cp "$sftp_dir/ghost" "$test_dir/revoke-ghost-before"
expect_denied "revoke for a nonexistent person" "$test_dir/revoke-ghost.log" \
  env MOCK_KANIDM_PERSON_FAIL=1 bash "$revoke_exec" ghost "$other_fingerprint"
require_fixed "$test_dir/revoke-ghost.log" \
  "target user is not a current Kanidm person; no key was revoked" \
  "revoke must refuse a nonexistent person"
assert_preserved "nonexistent person's own key file is preserved" "$test_dir/revoke-ghost-before" "$sftp_dir/ghost"

printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
cp "$alice_key_file" "$test_dir/revoke-before"
expect_denied "revoke with a Kanidm login failure" "$test_dir/revoke-login-failure.log" \
  env MOCK_KANIDM_LOGIN_FAIL=1 bash "$revoke_exec" alice "$test_fingerprint"
require_fixed "$test_dir/revoke-login-failure.log" \
  "unable to verify current Kanidm state; no key was revoked" \
  "revoke must refuse when Kanidm login fails"
assert_preserved "login failure preserves the targeted key file" "$test_dir/revoke-before" "$alice_key_file"

expect_denied "revoke with a Kanidm person lookup failure" "$test_dir/revoke-person-failure.log" \
  env MOCK_KANIDM_PERSON_FAIL=1 bash "$revoke_exec" alice "$test_fingerprint"
require_fixed "$test_dir/revoke-person-failure.log" \
  "target user is not a current Kanidm person; no key was revoked" \
  "revoke must refuse when the person lookup fails"
assert_preserved "person lookup failure preserves the targeted key file" "$test_dir/revoke-before" "$alice_key_file"

# An authorized-keys file with a widened mode is refused untouched.
chmod 0600 "$alice_key_file"
cp "$alice_key_file" "$test_dir/revoke-unsafe-before"
expect_denied "revoke over a file with an unsafe mode" "$test_dir/revoke-unsafe-mode.log" \
  bash "$revoke_exec" alice "$test_fingerprint"
require_fixed "$test_dir/revoke-unsafe-mode.log" \
  "authorized-keys file has unsafe ownership or mode" \
  "revoke must refuse an authorized-keys file with an unsafe mode"
assert_preserved "unsafe-mode revoke leaves the file untouched" "$test_dir/revoke-unsafe-before" "$alice_key_file"
chmod 0644 "$alice_key_file"

# ---------------------------------------------------------------------------
# Both helpers: malformed usernames and fingerprints are rejected before any
# Kanidm contact.
# ---------------------------------------------------------------------------

printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
cp "$alice_key_file" "$test_dir/revoke-inputs-before"

: >"$call_log"
expect_denied "revoke with a malformed username" "$test_dir/revoke-bad-username.log" \
  env MOCK_KANIDM_CALL_LOG="$call_log" bash "$revoke_exec" 'Bad-User!' "$test_fingerprint"
require_fixed "$test_dir/revoke-bad-username.log" "invalid username" \
  "revoke must reject a malformed username"
assert_no_kanidm_calls "malformed revoke username is rejected before Kanidm" "$call_log"

: >"$call_log"
expect_denied "install with a malformed username" "$test_dir/install-bad-username.log" \
  env MOCK_KANIDM_CALL_LOG="$call_log" bash "$install_exec" 'Bad-User!' <<<"$test_pub_key"
require_fixed "$test_dir/install-bad-username.log" "invalid username" \
  "install must reject a malformed username"
assert_no_kanidm_calls "malformed install username is rejected before Kanidm" "$call_log"

malformed_fingerprint_case() {
  local label="$1" fingerprint="$2" log="$3"
  : >"$call_log"
  if [[ "$fingerprint" == "<absent>" ]]; then
    expect_denied "$label" "$log" \
      env MOCK_KANIDM_CALL_LOG="$call_log" bash "$revoke_exec" alice
  else
    expect_denied "$label" "$log" \
      env MOCK_KANIDM_CALL_LOG="$call_log" bash "$revoke_exec" alice "$fingerprint"
  fi
  require_fixed "$log" "invalid key fingerprint" "$label must be rejected as a malformed fingerprint"
  assert_no_kanidm_calls "$label is rejected before Kanidm" "$call_log"
  assert_preserved "$label leaves the targeted file untouched" "$test_dir/revoke-inputs-before" "$alice_key_file"
}

malformed_fingerprint_case "revoke with an absent fingerprint" '<absent>' \
  "$test_dir/revoke-fingerprint-absent.log"
malformed_fingerprint_case "revoke with a bare fingerprint label" 'SHA256:' \
  "$test_dir/revoke-fingerprint-empty.log"
malformed_fingerprint_case "revoke with an MD5 fingerprint" 'MD5:aa:bb:cc' \
  "$test_dir/revoke-fingerprint-md5.log"
malformed_fingerprint_case "revoke with whitespace in the fingerprint" 'SHA256:abcdef ghij' \
  "$test_dir/revoke-fingerprint-space.log"
malformed_fingerprint_case "revoke with non-base64 fingerprint characters" 'SHA256:abc$def' \
  "$test_dir/revoke-fingerprint-chars.log"

# ---------------------------------------------------------------------------
# Competing same-user mutations: the per-user lock serializes changes so no
# update is lost and no key is duplicated.
# ---------------------------------------------------------------------------

reset_group_dir
printf '{"attrs":{"member":["carol","dave"]}}\n' >"$group_dir/$first_group"
rm -f "$sftp_dir/carol"
MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_DELAY=0.2 \
  bash "$install_exec" carol <<<"$test_pub_key" >"$test_dir/competing-a.log" 2>&1 &
competing_a=$!
MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_DELAY=0.2 \
  bash "$install_exec" carol <<<"$other_pub_key" >"$test_dir/competing-b.log" 2>&1 &
competing_b=$!
rc_a=0
rc_b=0
wait "$competing_a" || rc_a=$?
wait "$competing_b" || rc_b=$?
if (( rc_a != 0 || rc_b != 0 )); then
  echo "❌ Competing install: concurrent installs returned $rc_a and $rc_b; expected 0 and 0." >&2
  cat "$test_dir/competing-a.log" "$test_dir/competing-b.log" >&2
  exit 1
fi
printf '%s\n%s\n' "$test_pub_key" "$other_pub_key" | sort >"$test_dir/competing-expected"
sort "$sftp_dir/carol" >"$test_dir/competing-actual"
assert_same_bytes "competing installs keep both keys with exact content" "$test_dir/competing-expected" "$test_dir/competing-actual"
competing_receipts="$(grep -ho 'registered-keys=[0-9]*' "$test_dir/competing-a.log" "$test_dir/competing-b.log" | sort | tr '\n' ' ')"
if [[ "$competing_receipts" != "registered-keys=1 registered-keys=2 " ]]; then
  echo "❌ Competing install: receipts were '$competing_receipts'; expected 1 then 2 (no lost update)." >&2
  cat "$test_dir/competing-a.log" "$test_dir/competing-b.log" >&2
  exit 1
fi

# The same key submitted twice concurrently is stored exactly once.
rm -f "$sftp_dir/dave"
MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_DELAY=0.2 \
  bash "$install_exec" dave <<<"$test_pub_key" >"$test_dir/competing-c.log" 2>&1 &
competing_c=$!
MOCK_KANIDM_GROUP_DIR="$group_dir" MOCK_KANIDM_DELAY=0.2 \
  bash "$install_exec" dave <<<"$test_pub_key" >"$test_dir/competing-d.log" 2>&1 &
competing_d=$!
rc_c=0
rc_d=0
wait "$competing_c" || rc_c=$?
wait "$competing_d" || rc_d=$?
if (( rc_c != 0 || rc_d != 0 )); then
  echo "❌ Competing duplicate install: installs returned $rc_c and $rc_d; expected 0 and 0." >&2
  cat "$test_dir/competing-c.log" "$test_dir/competing-d.log" >&2
  exit 1
fi
duplicate_lines="$(grep -c . "$sftp_dir/dave")"
if [[ "$(<"$sftp_dir/dave")" != "$test_pub_key" ]] || (( duplicate_lines != 1 )); then
  echo "❌ Competing duplicate install: key stored $duplicate_lines time(s) instead of exactly once." >&2
  exit 1
fi
if grep -qv 'registered-keys=1' "$test_dir/competing-c.log" "$test_dir/competing-d.log"; then
  echo "❌ Competing duplicate install: receipts did not both report one registered key." >&2
  cat "$test_dir/competing-c.log" "$test_dir/competing-d.log" >&2
  exit 1
fi

echo "✅ SFTP key helper authorization tests passed."
