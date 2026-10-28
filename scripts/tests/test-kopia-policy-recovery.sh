#!/usr/bin/env bash
set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
source "$TESTS_REPO_ROOT/scripts/helpers/repo-common.sh"
cd "$TESTS_REPO_ROOT"
init_repo_root
ensure_default_nix_config
ensure_tools nix jq python3 flock

# Reuse the pinned binary without building a system or touching a real repository.
kopia_bin="$(nix_flake_var '"${flake.inputs.nixpkgs.legacyPackages.${vars.hostPlatform}.kopia}/bin/kopia"')"
[[ -x "$kopia_bin" ]] || { echo "Realize the pinned Kopia package before this focused check." >&2; exit 1; }
kopia() { "$kopia_bin" "$@" --disable-file-logging; }

scratch="$(mktemp -d "${TMPDIR:-/tmp}/kopia-policy-recovery.XXXXXX")"
trap 'rm -rf -- "$scratch"' EXIT
export NIXHOMESERVER_KOPIA_FIXTURE_ROOT="$scratch"

# Evaluate only this module's actual policy script, with isolated storage and lock
# bindings. No full NixOS configuration, build, credentials or server are needed.
nix_flake_var '
  let
    root = builtins.getEnv "NIXHOMESERVER_KOPIA_FIXTURE_ROOT";
    module = import (builtins.toPath (repoPath + "/modules/Core_Modules/kopia/service.nix")) {
      inherit lib;
      pkgs = {};
      oauth2Proxy = {};
      vars.dataRootIsMountPoint = false;
      config.repo.backups = {
        maintenanceLock = root + "/maintenance.lock";
        rebuildableSnapshotPaths = [];
      };
    };
  in (builtins.head module.config.contents).systemd.services.kopia-policy-reconcile.script
' > "$scratch/policy.sh"
python3 - "$scratch" <<'PY'
from pathlib import Path
import sys

root = Path(sys.argv[1])
script = root / 'policy.sh'
script.write_text(script.read_text().replace('/persist', str(root / 'persist')))
persist = root / 'persist'
generation = persist / 'appdata/backup-metadata/generations/generation-1'
(generation / 'dumps').mkdir(parents=True)
(generation / 'metadata').mkdir()
dump = generation / 'dumps/postgresql.sql'
with dump.open('wb') as output:
    output.write(b'-- Synthetic PostgreSQL dump\nCREATE TABLE fixture (id integer);\n')
    padding = b'-- fixture padding\n' * 65536
    while output.tell() <= 101 * 1024 * 1024:
        output.write(padding)
(generation / 'dumps/kanidm.sqlite').write_bytes(b'SQLite format 3\0synthetic backup fixture')
(generation / 'metadata/manifest.json').write_text('{"fixture":true}\n')
(persist / 'appdata/backup-metadata/current').symlink_to('generations/generation-1')
pending = generation.parent / '.prepare.inflight/dumps'
pending.mkdir(parents=True)
(pending / 'unpublished.sql').write_text('unfinished fixture')
postgres = persist / 'var/lib/postgresql'
postgres.mkdir(parents=True)
(postgres / 'raw-state').write_text('inconsistent raw database fixture')
(persist / 'model.gguf').write_text('reproducible model fixture')
paperless = root / 'paperless'
paperless.mkdir()
with (paperless / 'large-document.pdf').open('wb') as output:
    output.write(b'%PDF-1.7\nsynthetic document bytes\n')
    output.truncate(101 * 1024 * 1024)
(paperless / 'model.gguf').write_text('reproducible model fixture')
PY
persist="$scratch/persist"
generation="appdata/backup-metadata/generations/generation-1"
(cd "$persist/$generation" && sha256sum dumps/* > metadata/SHA256SUMS)
mkdir -p "$persist/appdata/kopia/cache" "$scratch/credentials" "$scratch/logs"
export CREDENTIALS_DIRECTORY="$scratch/credentials"
printf 'synthetic-policy-fixture\n' > "$CREDENTIALS_DIRECTORY/kopia-server-password"
export KOPIA_PASSWORD=synthetic-policy-fixture
export KOPIA_CONFIG_PATH="$persist/appdata/kopia/repository.config"
export KOPIA_CACHE_DIRECTORY="$persist/appdata/kopia/cache"
export KOPIA_LOG_DIR="$scratch/logs"
export KOPIA_CHECK_FOR_UPDATES=false KOPIA_PERSIST_CREDENTIALS_ON_CONNECT=false
kopia repository create filesystem --path "$scratch/repository" --no-persist-credentials >/dev/null

# Reconciliation must also repair previously saved exclusions and size limits.
kopia policy set --global --max-file-size=104857600 >/dev/null
kopia policy set "$persist" --max-file-size=104857600 \
  --add-ignore=appdata/backup-metadata >/dev/null
export -f kopia
export kopia_bin
bash "$scratch/policy.sh"
# An unchanged repeat must converge and keep the repaired policy intact.
bash "$scratch/policy.sh"

for source_root in "$persist" "$scratch/paperless"; do
  kopia snapshot create "$source_root" --no-progress >/dev/null
  kopia snapshot list "$source_root" --json > "$scratch/$(basename "$source_root").json"
done
kopia repository disconnect >/dev/null
rm -f -- "$KOPIA_CONFIG_PATH"
rm -rf -- "$KOPIA_CACHE_DIRECTORY"
mkdir -p "$KOPIA_CACHE_DIRECTORY"
kopia repository connect filesystem --path "$scratch/repository" --no-persist-credentials >/dev/null
for label in persist paperless; do
  object="$(jq -er '.[0].rootEntry.obj' "$scratch/$label.json")"
  kopia snapshot restore "$object" "$scratch/restored-$label" --no-progress >/dev/null
done
for file in dumps/postgresql.sql dumps/kanidm.sqlite metadata/manifest.json metadata/SHA256SUMS; do
  cmp "$persist/$generation/$file" "$scratch/restored-persist/$generation/$file"
done
(cd "$scratch/restored-persist/$generation" && sha256sum --check metadata/SHA256SUMS)
[[ "$(readlink "$scratch/restored-persist/appdata/backup-metadata/current")" == generations/generation-1 ]]
cmp "$scratch/paperless/large-document.pdf" "$scratch/restored-paperless/large-document.pdf"
[[ ! -e "$scratch/restored-persist/appdata/backup-metadata/generations/.prepare.inflight" ]]
[[ ! -e "$scratch/restored-persist/var/lib/postgresql" ]]
[[ ! -e "$scratch/restored-persist/model.gguf" ]]
[[ ! -e "$scratch/restored-paperless/model.gguf" ]]
echo 'Kopia policy restores successful logical dumps and documents above 100 MiB.'
