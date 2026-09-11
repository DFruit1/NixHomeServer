#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools age age-keygen git jq mktemp nix openssl python3 rg sed

tmpdir="$(mktemp -d)"
cleanup() { rm -rf "$tmpdir"; }
trap cleanup EXIT

fixture="$tmpdir/repo"
mkdir -p "$fixture/secrets" "$fixture/scripts/admin" "$fixture/scripts/helpers"

# Copy the helper script and everything its phases invoke so the fixture
# behaves like a real checkout.
fixture_files=(
  scripts/admin/bootstrap-host.sh
  scripts/admin/common.sh
  scripts/admin/seed-install-repository.sh
  scripts/generate-all-secrets.sh
  scripts/helpers/repo-common.sh
  scripts/helpers/secrets-common.sh
  scripts/helpers/generate-managed-secrets.sh
  scripts/helpers/encrypt-staged-external-secrets.sh
  scripts/helpers/verify-zfs-pool-identity.sh
  vars.example.nix
  secrets/manifest.nix
  lib/derive-vars.nix
  lib/merge-ports.nix
  modules/catalog.nix
  lib/authorization-groups.nix
  lib/identity-access.nix
  lib/identity-validation.nix
  lib/name-validation.nix
  lib/file-access-gids.nix
  lib/backup-access.nix
)
for registration in "$TESTS_REPO_ROOT"/modules/*/registration.nix; do
  fixture_files+=("${registration#"$TESTS_REPO_ROOT"/}")
done
for fixture_file in "${fixture_files[@]}"; do
  mkdir -p "$fixture/$(dirname "$fixture_file")"
  cp "$TESTS_REPO_ROOT/$fixture_file" "$fixture/$fixture_file"
done

# Keep installed-system markers inside the fixture. In particular, first-boot
# refusal tests must never inspect or reconcile the actual server's checkout.
python3 - "$fixture/scripts/admin/bootstrap-host.sh" "$tmpdir/absent-installation" <<'PYTHON'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
for marker in ["/persist/etc/nixos", "/run/agenix"]:
    source = source.replace(marker, sys.argv[2] + marker)
path.write_text(source)
PYTHON

# A minimal offline flake so the phases that read evaluated settings work in
# the fixture exactly as they do in a real checkout. The nixpkgs input pins the
# revision locked by this repository's own flake.lock so it resolves from the
# local Nix cache without network access; a path input into this repository
# would copy gitignored build trees into the store.
nixpkgs_rev="$(jq -r '.nodes.nixpkgs.locked.rev' "$TESTS_REPO_ROOT/flake.lock")"
cat >"$fixture/flake.nix" <<EOF
{
  inputs.nixpkgs.url = "github:NixOS/nixpkgs/$nixpkgs_rev";
  outputs = { self, nixpkgs }: {
    lib.nixhomeserverSettings."example-server" =
      import ./vars.nix { lib = nixpkgs.lib; };
  };
}
EOF

git -C "$fixture" init -q
git -C "$fixture" config user.email bootstrap@example.test
git -C "$fixture" config user.name "Bootstrap Fixture"
printf '%s\n' \
  '/secrets/*' \
  '!/secrets/*.age' \
  '!/secrets/manifest.nix' \
  '!/secrets/pubkeys/' \
  '!/secrets/pubkeys/age.pub' \
  '/secrets/unencrypted/' \
  '/SensitivePrivateSecrets' \
  >"$fixture/.gitignore"
git -C "$fixture" add -A
git -C "$fixture" commit -qm 'fixture base'

run_phase() {
  local log="$1"
  shift
  (cd "$fixture" && NIXHOMESERVER_REPO_ROOT="$fixture" \
    bash "$fixture/scripts/admin/bootstrap-host.sh" "$@") >"$log" 2>&1
}

# --- init: seeds vars.nix, fills the hostId placeholder, and is idempotent.
if ! run_phase "$tmpdir/init1.log" init; then
  echo "❌ bootstrap init failed."
  cat "$tmpdir/init1.log"
  exit 1
fi
[[ -f "$fixture/vars.nix" ]] || {
  echo "❌ init did not seed vars.nix."
  exit 1
}
host_id="$(sed -n 's/^[[:space:]]*hostId[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$fixture/vars.nix")"
[[ "$host_id" =~ ^[0-9a-f]{8}$ && "$host_id" != "00000000" ]] || {
  echo "❌ init did not generate a real hostId: $host_id"
  cat "$tmpdir/init1.log"
  exit 1
}
if ! run_phase "$tmpdir/init2.log" init; then
  echo "❌ bootstrap init rerun failed."
  cat "$tmpdir/init2.log"
  exit 1
fi
host_id_rerun="$(sed -n 's/^[[:space:]]*hostId[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "$fixture/vars.nix")"
[[ "$host_id_rerun" == "$host_id" ]] || {
  echo "❌ init rerun regenerated the hostId instead of converging."
  exit 1
}
rg -Fq 'already converged: hostId is set or not required' "$tmpdir/init2.log" || {
  echo "❌ init rerun did not report convergence."
  cat "$tmpdir/init2.log"
  exit 1
}

# Commit the seeded settings so flake evaluation sees them, as the real
# checkpoint step requires before any evaluated phase.
git -C "$fixture" add vars.nix
git -C "$fixture" commit -qm 'seed vars'

# --- check: always exits 0 and prints a next command.
if ! run_phase "$tmpdir/check1.log" check; then
  echo "❌ bootstrap check failed."
  cat "$tmpdir/check1.log"
  exit 1
fi
rg -Fq 'next:' "$tmpdir/check1.log" || {
  echo "❌ check did not print a next command."
  cat "$tmpdir/check1.log"
  exit 1
}
rg -Fq 'template values remain' "$tmpdir/check1.log" || {
  echo "❌ check did not flag the remaining template values."
  cat "$tmpdir/check1.log"
  exit 1
}

# --- identity: create, converge, refuse a mismatched key.
if ! run_phase "$tmpdir/identity1.log" identity --create "$tmpdir/fixture.age.key"; then
  echo "❌ bootstrap identity creation failed."
  cat "$tmpdir/identity1.log"
  exit 1
fi
[[ -f "$tmpdir/fixture.age.key" && -s "$fixture/secrets/pubkeys/age.pub" ]] || {
  echo "❌ identity creation did not produce a key and recipient."
  exit 1
}
[[ "$(stat -c '%a' "$tmpdir/fixture.age.key")" == "400" ]] || {
  echo "❌ the created private key is not mode 0400."
  exit 1
}
if ! run_phase "$tmpdir/identity2.log" identity --identity "$tmpdir/fixture.age.key"; then
  echo "❌ identity verification rerun failed."
  cat "$tmpdir/identity2.log"
  exit 1
fi
rg -Fq 'already converged' "$tmpdir/identity2.log" || {
  echo "❌ identity verification rerun did not converge."
  cat "$tmpdir/identity2.log"
  exit 1
}
age-keygen -o "$tmpdir/other.age.key" >/dev/null 2>&1
if run_phase "$tmpdir/identity3.log" identity --identity "$tmpdir/other.age.key"; then
  echo "❌ identity accepted a mismatched key."
  exit 1
fi
rg -q 'does not match' "$tmpdir/identity3.log" || {
  echo "❌ mismatched-key refusal was not reported."
  cat "$tmpdir/identity3.log"
  exit 1
}
if run_phase "$tmpdir/identity4.log" identity --create "$tmpdir/another.age.key"; then
  echo "❌ identity replaced a configured recipient via --create."
  exit 1
fi
rg -q 'refusing to replace' "$tmpdir/identity4.log" || {
  echo "❌ recipient-replacement refusal was not reported."
  cat "$tmpdir/identity4.log"
  exit 1
}

# --- secrets: refuses to prompt on a non-interactive terminal, encrypts staged
# values, converges without regenerating, and cleans its staging.
unset NIXHOMESERVER_AGE_IDENTITY_FILE
if run_phase "$tmpdir/secrets1.log" secrets --identity "$tmpdir/fixture.age.key" </dev/null; then
  echo "❌ secrets prompted on a non-interactive terminal."
  cat "$tmpdir/secrets1.log"
  exit 1
fi
rg -q 'not interactive' "$tmpdir/secrets1.log" || {
  echo "❌ the non-interactive refusal was not reported."
  cat "$tmpdir/secrets1.log"
  exit 1
}
rg -Fq 'secrets/unencrypted/cfAPIToken' "$tmpdir/secrets1.log" || {
  echo "❌ the non-interactive refusal did not list the staging path."
  cat "$tmpdir/secrets1.log"
  exit 1
}

install -d -m 0700 "$fixture/secrets/unencrypted"
printf 'bootstrap-netbird-setup-key-0123456789' >"$fixture/secrets/unencrypted/netbirdSetupKey"
printf '{"AccountTag":"a","TunnelID":"b","TunnelSecret":"c"}' >"$fixture/secrets/unencrypted/cfHomeCreds"
printf 'cloudflare-api-token-0123456789abcdef' >"$fixture/secrets/unencrypted/cfAPIToken"
if ! run_phase "$tmpdir/secrets2.log" secrets --identity "$tmpdir/fixture.age.key" </dev/null; then
  echo "❌ secrets generation from staged values failed."
  cat "$tmpdir/secrets2.log"
  exit 1
fi
[[ -s "$fixture/secrets/netbirdSetupKey.age" && -s "$fixture/secrets/kanidmAdminPass.age" ]] || {
  echo "❌ secrets generation did not produce ciphertext."
  cat "$tmpdir/secrets2.log"
  exit 1
}
age --decrypt -i "$tmpdir/fixture.age.key" -o "$tmpdir/netbird.roundtrip" "$fixture/secrets/netbirdSetupKey.age"
[[ "$(cat "$tmpdir/netbird.roundtrip")" == "bootstrap-netbird-setup-key-0123456789" ]] || {
  echo "❌ the staged external value was not encrypted faithfully."
  exit 1
}
[[ -z "$(find "$fixture/secrets/unencrypted" -mindepth 1 -print -quit 2>/dev/null)" ]] || {
  echo "❌ the secrets phase left plaintext staging behind."
  find "$fixture/secrets/unencrypted"
  exit 1
}
age --decrypt -i "$tmpdir/fixture.age.key" -o "$tmpdir/kanidm.before" "$fixture/secrets/kanidmAdminPass.age"
if ! run_phase "$tmpdir/secrets3.log" secrets --identity "$tmpdir/fixture.age.key" </dev/null; then
  echo "❌ secrets convergence rerun failed."
  cat "$tmpdir/secrets3.log"
  exit 1
fi
rg -Fq 'already converged: every required secret decrypts' "$tmpdir/secrets3.log" || {
  echo "❌ secrets rerun did not report convergence."
  cat "$tmpdir/secrets3.log"
  exit 1
}
age --decrypt -i "$tmpdir/fixture.age.key" -o "$tmpdir/kanidm.after" "$fixture/secrets/kanidmAdminPass.age"
cmp -s "$tmpdir/kanidm.before" "$tmpdir/kanidm.after" || {
  echo "❌ the converged rerun regenerated secret values."
  exit 1
}

# --- pin-guid: unavailable ZFS tools must refuse even on a ZFS-capable test host.
# Stub discovery for this case so the fixture never inspects the host's pool.
if (
  # shellcheck disable=SC2329 # Invoked indirectly by the fixture subprocess.
  command() {
    if [[ "${1:-}" == -v && "${2:-}" == zpool ]]; then
      return 1
    fi
    builtin command "$@"
  }
  export -f command
  run_phase "$tmpdir/guid1.log" pin-guid
); then
  echo "❌ pin-guid ran without a ZFS pool."
  cat "$tmpdir/guid1.log"
  exit 1
fi
rg -q 'zpool is not available' "$tmpdir/guid1.log" || {
  echo "❌ the missing-pool refusal was not reported."
  cat "$tmpdir/guid1.log"
  exit 1
}
sed -i 's/profile = "zfs-mirror"/profile = "single-disk-ext4"/' "$fixture/vars.nix"
if ! run_phase "$tmpdir/guid2.log" pin-guid; then
  echo "❌ pin-guid failed on the ext4 profile."
  cat "$tmpdir/guid2.log"
  exit 1
fi
rg -Fq 'already converged: storage profile' "$tmpdir/guid2.log" || {
  echo "❌ pin-guid did not report not-applicable convergence on ext4."
  cat "$tmpdir/guid2.log"
  exit 1
}
sed -i 's/profile = "single-disk-ext4"/profile = "zfs-mirror"/' "$fixture/vars.nix"

# --- install and first-boot: environment refusals.
if (
  # shellcheck disable=SC2329 # Invoked indirectly by the fixture subprocess.
  id() {
    if [[ "${1:-}" == -u ]]; then
      printf '1000\n'
      return 0
    fi
    command id "$@"
  }
  export -f id
  run_phase "$tmpdir/install1.log" install
); then
  echo "❌ install ran without root."
  cat "$tmpdir/install1.log"
  exit 1
fi
rg -q 'runs as root' "$tmpdir/install1.log" || {
  echo "❌ the non-root install refusal was not reported."
  cat "$tmpdir/install1.log"
  exit 1
}
if run_phase "$tmpdir/boot1.log" first-boot; then
  echo "❌ first-boot ran off the installed system."
  cat "$tmpdir/boot1.log"
  exit 1
fi
rg -q 'runs on the installed system' "$tmpdir/boot1.log" || {
  echo "❌ the off-server first-boot refusal was not reported."
  cat "$tmpdir/boot1.log"
  exit 1
}

# The helper must keep advertising its policy surface so the documented
# workflow cannot silently drift from the implemented behavior.
require_fixed scripts/admin/bootstrap-host.sh 'already converged' \
  'the bootstrap helper reports idempotent convergence'
require_fixed scripts/admin/bootstrap-host.sh 'next:' \
  'the bootstrap helper always prints the next operator step'
require_fixed scripts/admin/bootstrap-host.sh 'not interactive' \
  'the bootstrap helper refuses secret prompts without a terminal'
rg -Fq 'scripts/admin/bootstrap-host.sh' documentation/quickstart.md || {
  echo "❌ quickstart.md does not document the guided bootstrap helper."
  exit 1
}

echo "✅ Guided bootstrap phase tests passed."
