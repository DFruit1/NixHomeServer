#!/usr/bin/env bash
# Recovered from unfinished t_950519d0/t_bb9d1c10 coverage, adapted to NSS.
# Security/data-preservation risk: an unauthorized reusable SFTP key can expose
# user data; identity-dependent revocation can leave offboarded credentials in
# place. Check that denials preserve files and revocation preserves other keys.
# Local template fixtures only; no system evaluation, sudo or real credentials.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
for tool in bash python3 ssh-keygen flock grep sed id install chown stat mktemp cat tr chmod mv rm printf cut cmp; do
  type -P "$tool" >/dev/null || { echo "missing tool: $tool" >&2; exit 1; }
done

test_dir="$(mktemp -d /tmp/sftp-key-authorization.XXXXXX)"
trap 'rm -rf -- "$test_dir"' EXIT
export TMPDIR="$test_dir"
export SFTP_TEST_DIR="$test_dir/keys"
export SFTP_TEST_ID_LOG="$test_dir/id.log"
mkdir -p "$SFTP_TEST_DIR" "$test_dir/util/bin"

# Use real utilities except privilege-sensitive ownership operations and NSS.
for tool in id install chown stat mktemp cat tr chmod mv rm printf cut; do
  ln -s "$(type -P "$tool")" "$test_dir/util/bin/$tool"
done
for tool in id install chown stat; do
  rm "$test_dir/util/bin/$tool"
done

write_mock() {
  printf '#!%s\n' "$(type -P bash)" > "$test_dir/util/bin/$1"
  cat >> "$test_dir/util/bin/$1"
  chmod +x "$test_dir/util/bin/$1"
}
write_mock id <<'MOCK'
set -euo pipefail
printf '%s\n' "$*" >> "$SFTP_TEST_ID_LOG"
[[ "$#" == 3 && "$1" == '-Gn' && "$2" == '--' ]] || exit 96
# The helper must hold its per-target lock while resolving eligibility.
if flock -n "$SFTP_TEST_DIR/.$3.lock" -c true; then
  echo 'NSS lookup without per-target lock' >&2
  exit 97
fi
printf '%s\n' "${MOCK_NSS_GROUPS:-users}"
exit "${MOCK_NSS_STATUS:-0}"
MOCK
write_mock install <<'MOCK'
set -euo pipefail
[[ "$#" == 8 && "$*" == "-d -m 0755 -o root -g root $SFTP_TEST_DIR" ]] || exit 96
mkdir -p "$SFTP_TEST_DIR"
MOCK
write_mock chown <<'MOCK'
set -euo pipefail
[[ "$#" == 2 && "$1" == 'root:root' && -f "$2" ]] || exit 96
MOCK
printf '#!%s\nreal_stat=%q\n' "$(type -P bash)" "$(type -P stat)" > "$test_dir/util/bin/stat"
cat >> "$test_dir/util/bin/stat" <<'MOCK'
set -euo pipefail
if [[ "$1" == '-c' && "$2" == '%U:%G' ]]; then
  printf '%s\n' "${MOCK_OWNER_GROUP:-root:root}"
else
  exec "$real_stat" "$@"
fi
MOCK
chmod +x "$test_dir/util/bin/stat"

# Render the exact owned template text. The coordinator supplies the matching
# sshd AllowGroups binding in services.nix; this fixture covers all name forms.
python3 - "$repo_root" "$test_dir" <<'PY'
from pathlib import Path
import re
import shlex
import shutil
import sys

repo, scratch = map(Path, sys.argv[1:])
parameters = {
    'COREUTILS': str(scratch / 'util'),
    'SFTPAUTHORIZEDKEYSDIR': str(scratch / 'keys'),
    'SFTPAUTHORIZEDKEYSDIR_QUOTED': shlex.quote(str(scratch / 'keys')),
    'SFTPAUTHORIZEDKEYSDIR_SERVICEUSER_XXXXXX_QUOTED': shlex.quote(str(scratch / 'keys/.homepage.XXXXXX')),
    'SFTP_UNIX_GROUPS': ' '.join(map(shlex.quote, [
        'files-personal-users', 'files-sftp-users', 'files-shared-users',
        'usb-access', 'backup-storage-users', 'files-personal-users@example.test',
        'files-sftp-users@example.test', 'files-shared-users@example.test',
        'usb-access@example.test', 'backup-storage-users@example.test',
        'files-local-sftp-users',
    ])),
}
binary_tokens = {
    '@NIX_' + label + '@/bin/' + binary: shutil.which(binary)
    for label, binary in [('GNUGREP', 'grep'), ('GNUSED', 'sed'), ('OPENSSH', 'ssh-keygen'), ('UTIL_LINUX', 'flock')]
}
for operation in ['install', 'revoke']:
    text = (repo / f'custom_apps/shell/homepage/homepage-{operation}-sftp-key.sh.in').read_text()
    # Guard the credential boundary without requiring external Kanidm access.
    assert not re.search(r'KANIDM|agenix|idm_admin', text), 'unexpected administrative credential dependency'
    # Different utilities can live under different package prefixes on NixOS.
    for token, value in binary_tokens.items():
        text = text.replace(token, value)
    for name, value in parameters.items():
        text = text.replace('@NIX_' + name + '@', value)
    assert not re.search(r'@NIX_[A-Z0-9_]+@', text), 'unresolved template parameter'
    (scratch / operation).write_text(text)
PY

ssh-keygen -q -t ed25519 -N '' -f "$test_dir/key-one"
ssh-keygen -q -t ed25519 -N '' -f "$test_dir/key-two"
public_key="$(cat "$test_dir/key-one.pub")"
other_key="$(cat "$test_dir/key-two.pub")"
fingerprint="$(ssh-keygen -lf "$test_dir/key-one.pub" | cut -d ' ' -f 2)"

run_install() { bash "$test_dir/install" "$1" <<< "$public_key"; }
run_revoke() { bash "$test_dir/revoke" "$1" "${2:-$fingerprint}"; }
expect_failure() {
  local status=0 label="$1"
  shift
  "$@" > "$test_dir/rejected.log" 2>&1 || status=$?
  if [[ "$status" != 1 ]]; then
    cat "$test_dir/rejected.log" >&2
    echo "$label: expected exit 1, got $status" >&2
    exit 1
  fi
  printf 'ok - %s\n' "$label"
}

# Every SFTP role, its realm alias, and the local bridge permit installation.
for group in files-personal-users files-sftp-users files-shared-users usb-access backup-storage-users \
    files-personal-users@example.test files-sftp-users@example.test files-shared-users@example.test \
    usb-access@example.test backup-storage-users@example.test files-local-sftp-users; do
  rm -f "$SFTP_TEST_DIR/alice"
  MOCK_NSS_GROUPS="users $group unrelated" run_install alice > "$test_dir/allowed.log"
  [[ "$(cat "$SFTP_TEST_DIR/alice")" == "$public_key" ]]
  [[ "$(cat "$test_dir/allowed.log")" == "saved $SFTP_TEST_DIR/alice owner=root:root mode=644 registered-keys=1" ]]
done
printf 'ok - every allowed group, realm alias and local bridge installs under lock\n'

# Idempotent enrollment and enrollment from multiple device keys preserve data.
MOCK_NSS_GROUPS=files-sftp-users run_install alice > /dev/null
[[ "$(cat "$SFTP_TEST_DIR/alice")" == "$public_key" ]]
printf '%s\n' "$other_key" > "$SFTP_TEST_DIR/alice"
MOCK_NSS_GROUPS=files-sftp-users run_install alice > /dev/null
printf '%s\n' "$other_key" "$public_key" > "$test_dir/both"
cmp "$test_dir/both" "$SFTP_TEST_DIR/alice"
printf 'ok - duplicate and additional enrollment preserve registered keys\n'

# Denials must leave existing files byte-for-byte intact, and create no file
# for absent targets. A failed id may print a partial allowed group: fail closed.
for group in users prefix-files-sftp-users files-sftp-users-suffix files-sftp-users@other.test; do
  expect_failure "ineligible install ($group)" env MOCK_NSS_GROUPS="$group" bash "$test_dir/install" alice <<< "$public_key"
  cmp "$test_dir/both" "$SFTP_TEST_DIR/alice"
done
expect_failure 'NSS failure with partial eligible output' env MOCK_NSS_STATUS=1 MOCK_NSS_GROUPS=files-sftp-users bash "$test_dir/install" alice <<< "$public_key"
cmp "$test_dir/both" "$SFTP_TEST_DIR/alice"
expect_failure 'absent NSS target' env MOCK_NSS_STATUS=1 bash "$test_dir/install" ghost <<< "$public_key"
[[ ! -e "$SFTP_TEST_DIR/ghost" ]]
cp "$SFTP_TEST_ID_LOG" "$test_dir/id-before"
expect_failure 'malformed install target' run_install '../alice'
cmp "$test_dir/id-before" "$SFTP_TEST_ID_LOG"

# Revocation is intentionally independent of NSS, including missing identities
# and outage. It removes only the selected device key, retaining the other key.
for target in alice deleted; do
  cp "$test_dir/both" "$SFTP_TEST_DIR/$target"
  chmod 0644 "$SFTP_TEST_DIR/$target"
  MOCK_NSS_STATUS=1 run_revoke "$target" > "$test_dir/revoked.log"
  [[ "$(cat "$SFTP_TEST_DIR/$target")" == "$other_key" ]]
  [[ "$(cat "$test_dir/revoked.log")" == "revoked 1 key(s) for $target" ]]
done
cmp "$test_dir/id-before" "$SFTP_TEST_ID_LOG"
printf 'ok - offboarding revokes after identity removal or NSS outage, preserving other keys\n'

cp "$SFTP_TEST_DIR/alice" "$test_dir/revoke-before"
expect_failure 'unregistered fingerprint' run_revoke alice
cmp "$test_dir/revoke-before" "$SFTP_TEST_DIR/alice"
expect_failure 'missing key file' run_revoke ghost
expect_failure 'malformed revoke target' run_revoke '../alice'
expect_failure 'malformed fingerprint' run_revoke alice 'bad-fingerprint'

# Existing file safety checks must continue to protect unrelated data.
ln -s "$SFTP_TEST_DIR/alice" "$SFTP_TEST_DIR/symlink"
expect_failure 'symlink install' env MOCK_NSS_GROUPS=files-sftp-users bash "$test_dir/install" symlink <<< "$public_key"
expect_failure 'symlink revoke' run_revoke symlink
expect_failure 'unsafe-owner install' env MOCK_OWNER_GROUP=homepage:homepage MOCK_NSS_GROUPS=files-sftp-users bash "$test_dir/install" alice <<< "$public_key"
expect_failure 'unsafe-owner revoke' env MOCK_OWNER_GROUP=homepage:homepage bash "$test_dir/revoke" alice "$fingerprint"
chmod 0600 "$SFTP_TEST_DIR/alice"
expect_failure 'unsafe-mode install' env MOCK_NSS_GROUPS=files-sftp-users bash "$test_dir/install" alice <<< "$public_key"
expect_failure 'unsafe-mode revoke' run_revoke alice
cmp "$test_dir/revoke-before" "$SFTP_TEST_DIR/alice"
printf 'SFTP key authorization fixtures passed.\n'
