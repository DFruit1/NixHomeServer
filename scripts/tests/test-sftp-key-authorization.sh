#!/usr/bin/env bash
# Lean-tier test: SFTP key helper authorization hardening.
#
# Verifies that the install and revoke helpers:
#   1. Validate the target username shape before any Kanidm lookup.
#   2. Acquire the per-user flock before performing the Kanidm re-check.
#   3. Perform the Kanidm re-check (membership for install, existence for
#      revoke) under the same lock, before any key-file mutation.
#   4. Fail closed on Kanidm lookup failure (no key written / no key removed).
#   5. Do not accept an actor argument (only the target username).
#   6. Are reachable via the existing NOPASSWD sudoers rules (no broadening).
#
# Behavioral tests execute the rendered helpers with path-substituted mocks
# for kanidm, the agenix secret, the SFTP authorized-keys directory, and the
# standard utilities. No real Kanidm instance is contacted; no agenix
# plaintext is read.

set -euo pipefail

TESTS_REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$TESTS_REPO_ROOT/scripts/tests/test-common.sh"

ensure_tools jq rg sed bash

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
  }
')"

install_drv="$(jq -er '.installCommandDrv' <<<"$behavior_json")"
revoke_drv="$(jq -er '.revokeCommandDrv' <<<"$behavior_json")"
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

# 4. Fail-closed messages present.
require_fixed "$install_file" "unable to verify current SFTP membership; no key was installed" \
  "install helper must fail closed on Kanidm lookup failure"
require_fixed "$install_file" "current Kanidm membership does not permit SFTP access; no key was installed" \
  "install helper must reject non-eligible targets"
require_fixed "$revoke_file" "unable to verify current Kanidm state; no key was revoked" \
  "revoke helper must fail closed on Kanidm lookup failure"
require_fixed "$revoke_file" "target user is not a current Kanidm person; no key was revoked" \
  "revoke helper must reject nonexistent targets"

# 5. No actor argument. The helpers accept exactly one (install) or two
#    (revoke: username + fingerprint) positional args, neither of which is
#    an actor/identity argument.
install_arg_count="$(rg -c '^\$1|^\$2|^\$3' <<<"$install_text" || true)"
# Install: only $1 (username). No $2 that would be an actor.
if rg -q --multiline 'actor|acting_user|caller_username' <<<"$install_text"; then
  echo "❌ install helper must not accept an actor/identity argument." >&2
  exit 1
fi
if rg -q --multiline 'actor|acting_user|caller_username' <<<"$revoke_text"; then
  echo "❌ revoke helper must not accept an actor/identity argument." >&2
  exit 1
fi

# 6. Sudoers rules unchanged (no broadening).
require_fixed "$TESTS_REPO_ROOT/modules/Core_Modules/homepage/services.nix" \
  'NOPASSWD' \
  "SFTP helper sudoers rules must retain NOPASSWD (no broadening)"

# ---------------------------------------------------------------------------
# Behavioral tests: execute the rendered helpers with path-substituted mocks.
# ---------------------------------------------------------------------------

sftp_dir="$test_dir/sftp-keys"
mkdir -p "$sftp_dir"
mock_bin="$test_dir/bin"
mkdir -p "$mock_bin"
mock_secret="$test_dir/kanidm-admin-pass"
printf 'test-admin-pass\n' >"$mock_secret"

# Mock kanidm: controlled by env vars.
#   MOCK_KANIDM_LOGIN_FAIL=1   → login fails
#   MOCK_KANIDM_GROUP_JSON     → JSON for group get
#   MOCK_KANIDM_PERSON_EXIST=1 → person get succeeds (default)
#   MOCK_KANIDM_PERSON_FAIL=1  → person get fails
cat >"$mock_bin/kanidm" <<'MOCK_EOF'
#!/usr/bin/env bash
set -euo pipefail
cmd="${1:-}"
subcmd="${2:-}"
case "$cmd $subcmd" in
  "login "*)
    if [[ "${MOCK_KANIDM_LOGIN_FAIL:-0}" == 1 ]]; then
      echo "kanidm: login failed" >&2
      exit 1
    fi
    exit 0
    ;;
  "group get")
    group_name="${3:-}"
    if [[ -n "${MOCK_EXPECT_LOCK:-}" ]] \
      && flock -n "$SFTP_TEST_DIR/.$MOCK_EXPECT_LOCK.lock" -c true 2>/dev/null; then
      echo "kanidm: group lookup did not hold the per-user lock" >&2
      exit 97
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

# Generate a test SSH key pair for the behavioral tests.
test_key_file="$test_dir/test-key"
ssh-keygen -t ed25519 -N "" -f "$test_dir/test-keypair" -q
test_pub_key="$(awk '{print $1" "$2}' "$test_dir/test-keypair.pub")"
test_fingerprint="$(ssh-keygen -lf "$test_dir/test-keypair.pub" | awk '{print $2}')"

# Pre-populate the SFTP authorized-keys dir for revoke tests.
# Create a known key file for user "alice".
alice_key_file="$sftp_dir/alice"
printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"

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

# Helper: run a command, capture exit code and output.
run_helper() {
  local helper="$1"; shift
  local rc=0
  local output
  output="$("$@" 2>&1)" || rc=$?
  printf '%s\n---RC:%s---\n' "$output" "$rc"
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
  printf 'ok - %s rejected with exit 1\\n' "$label"
}

group_json_with_alice='{"attrs":{"member":["alice","bob"]}}'
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

# --- Install: rejected (not a member of any SFTP group) ---
group_json_empty='{"attrs":{"member":[]}}'
expect_rc_one "nonmember install" bash "$install_exec" mallory <<<"$test_pub_key"
if [[ -f "$sftp_dir/mallory" ]]; then
  echo "❌ Install: non-eligible user's key file was created." >&2
  exit 1
fi

# --- Install: rejected (nonexistent user — group JSON has no such member) ---
rm -f "$sftp_dir/ghost"
expect_rc_one "nonexistent install" env MOCK_KANIDM_GROUP_JSON="$group_json_with_alice" bash "$install_exec" ghost <<<"$test_pub_key"
if [[ -f "$sftp_dir/ghost" ]]; then
  echo "❌ Install: nonexistent user's key file was created." >&2
  exit 1
fi

# --- Install: rejected (Kanidm lookup failure) ---
rm -f "$sftp_dir/alice"
expect_rc_one "install Kanidm lookup failure" env MOCK_KANIDM_GROUP_FAIL=1 bash "$install_exec" alice <<<"$test_pub_key"
if [[ -f "$sftp_dir/alice" ]]; then
  echo "❌ Install: key file was written despite Kanidm lookup failure." >&2
  exit 1
fi

# --- Install: rejected (malformed username — before Kanidm) ---
expect_rc_one "malformed install username" bash "$install_exec" 'Bad-User!' <<<"$test_pub_key"

# --- Revoke: allowed (user exists in Kanidm) ---
printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
MOCK_EXPECT_LOCK=alice SFTP_TEST_DIR="$sftp_dir" MOCK_KANIDM_GROUP_FAIL=1 MOCK_KANIDM_PERSON_EXIST=1 \
  bash "$revoke_exec" alice "$test_fingerprint" >"$test_dir/revoke-allowed.log" 2>&1 \
  || { echo "❌ Revoke: existing user's key revocation failed." >&2; cat "$test_dir/revoke-allowed.log" >&2; exit 1; }
# Key should be removed (file may exist but be empty, or not exist).
if [[ -f "$alice_key_file" ]] && grep -qF "$test_pub_key" "$alice_key_file"; then
  echo "❌ Revoke: key was not removed for existing user." >&2
  exit 1
fi

# --- Revoke: rejected (nonexistent user) ---
printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
cp "$alice_key_file" "$test_dir/revoke-before"
expect_rc_one "revoke nonexistent target" env MOCK_KANIDM_PERSON_FAIL=1 bash "$revoke_exec" ghost "$test_fingerprint"
# The exact key-file bytes must remain unchanged.
if ! cmp -s "$test_dir/revoke-before" "$alice_key_file"; then
  echo "❌ Revoke: key file was modified for nonexistent user." >&2
  exit 1
fi

# --- Revoke: rejected (Kanidm lookup failure) ---
printf '%s\n' "$test_pub_key" >"$alice_key_file"
chmod 0644 "$alice_key_file"
cp "$alice_key_file" "$test_dir/revoke-before"
expect_rc_one "revoke Kanidm login failure" env MOCK_KANIDM_LOGIN_FAIL=1 bash "$revoke_exec" alice "$test_fingerprint"
if ! cmp -s "$test_dir/revoke-before" "$alice_key_file"; then
  echo "❌ Revoke: key file was modified despite Kanidm lookup failure." >&2
  exit 1
fi

# --- Revoke: rejected (malformed username — before Kanidm) ---
expect_rc_one "malformed revoke username" bash "$revoke_exec" 'Bad-User!' "$test_fingerprint"

echo "✅ SFTP key helper authorization tests passed."
