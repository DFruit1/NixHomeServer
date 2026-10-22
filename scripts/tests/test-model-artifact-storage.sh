#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools cmp diff find jq nix rsync

scratch="$(mktemp -d /tmp/nixhomeserver-model-storage-test.XXXXXX)"
cleanup() {
  local result=$?
  if ((result != 0)); then
    for log in "$scratch"/*.log; do
      [[ -f "$log" ]] && tail -40 "$log" >&2
    done
  fi
  rm -rf "$scratch"
  exit "$result"
}
trap cleanup EXIT
mkdir -p "$scratch/bin"
cat >"$scratch/bin/mountpoint" <<'SH'
#!/usr/bin/env bash
[[ "${MODEL_TEST_MOUNTED:-1}" == 1 ]]
SH
cat >"$scratch/bin/systemctl" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${MODEL_TEST_PRODUCER_STATE:-inactive}"
SH
make_test_executable "$scratch/bin/mountpoint" "$scratch/bin/systemctl"
export PATH="$scratch/bin:$PATH"

archive_case() {
  bash scripts/helpers/archive-bonsai-models.sh \
    "$scratch/$1/legacy" "$scratch/$1/data/bonsai/models" "$scratch/$1/data"
}
new_case() {
  mkdir -p "$scratch/$1/legacy/nested" "$scratch/$1/data"
  printf 'model weights\n' >"$scratch/$1/legacy/nested/model.gguf"
  printf 'partial download\n' >"$scratch/$1/legacy/model.gguf.part"
}

new_case migrate
cp -a "$scratch/migrate/legacy" "$scratch/expected"
archive_case migrate
[[ ! -e "$scratch/migrate/legacy" ]]
diff -r "$scratch/expected" "$scratch/migrate/data/bonsai/models"
archive_case migrate # Repeating a completed migration is harmless.

for failure in unmounted active activating reloading deactivating conflict symlink destination-symlink; do
  new_case "$failure"
  case "$failure" in
    unmounted) export MODEL_TEST_MOUNTED=0 ;;
    active|activating|reloading|deactivating) export MODEL_TEST_PRODUCER_STATE="$failure" ;;
    conflict)
      mkdir -p "$scratch/$failure/data/bonsai/models/nested"
      printf 'different existing weights\n' >"$scratch/$failure/data/bonsai/models/nested/model.gguf"
      ;;
    symlink) ln -s "$scratch/expected" "$scratch/$failure/legacy/linked" ;;
    destination-symlink)
      ln -s "$scratch/expected" "$scratch/$failure/data/bonsai"
      ;;
  esac
  if archive_case "$failure" >"$scratch/$failure/output" 2>&1; then
    echo "Model migration accepted unsafe case: $failure" >&2
    exit 1
  fi
  cmp "$scratch/expected/nested/model.gguf" "$scratch/$failure/legacy/nested/model.gguf"
  cmp "$scratch/expected/model.gguf.part" "$scratch/$failure/legacy/model.gguf.part"
  unset MODEL_TEST_MOUNTED MODEL_TEST_PRODUCER_STATE
done

new_case resume
mkdir -p "$scratch/resume/data/bonsai/models/nested"
cp "$scratch/resume/legacy/nested/model.gguf" "$scratch/resume/data/bonsai/models/nested/model.gguf"
printf 'retained archive\n' >"$scratch/resume/data/bonsai/models/older.gguf"
archive_case resume
[[ ! -e "$scratch/resume/legacy" ]]
[[ -f "$scratch/resume/data/bonsai/models/older.gguf" ]]
echo 'Model migration preserves content, rejects conflicts and is restartable.'

host="$(test_default_host)"
host_literal="$(printf '%s' "$host" | jq -Rs .)"
model_json="$(remote_eval_batch_json "models=
  let
    base = builtins.getAttr $host_literal f.nixosConfigurations;
    settings = builtins.getAttr $host_literal f.lib.nixhomeserverSettings;
    active = if base.config.nixhomeserver.modules.bonsai or false then base
      else base.extendModules { modules = [ ./modules/bonsai ]; };
    disabled = active.extendModules { modules = [
      ({ lib, ... }: { repo.bonsai.enable = lib.mkForce false; })
    ]; };
    c = active.config;
    d = disabled.config;
    archive = d.systemd.services.bonsai-model-archive;
  in {
    modelDir = c.repo.bonsai.paths.modelDir;
    expectedModelDir = settings.dataRoot + \"/bonsai/models\";
    prepareRequires = c.systemd.services.bonsai-model-prepare.requires;
    prepareWritable = c.systemd.services.bonsai-model-prepare.serviceConfig.ReadWritePaths;
    layoutRequires = c.systemd.services.bonsai-storage-layout.requires;
    archiveRequires = archive.requires;
    archiveCondition = archive.unitConfig.ConditionPathIsMountPoint;
    archiveMounts = archive.unitConfig.RequiresMountsFor;
    layoutMounts = c.systemd.services.bonsai-storage-layout.unitConfig.RequiresMountsFor;
    expectedMount = settings.dataRoot;
    archiveBefore = archive.before;
    archiveUser = archive.serviceConfig.User or \"root\";
    legacyExcluded = builtins.elem \"var/lib/bonsai/models\" d.repo.backups.rebuildableSnapshotPaths;
    metadataPersisted = builtins.elem \"/var/lib/bonsai\" d.repo.impermanence.inventory.persistenceDirectories;
    disabledProducerAbsent = !(d.systemd.services ? bonsai-model-prepare);
    archiveRetained = builtins.elem \"multi-user.target\" archive.wantedBy;
    policy = d.systemd.services.kopia-policy-reconcile.script;
  }
")"
jq -e '.models | .modelDir as $models |
  .modelDir == .expectedModelDir
  and (.prepareWritable | index($models) != null)
  and (.prepareRequires | index("bonsai-storage-layout.service") != null)
  and (.layoutRequires | index("bonsai-model-archive.service") != null)
  and (.archiveRequires | index("data-pool-layout.service") != null)
  and .archiveCondition == .expectedMount
  and (.expectedMount as $mount | .archiveMounts | index($mount) != null)
  and (.expectedMount as $mount | .layoutMounts | index($mount) != null)
  and (.archiveBefore | index("bonsai-model-prepare.service") != null)
  and .archiveUser == "root"
  and .legacyExcluded and .metadataPersisted
  and .disabledProducerAbsent and .archiveRetained
  and (.policy | contains("*.gguf") and contains("*.gguf.part"))
' <<<"$model_json" >/dev/null || {
  echo 'Model data-pool storage or disabled-module retention regressed.' >&2
  jq . <<<"$model_json" >&2
  exit 1
}
echo 'Enabled and disabled Bonsai storage, archive ordering and backup exclusions passed.'

# Use the pinned CLI and the generated policy commands in an isolated fixture
# repository. Both target-specific lists and global defaults must exclude models.
kopia_package="$(nix build --impure --no-link --print-out-paths --expr '
  let
    f = builtins.getFlake (builtins.getEnv "NIXHOMESERVER_FLAKE_REF_FOR_EVAL");
    settings = builtins.getAttr (builtins.head (builtins.attrNames f.lib.nixhomeserverSettings)) f.lib.nixhomeserverSettings;
  in f.inputs.nixpkgs.legacyPackages.${settings.hostPlatform}.kopia
')"
# The fixture is one behavioural block so both modes execute the same code. In
# strict mode Kopia was built on the server, so the block runs there against its
# own scratch space instead of realising or copying that output here.
model_artifact_kopia_behaviour() {
scratch="$(mktemp -d /tmp/nixhomeserver-model-kopia-test.XXXXXX)"
trap 'rm -rf -- "$scratch"' EXIT
kopia() {
  KOPIA_PASSWORD=public-fixture-only \
    KOPIA_CHECK_FOR_UPDATES=false \
    KOPIA_CONFIG_PATH="$scratch/kopia.config" \
    KOPIA_CACHE_DIRECTORY="$scratch/kopia-cache" \
    "$kopia_package/bin/kopia" --disable-file-logging --disable-content-log --no-persist-credentials "$@"
}
kopia repository create filesystem --path="$scratch/repository" >"$scratch/create.log" 2>&1
mkdir -p "$scratch/source-a/nested/deep" "$scratch/source-b/nested"
for root in source-a source-b; do
  printf 'metadata\n' >"$scratch/$root/state.json"
  printf 'weights\n' >"$scratch/$root/model.gguf"
  printf 'weights\n' >"$scratch/$root/nested/other.gguf"
  printf 'partial\n' >"$scratch/$root/nested/model.gguf.part"
done
policy_commands="$(jq -r .models.policy <<<"$model_json" | sed -n '/^kopia policy set --global/,$p')"
policy_commands="${policy_commands//policy set \/persist/policy set \"$scratch\/source-a\"}"
eval "$policy_commands" >"$scratch/policy.log" 2>&1
kopia snapshot create --no-progress "$scratch/source-a" "$scratch/source-b" >"$scratch/snapshot.log" 2>&1
kopia snapshot list --all --json >"$scratch/snapshots.json"
jq -e '
  length == 2 and all(.[]; .rootEntry.summ.size == 9 and .stats.excludedFileCount == 3)
' "$scratch/snapshots.json" >/dev/null || {
  jq '[.[] | {source: .source.path, size: .rootEntry.summ.size, stats}]' "$scratch/snapshots.json" >&2
  exit 1
}
echo 'Real Kopia snapshots exclude nested GGUF/partial files from both roots and retain metadata.'
}

if strict_remote_enabled; then
  remote_run 'set -euo pipefail
tree="$1"; shift
kopia_package="$1"; shift
model_json="$1"; shift
cd "$tree"
eval "$1"
model_artifact_kopia_behaviour' "$kopia_package" "$model_json" "$(declare -f model_artifact_kopia_behaviour)"
else
  model_artifact_kopia_behaviour
fi
