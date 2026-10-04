#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
ensure_tools jq nix
host="$(test_default_host)"
if [[ "$(flake_eval_json "in builtins.elem \"langfuse\" (builtins.getAttr \"$host\" f.lib.nixhomeserverSettings).enabledApps")" != true ]]; then
  echo 'Langfuse is disabled; skipping its enabled-module contract.'
  exit 0
fi
value="$(flake_eval_json "
  cfg = (builtins.getAttr \"$host\" f.nixosConfigurations).config;
  vars = builtins.getAttr \"$host\" f.lib.nixhomeserverSettings;
  app = cfg.repo.authGateway.protectedApps.langfuse;
  containers = cfg.virtualisation.oci-containers.containers;
in {
  drvPath = cfg.system.build.toplevel.drvPath;
  database = builtins.elem \"langfuse\" cfg.services.postgresql.ensureDatabases;
  redis = cfg.services.redis.servers.langfuse;
  clickhouse = cfg.services.clickhouse.serverConfig;
  bootstrapAfter = cfg.systemd.services.langfuse-db-bootstrap.after;
  bootstrapRequires = cfg.systemd.services.langfuse-db-bootstrap.requires;
  minioArgs = containers.langfuse-minio.cmd;
  nativeAuthPaths = app.nativeAuthPaths;
  allowedGroups = app.allowedGroups;
  privateDns = cfg.services.unbound.privateHosts.\"langfuse.\${vars.domain}\".target;
  publicRoute = builtins.hasAttr \"langfuse.\${vars.domain}\" (builtins.head (builtins.attrValues cfg.services.cloudflared.tunnels)).ingress;
  images = map (name: containers.\${name}.image) [ \"langfuse-web\" \"langfuse-worker\" ];
  networks = map (name: containers.\${name}.networks) [ \"langfuse-web\" \"langfuse-worker\" ];
  ownerEmail = containers.langfuse-web.environment.LANGFUSE_INIT_USER_EMAIL;
  secretMode = cfg.age.secrets.langfuseServerEnv.mode;
  persistence = cfg.repo.impermanence.inventory.persistenceDirectories;
  dump = builtins.filter (item: item.database == \"langfuse\") cfg.repo.backups.postgresqlDumps;
  clickhouseBackup = builtins.hasAttr \"langfuse\" cfg.repo.backups.prepareFragments;
  restart = cfg.systemd.services.clickhouse.serviceConfig.Restart;
  restartSec = cfg.systemd.services.clickhouse.serviceConfig.RestartSec;
  interval = cfg.systemd.services.clickhouse.unitConfig.StartLimitIntervalSec;
  burst = cfg.systemd.services.clickhouse.unitConfig.StartLimitBurst;
  onFailure = cfg.systemd.services.clickhouse.unitConfig.OnFailure;
  redisRestart = cfg.systemd.services.redis-langfuse.serviceConfig.Restart;
  redisRestartSec = cfg.systemd.services.redis-langfuse.serviceConfig.RestartSec;
  redisInterval = cfg.systemd.services.redis-langfuse.unitConfig.StartLimitIntervalSec;
  redisBurst = cfg.systemd.services.redis-langfuse.unitConfig.StartLimitBurst;
  redisOnFailure = cfg.systemd.services.redis-langfuse.unitConfig.OnFailure;
  unitOnFailure = map (name: cfg.systemd.services.\${name}.unitConfig.OnFailure)
    [ \"langfuse-prepare\" \"langfuse-db-bootstrap\" \"langfuse-web\" \"langfuse-worker\" \"langfuse-minio\" ];
  prepareTriggers = cfg.systemd.services.langfuse-prepare.restartTriggers;
  bootstrapTriggers = cfg.systemd.services.langfuse-db-bootstrap.restartTriggers;
  containerOptions = map (name: containers.\${name}.extraOptions)
    [ \"langfuse-web\" \"langfuse-worker\" \"langfuse-minio\" ];
  postgresTimezone = cfg.services.postgresql.settings.timezone or null;
  rebuildable = cfg.repo.backups.rebuildableSnapshotPaths;
  currentGenerationPath = cfg.repo.backups.successfulCurrentPath;
  fragment = cfg.repo.backups.prepareFragments.langfuse or \"\";
  seedScript = cfg.system.activationScripts.seedCorePersistence.text;
}")"
jq -e '
  (.drvPath | startswith("/nix/store/")) and .database and .redis.enable and .redis.bind == "127.0.0.1"
  and .redis.settings["maxmemory-policy"] == "noeviction"
  and .redis.appendOnly and .redis.requirePassFile == "/run/langfuse-redis/password"
  and .clickhouse.listen_host == "127.0.0.1"
  and .clickhouse.timezone == "UTC"
  and .clickhouse.tcp_port == 19140 and .clickhouse.http_port == 18140
  and (.bootstrapAfter | index("postgresql-setup.service")) != null
  and (.bootstrapRequires | index("postgresql-setup.service")) != null
  and (.minioArgs | index("127.0.0.1:9040")) != null
  and .nativeAuthPaths == ["/api/public/*"]
  and .allowedGroups == ["langfuse-users"]
  and .privateDns == "private" and (.publicRoute | not)
  and all(.images[]; test("@sha256:[a-f0-9]{64}$"))
  and .networks == [["host"],["host"]]
  and .secretMode == "0400" and (.ownerEmail | contains("@"))
  and (.dump | length) == 1 and .clickhouseBackup
  and .restart == "on-failure" and (.restartSec | length > 0)
  and (.interval | length > 0) and (.burst | length > 0)
  and .redisRestart == "on-failure" and (.redisRestartSec | length > 0)
  and (.redisInterval | length > 0) and (.redisBurst | length > 0)
  and (.onFailure | length) == 1 and (.redisOnFailure | length) == 1
  and all(.unitOnFailure[]; length == 1)
  and (.prepareTriggers | length) == 1 and (.bootstrapTriggers | length) == 1
  and all(.containerOptions[]; index("--cap-drop=ALL") != null)
  and .postgresTimezone == "UTC"
  and (.rebuildable | index("var/lib/clickhouse") != null)
  and (.rebuildable | index("var/lib/langfuse/minio") == null)
  and (.currentGenerationPath | startswith("/persist/appdata/backup-metadata/"))
  and (.fragment | contains("langfuse_clickhouse_backup"))
  and (.fragment | contains("if ! /nix/store/"))
  and (.fragment | contains("BACKUP DATABASE default TO Disk("))
  and (.fragment | contains("langfuse_retain_last_good"))
  and (.fragment | contains("sha256sum --check --status"))
  and (.fragment | contains("degraded-langfuse-clickhouse.json"))
  and (.fragment | contains("archiveCarriedForward"))
  and (.seedScript | contains("seed_directory /var/lib/clickhouse"))
  and (.seedScript | contains("seed_directory /var/lib/langfuse"))
  and (.seedScript | contains("seed_directory /var/lib/redis-langfuse"))
' <<<"$value" >/dev/null
# Persistence entries can be either a path string or a directory record.
for path in /var/lib/langfuse /var/lib/clickhouse /var/lib/redis-langfuse; do
  jq -e --arg path "$path" '.persistence | any(. == $path or (type == "object" and .directory == $path))' <<<"$value" >/dev/null
done
echo 'Langfuse reuses platform dependencies, keeps private routing, and retains backup state.'

# ---------------------------------------------------------------------------
# Executable retention coverage.
#
# The declaration assertions above cannot show that a failed ClickHouse backup
# still leaves a restorable archive. Run the real fragment body from the
# evaluated configuration against a sandbox: the store client, /run and
# /var/lib paths are rewritten to temporary directories, and the client is
# replaced by a stub whose outcome each scenario controls.
# ---------------------------------------------------------------------------
ensure_tools bash sha256sum readlink grep sed

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

client_path="$(jq -r '.fragment' <<<"$value" | grep -o '/nix/store/[^ ]*/bin/clickhouse-client' | head -n 1)"
if [[ -z "$client_path" ]]; then
  echo '❌ Langfuse fragment does not pin a store ClickHouse client.'
  exit 1
fi
current_link="$(jq -r '.currentGenerationPath' <<<"$value")"
if [[ "$current_link" != /* ]]; then
  echo "❌ Langfuse fragment does not resolve the current generation: ${current_link}"
  exit 1
fi

stub_dir="$sandbox/stub"
mkdir -p "$stub_dir"
stub="$stub_dir/clickhouse-client"
cat >"$stub" <<'STUB_EOF'
#!/usr/bin/env bash
set -euo pipefail
# Recover the archive name from the BACKUP statement the fragment issues. The
# whole statement arrives as one argument; strip everything up to the Disk
# target and its opening quote, then the closing "')".
name=""
for arg in "$@"; do
  case "$arg" in
    *BACKUP*)
      name="$(printf '%s' "$arg" | sed "s/.*Disk('[^']*', '//; s/').*//")"
      ;;
  esac
done
if [[ -z "$name" ]]; then
  echo "stub: no archive name in: $*" >&2
  exit 1
fi
if [[ "${BACKUP_STUB_FAILS:-0}" == "1" ]]; then
  echo "stub: BACKUP failed" >&2
  exit 1
fi
printf '%s' "${BACKUP_STUB_CONTENT:-fresh}" >"$BACKUP_STUB_ROOT/$name"
STUB_EOF
make_test_executable "$stub"

# The generated fragment runs under the parent's `set -euo pipefail`; source it
# in a subshell so each scenario gets its own `work` directory. Absolute
# production paths are rewritten to the sandbox, never emulated.
run_fragment() {
  local scenario="$1"
  local root="$sandbox/$scenario"
  local fragment="$root/fragment.sh"

  mkdir -p "$root/run-langfuse/clickhouse-backups" "$root/previous/dumps" \
    "$root/previous/metadata" "$root/current/dumps" "$root/current/metadata"
  export BACKUP_STUB_ROOT="$root/run-langfuse/clickhouse-backups"

  jq -r '.fragment' <<<"$value" \
    | sed -e "s#$client_path#$stub#g" \
      -e "s#/run/langfuse#$root/run-langfuse#g" \
      -e "s#/var/lib/langfuse#$root/run-langfuse#g" \
      -e "s#$current_link#$root/previous#g" \
    >"$fragment"

  (
    set -euo pipefail
    work="$root/current"
    export work
    # shellcheck disable=SC1090
    source "$fragment"
  )
}

assert_degraded() {
  local root="$1" expect_carried="$2" description="$3"
  local marker="$root/current/metadata/degraded-langfuse-clickhouse.json"
  if [[ ! -f "$marker" ]]; then
    echo "❌ ${description}: no degraded marker was written"
    exit 1
  fi
  require_json_equal "$(jq -r '.archiveCarriedForward' "$marker")" "$expect_carried" \
    "${description}: carried-forward flag"
  if [[ "$expect_carried" == "false" ]] && [[ -s "$root/current/dumps/langfuse-clickhouse.zip" ]]; then
    echo "❌ ${description}: published an archive with no verified predecessor"
    exit 1
  fi
}

# 1. Fresh backup: published, checksummed, not degraded, and no intermediate
# archive left on the live ClickHouse backup disk.
run_fragment fresh
[[ -s "$sandbox/fresh/current/dumps/langfuse-clickhouse.zip" ]] || {
  echo '❌ Fresh ClickHouse backup was not published.'
  exit 1
}
grep -q 'dumps/langfuse-clickhouse.zip' "$sandbox/fresh/current/metadata/SHA256SUMS" || {
  echo '❌ Fresh ClickHouse backup has no SHA256SUMS line.'
  exit 1
}
[[ ! -e "$sandbox/fresh/current/metadata/degraded-langfuse-clickhouse.json" ]] || {
  echo '❌ A successful ClickHouse backup was marked degraded.'
  exit 1
}
if find "$sandbox/fresh/run-langfuse/clickhouse-backups" -type f | grep -q .; then
  echo '❌ The intermediate ClickHouse archive was left on the live disk.'
  exit 1
fi

# 2. Failed BACKUP with a verified predecessor: the last good archive is
# carried forward, the generation still publishes, and it is marked degraded.
mkdir -p "$sandbox/carryforward/previous/dumps" "$sandbox/carryforward/previous/metadata"
printf 'last-good-archive' >"$sandbox/carryforward/previous/dumps/langfuse-clickhouse.zip"
(cd "$sandbox/carryforward/previous" && sha256sum dumps/langfuse-clickhouse.zip) \
  >"$sandbox/carryforward/previous/metadata/SHA256SUMS"
BACKUP_STUB_FAILS=1 run_fragment carryforward
require_json_equal \
  "$(cat "$sandbox/carryforward/current/dumps/langfuse-clickhouse.zip")" 'last-good-archive' \
  'A failed ClickHouse backup must inherit the last verified archive'
assert_degraded "$sandbox/carryforward" true 'Carried-forward generation'
(cd "$sandbox/carryforward/current" && sha256sum --check --status metadata/SHA256SUMS) || {
  echo '❌ The carried-forward archive does not match this generation'"'"'s SHA256SUMS.'
  exit 1
}

# 3. Failed BACKUP with a corrupted predecessor: nothing is published, and the
# loss is still surfaced instead of reported as a successful backup.
mkdir -p "$sandbox/corrupt/previous/dumps" "$sandbox/corrupt/previous/metadata"
printf 'tampered' >"$sandbox/corrupt/previous/dumps/langfuse-clickhouse.zip"
(cd "$sandbox/corrupt/previous" && sha256sum dumps/langfuse-clickhouse.zip) \
  >"$sandbox/corrupt/previous/metadata/SHA256SUMS"
printf 'tampered-after-the-sum-was-written' >"$sandbox/corrupt/previous/dumps/langfuse-clickhouse.zip"
BACKUP_STUB_FAILS=1 run_fragment corrupt
assert_degraded "$sandbox/corrupt" false 'Corrupted-predecessor generation'

# 4. Failed BACKUP on a first run: degraded, with no archive to inherit.
BACKUP_STUB_FAILS=1 run_fragment firstrun
assert_degraded "$sandbox/firstrun" false 'First-run generation'

echo 'Langfuse backup retention degrades loudly and keeps a restorable archive.'
