#!/usr/bin/env bash

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools jq nix rg

host_name="$(
  nix eval --json '.#nixosConfigurations' --apply builtins.attrNames \
    | jq -er '[.[] | select(endswith("-bootstrap") | not)] | first'
)"

serializable_settings="$(nix eval --json '.#lib.nixhomeserverSerializableSettings')"
jq -e --arg host "$host_name" '
  length == 1
  and has($host)
  and (.[ $host ].serverLanIP | type == "string" and length > 0)
  and (.[ $host ].localAdminUser | type == "string" and length > 0)
' <<<"$serializable_settings" >/dev/null || {
  echo "❌ Maintenance apps cannot evaluate the sole host transport settings as JSON."
  jq . <<<"$serializable_settings"
  exit 1
}

runtime_json="$(NIXHOMESERVER_TEST_HOST="$host_name" flake_eval_json '
  hostName = builtins.getEnv "NIXHOMESERVER_TEST_HOST";
  cfg = (builtins.getAttr hostName f.nixosConfigurations).config;
in {
  dataPool = {
    forceImportRoot = cfg.boot.zfs.forceImportRoot;
    wantedBy = cfg.systemd.services.data-pool-layout.wantedBy;
    fileshareRequires = cfg.systemd.services.fileshare-user-root-sync.requires;
    fileshareAfter = cfg.systemd.services.fileshare-user-root-sync.after;
    kopiaBootstrapRequires = cfg.systemd.services.kopia-repository-bootstrap.requires;
    kopiaSnapshotRequires = cfg.systemd.services.kopia-persist-snapshot.requires;
    zfsMaintenanceOrdering = map
      (name: {
        inherit name;
        requires = cfg.systemd.services.${name}.requires;
        after = cfg.systemd.services.${name}.after;
      })
      [ "zfs-scrub" "zfs-snapshot-daily" "zfs-snapshot-hourly" "zfs-snapshot-weekly" ];
  };
  dns = {
    freebind = cfg.services.unbound.settings.server.ip-freebind;
    unboundBefore = cfg.systemd.services.unbound.before;
    netbirdAfter = cfg.systemd.services.netbird-main.after;
  };
  syncthing = cfg.repo.authGateway.protectedApps.syncthing;
  backups = {
    sqliteSources = map (dump: dump.source) cfg.repo.backups.sqliteDumps;
    postgresqlDatabases = map (dump: dump.database) cfg.repo.backups.postgresqlDumps;
    snapshotRoots = cfg.repo.backups.snapshotRoots;
  };
  optionalFiles = {
    kanidmRequires = cfg.systemd.services.kanidm.requires;
    sftpRequires = cfg.systemd.services.files-sftp-sshd.requires;
    sftpWants = cfg.systemd.services.files-sftp-sshd.wants;
    filestashRequires = cfg.systemd.services.filestash.requires;
  };
  maintenance = {
    backupUnit = cfg.systemd.services.backup-prepare.unitConfig;
    backupServiceHasStartLimit = cfg.systemd.services.backup-prepare.serviceConfig ? StartLimitIntervalSec;
    kopiaSnapshotUnit = cfg.systemd.services.kopia-persist-snapshot.unitConfig;
    gcUnit = cfg.systemd.services.nixhomeserver-nix-gc.unitConfig;
    gcService = {
      restart = cfg.systemd.services.nixhomeserver-nix-gc.serviceConfig.Restart or null;
      successExitStatus = cfg.systemd.services.nixhomeserver-nix-gc.serviceConfig.SuccessExitStatus;
    };
    gcTimer = cfg.systemd.timers.nixhomeserver-nix-gc.timerConfig;
    optimiseSuccessExitStatus =
      cfg.systemd.services.nixhomeserver-nix-optimise.serviceConfig.SuccessExitStatus;
  };
  persistence = {
    directories = cfg.repo.impermanence.inventory.persistenceDirectories;
    files = cfg.repo.impermanence.inventory.persistenceFiles;
  };
  localAdminPassword = {
    wantedBy = cfg.systemd.services.local-admin-bootstrap-password.wantedBy;
    before = cfg.systemd.services.local-admin-bootstrap-password.before;
    credentials = cfg.systemd.services.local-admin-bootstrap-password.serviceConfig.LoadCredential;
    execStart = toString cfg.systemd.services.local-admin-bootstrap-password.serviceConfig.ExecStart;
    restartTriggers = map toString cfg.systemd.services.local-admin-bootstrap-password.restartTriggers;
    expectedRestartTrigger = toString cfg.age.secrets.serverBootstrapSudoPassword.file;
    sshPasswordAuthentication = cfg.services.openssh.settings.PasswordAuthentication;
  };
  fileshareAclMigration = {
    wantedBy = cfg.systemd.services.fileshare-acl-migrate.wantedBy;
    after = cfg.systemd.services.fileshare-acl-migrate.after;
    script = cfg.systemd.services.fileshare-acl-migrate.script;
    policyVersion = cfg.repo.storage.userRoots.aclPolicyVersion;
  };
  power = {
    available = cfg.nixhomeserver.powerSchedule.available;
    stateFile = cfg.nixhomeserver.powerSchedule.stateFile;
    defaults = cfg.nixhomeserver.powerSchedule.defaults;
    defaultsJson = cfg.nixhomeserver.powerSchedule.defaultsJson;
    timerOnCalendar = cfg.systemd.timers.power-management-nightly-suspend.timerConfig.OnCalendar;
    suspendScript = cfg.systemd.services.power-management-nightly-suspend.script;
    tmpfiles = cfg.systemd.tmpfiles.rules;
    homepageEnv = cfg.systemd.services.homepage.environment;
    homepageReadWritePaths = cfg.systemd.services.homepage.serviceConfig.ReadWritePaths;
    homepageSudoCommands = builtins.concatMap
      (rule: map (command: command.command) rule.commands)
      (lib.filter (rule: builtins.elem "homepage" rule.users) cfg.security.sudo.extraRules);
    persistedDirectories = cfg.repo.impermanence.inventory.persistenceDirectories;
    buildModeEnv = cfg.systemd.services.homepage.environment;
  };
}')"

jq -e '
  (.dataPool.wantedBy | index("local-fs.target") != null)
  and (.dataPool.forceImportRoot == false)
  and (.dataPool.fileshareRequires | index("data-pool-layout.service") != null)
  and (.dataPool.fileshareAfter | index("kanidm-unixd.service") != null)
  and (.dataPool.kopiaBootstrapRequires | index("data-pool-layout.service") != null)
  and (.dataPool.kopiaSnapshotRequires | index("data-pool-layout.service") != null)
  and (.dataPool.kopiaSnapshotRequires | index("kopia-repository-bootstrap.service") != null)
  and (.dataPool.zfsMaintenanceOrdering | all(
    (.requires | index("data-pool-layout.service") != null)
    and (.after | index("data-pool-layout.service") != null)
  ))
  and (.dns.freebind == true)
  and (.dns.unboundBefore | index("netbird-main.service") != null)
  and (.dns.netbirdAfter | index("unbound.service") != null)
  and (.syncthing.host | startswith("syncthing."))
  and (.syncthing.upstream == "http://127.0.0.1:8384")
  and (.syncthing.allowedGroups == ["app-admin"])
  and (.backups.sqliteSources | index("/var/lib/audiobookshelf/config/absdatabase.sqlite") != null)
  and (.backups.sqliteSources | index("/var/lib/jellyfin/data/jellyfin.db") != null)
  and (.backups.postgresqlDatabases | index("immich") != null)
  and (.backups.snapshotRoots | index("/persist") != null)
  and (.backups.snapshotRoots | index("/mnt/data/paperless") != null)
  and (.optionalFiles.kanidmRequires | index("filestash-secret-materialize.service") == null)
  and (.optionalFiles.kanidmRequires | index("filestash-identity-secret-materialize.service") != null)
  and (.optionalFiles.sftpRequires | index("data-pool-layout.service") != null)
  and (.optionalFiles.sftpRequires | index("fileshare-user-root-sync.service") != null)
  and (.optionalFiles.sftpWants | index("filestash-secret-materialize.service") == null)
  and (.optionalFiles.filestashRequires | index("data-pool-layout.service") != null)
  and (.optionalFiles.filestashRequires | index("fileshare-user-root-sync.service") != null)
  and (.maintenance.backupUnit.StartLimitIntervalSec == "2h")
  and (.maintenance.backupServiceHasStartLimit == false)
  and (.maintenance.kopiaSnapshotUnit.StartLimitIntervalSec == "2h")
  and (.maintenance.gcUnit.OnFailure == ["nixhomeserver-failure-alert@%n.service"])
  and (.maintenance.gcService.restart == null)
  and (.maintenance.gcService.successExitStatus | index(75) != null)
  and (.maintenance.gcTimer.OnCalendar == "hourly")
  and (.maintenance.optimiseSuccessExitStatus | index(75) != null)
  and (.localAdminPassword.wantedBy | index("multi-user.target") != null)
  and (.localAdminPassword.before | index("systemd-user-sessions.service") != null)
  and (.localAdminPassword.credentials | index("bootstrap-password:/run/agenix/serverBootstrapSudoPassword") != null)
  and (.localAdminPassword.execStart | contains("local-admin-bootstrap-password"))
  and (.localAdminPassword as $localAdmin | ($localAdmin.restartTriggers | index($localAdmin.expectedRestartTrigger) != null))
  and (.localAdminPassword.sshPasswordAuthentication == false)
  and (.fileshareAclMigration.wantedBy | index("multi-user.target") != null)
  and (.fileshareAclMigration.after | index("fileshare-user-root-sync.service") != null)
  and (.fileshareAclMigration as $acl | ($acl.script | contains("fileshare-acl-policy-v" + ($acl.policyVersion | tostring))))
  and (.fileshareAclMigration.script | contains("install -D -m 0600 /dev/null \"$marker\""))
  and (.power.available == true)
  and (.power.stateFile == "/var/lib/power-schedule/schedule.json")
  and (.power.defaults == { enabled: false, wakeTime: "10:30", idleWindowStartHour: 22, forcedWindowEndHour: 10 })
  and ((.power.defaultsJson | fromjson) == .power.defaults)
  and (.power.timerOnCalendar == ["*-*-* *:00/15:00"])
  and (.power.suspendScript | contains("/var/lib/power-schedule/schedule.json"))
  and (.power.suspendScript | contains("jq -cerf"))
  and (.power.suspendScript | contains("dashboard power schedule"))
  and (.power.suspendScript | contains("falling back to Nix defaults"))
  and (.power.tmpfiles | index("d /var/lib/power-schedule 0755 root root -") != null)
  and (.power.persistedDirectories | index("/var/lib/power-schedule") != null)
  and (.power.homepageEnv.HOMEPAGE_POWER_SCHEDULE_FILE == .power.stateFile)
  and (.power.homepageEnv.HOMEPAGE_POWER_SCHEDULE_APPLY_COMMAND | type == "string" and length > 0)
  and ((.power.homepageEnv.HOMEPAGE_POWER_SCHEDULE_DEFAULTS | fromjson).wakeTime == "10:30")
  and (.power.homepageReadWritePaths | index("/var/lib/power-schedule") != null)
  and (.power as $power | ($power.homepageSudoCommands | index($power.homepageEnv.HOMEPAGE_POWER_SCHEDULE_APPLY_COMMAND)) != null)
  and (.power.buildModeEnv.HOMEPAGE_BUILD_MODE_FILE == "/var/lib/deploy-settings/build-mode.json")
  and (.power.buildModeEnv.HOMEPAGE_BUILD_MODE_DEFAULT == "remote")
  and (.power.buildModeEnv.HOMEPAGE_BUILD_MODE_APPLY_COMMAND | type == "string" and length > 0)
  and (.power.homepageReadWritePaths | index("/var/lib/deploy-settings") != null)
  and (.power as $power | ($power.homepageSudoCommands | index($power.buildModeEnv.HOMEPAGE_BUILD_MODE_APPLY_COMMAND)) != null)
  and (.power.tmpfiles | index("d /var/lib/deploy-settings 0755 root root -") != null)
  and (.power.persistedDirectories | index("/var/lib/deploy-settings") != null)
  and (.persistence.directories | index("/etc/nixos") != null)
  and (.persistence.directories | index("/var/lib/postgresql") != null)
  and (.persistence.directories | index("/var/log/caddy") != null)
  and (.persistence.files | index("/etc/machine-id") != null)
  and (.persistence.files | index("/var/lib/systemd/random-seed") != null)
' <<<"$runtime_json" >/dev/null || {
  echo "❌ Core runtime safety configuration regressed."
  jq . <<<"$runtime_json"
  exit 1
}

require_fixed modules/Core_Modules/storage/layout.nix \
  'Required ZFS pool ${vars.zfsDataPool.name} is not mounted at ${vars.dataRoot}' \
  "The data-pool layout must fail instead of writing beneath an absent pool mount."
require_fixed modules/Core_Modules/storage/layout.nix \
  'Required ZFS dataset $dataset is not mounted at $mountpoint' \
  "Every managed ZFS dataset must be checked after reconciliation."
require_fixed modules/Core_Modules/storage/layout.nix \
  'Refusing to hide existing files beneath unmounted data-pool path $mountpoint' \
  "Pool reconciliation must not conceal files written beneath a missing mount."
require_fixed modules/Core_Modules/storage/fileshare-user-roots.nix \
  'Refusing fileshare operation because ${vars.dataRoot} is not a mounted data pool' \
  "Fileshare reconciliation must recheck the data mount on every run."
for service_template in files-shared-delete-bindfs@ files-shared-bindfs@ files-sftp-user-root@; do
  require_fixed modules/Core_Modules/storage/fileshare-user-roots.nix \
    "systemctl start --no-block \"\$(service_instance $service_template.service \"\$username\")\"" \
    "Fileshare reconciliation must not synchronously wait for $service_template units ordered after it."
done
require_fixed modules/Core_Modules/backups/default.nix 'sha256sum -- "dumps/$output_name"' \
  "Published backup checksums must use generation-relative dump paths."
require_fixed modules/Core_Modules/backups/default.nix 'sha256sum --check metadata/SHA256SUMS' \
  "Backup preparation must verify its checksum manifest before publication."
# The retention matrix keeps its fixtures under a task-owned, gitignored
# evidence root so the extracted executable, checked substitutions, input
# trees, observations and hashes survive the fixture cleanup. Every byte it
# records is synthetic; no live backup data is read or written.
backup_evidence_root="${NIXHOMESERVER_BACKUP_EVIDENCE_DIR:-$TESTS_REPO_ROOT/.tmp/backup-retention-evidence}"
backup_evidence_run="$backup_evidence_root/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"

create_complete_generation() {
  local root="$1" name="$2"
  mkdir -p "$root/dumps" "$root/metadata"
  printf '%s\n' "$name" >"$root/dumps/payload"
  jq -n \
    --arg createdAt '2026-01-01T00:00:00+00:00' \
    --arg host 'synthetic-fixture' \
    '{schemaVersion: 1, createdAt: $createdAt, host: $host, sqliteDumps: 0, postgresqlDumps: []}' \
    >"$root/metadata/manifest.json"
  (cd "$root" && sha256sum dumps/payload >metadata/SHA256SUMS)
}

# Complete production generations carry dumps plus metadata/manifest.json and
# metadata/SHA256SUMS. A generation missing any of them is not a generation the
# selector should be trusted to retain.
assert_complete_generation() {
  local root="$1" label="$2" inventory
  inventory="$(find "$root" -mindepth 1 -maxdepth 2 -type f -printf '%P\n' | sort)"
  [[ "$inventory" == $'dumps/payload\nmetadata/SHA256SUMS\nmetadata/manifest.json' ]] || {
    printf '❌ %s is not a complete backup generation:\n%s\n' "$label" "$inventory" >&2
    return 1
  }
  jq -e '
    .schemaVersion == 1
    and (.createdAt | type == "string" and length > 0)
    and (.host | type == "string" and length > 0)
    and (.sqliteDumps | type == "number")
    and (.postgresqlDumps | type == "array")
  ' "$root/metadata/manifest.json" >/dev/null || {
    printf '❌ %s carries an invalid metadata/manifest.json.\n' "$label" >&2
    return 1
  }
  (cd "$root" && sha256sum --check --strict metadata/SHA256SUMS >/dev/null) || {
    printf '❌ %s failed its checksum manifest.\n' "$label" >&2
    return 1
  }
}

run_backup_retention_fixture() {
  local retention="$1" ordering="$2" layout="$3" fixture_root="$4"
  local source_file="$TESTS_REPO_ROOT/modules/Core_Modules/backups/default.nix"
  local executable="$fixture_root/production-retention.sh"
  local generations="$fixture_root/generations" staging="$fixture_root/staging"
  local generation count current_target return_code current_link checksum_return_code
  local evidence_case="$backup_evidence_run/${retention}-${ordering}-${layout}"
  local prepare_sentinel_before outside_sentinel_before prepare_sentinel_after outside_sentinel_after

  mkdir -p "$generations" "$staging" "$fixture_root/work/metadata" "$fixture_root/work/dumps"
  mkdir -p "$evidence_case/inputs" "$evidence_case/retained"
  create_complete_generation "$generations/old-current" old-current
  if [[ "$layout" == full ]]; then
    for generation in prior-a prior-b; do
      create_complete_generation "$generations/$generation" "$generation"
    done
  fi
  ln -s generations/old-current "$fixture_root/current"
  mkdir -p "$generations/.prepare.sentinel"
  printf 'prepare\n' >"$generations/.prepare.sentinel/marker"
  printf 'outside\n' >"$fixture_root/outside-sentinel"
  if [[ "$ordering" == tied ]]; then
    while IFS= read -r generation_path; do
      touch -d '@1000000200' "$generation_path"
    done < <(find "$generations" -mindepth 1 -maxdepth 1 -type d ! -name '.prepare.*')
  elif [[ "$ordering" == reordered ]]; then
    touch -d '@1000000000' "$generations/old-current"
    [[ ! -d "$generations/prior-a" ]] || touch -d '@2000000000' "$generations/prior-a"
    [[ ! -d "$generations/prior-b" ]] || touch -d '@2000000100' "$generations/prior-b"
  else
    touch -d '@1000000000' "$generations/old-current"
    [[ ! -d "$generations/prior-a" ]] || touch -d '@1000000100' "$generations/prior-a"
    [[ ! -d "$generations/prior-b" ]] || touch -d '@1000000200' "$generations/prior-b"
  fi
  # Capture the exact synthetic inputs, sentinel bytes and every input hash
  # before the production shell runs: the fixture tree itself is removed after
  # the matrix, so an unexported run leaves no reviewable input evidence.
  prepare_sentinel_before="$(sha256sum "$generations/.prepare.sentinel/marker" | cut -d' ' -f1)"
  outside_sentinel_before="$(sha256sum "$fixture_root/outside-sentinel" | cut -d' ' -f1)"
  (cd "$generations" && find . -mindepth 1 -maxdepth 3 -type f ! -path './.prepare.*' -print0 \
    | sort -z | xargs -0 -r sha256sum) >"$evidence_case/inputs.sha256"
  for generation_path in "$generations/old-current" "$generations/prior-a" "$generations/prior-b"; do
    [[ -d "$generation_path" ]] || continue
    cp -a "$generation_path" "$evidence_case/inputs/${generation_path##*/}"
  done
  cp -a "$generations/.prepare.sentinel" "$evidence_case/inputs/prepare-sentinel"
  cp -a "$fixture_root/outside-sentinel" "$evidence_case/inputs/outside-sentinel"
  cp "$source_file" "$evidence_case/source-default.nix"
  printf 'retention=%s ordering=%s layout=%s\n' "$retention" "$ordering" "$layout" >"$evidence_case/case.txt"

  for generation_path in "$generations/old-current" "$generations/prior-a" "$generations/prior-b"; do
    [[ -d "$generation_path" ]] || continue
    set +e
    (cd "$generation_path" && sha256sum --check metadata/SHA256SUMS) >"$fixture_root/input-checksum" 2>&1
    input_checksum_exit=$?
    set -e
    printf 'input_generation=%s checksum_exit=%s manifest=' "${generation_path##*/}" "$input_checksum_exit"
    sha256sum "$generation_path/metadata/SHA256SUMS"
    [[ "$input_checksum_exit" -eq 0 ]] || return 1
    assert_complete_generation "$generation_path" "input generation ${generation_path##*/}" || return 1
  done

  python3 - "$source_file" "$executable" "$generations" "$staging" "$retention" "$ordering" \
    "$evidence_case/substitutions.txt" <<'PY'
import hashlib
import pathlib
import shlex
import sys

source_path, executable_path, generations, staging, retention, ordering, substitutions_path = sys.argv[1:]
source = pathlib.Path(source_path).read_text()

def unique_marker(value):
    if source.count(value) != 1:
        raise SystemExit(f"Expected one production boundary: {value!r}")
    return source.index(value)

function_start = unique_marker("        publish_current_link() {")
function_end_marker = "\n\n        # Interrupted publications"
if source.count(function_end_marker) != 1:
    raise SystemExit("Expected one end boundary for production publication function")
function_end = source.index(function_end_marker, function_start)
tail_start = unique_marker('        generation="$(date --utc +%Y%m%dT%H%M%S)-$$"')
tail_end_marker = "\n      '';"
if source.count(tail_end_marker) != 1:
    raise SystemExit("Expected one end boundary for production retention tail")
tail_end = source.index(tail_end_marker, tail_start)
script = source[function_start:function_end] + "\n" + source[tail_start:tail_end]

substitutions = {
    "''${": ("${", 3),
    "${lib.escapeShellArg successfulGenerationRoot}": (shlex.quote(generations), 3),
    "${lib.escapeShellArg stagingRoot}": (shlex.quote(staging), 1),
    "${lib.escapeShellArg successfulCurrentPath}": (shlex.quote(str(pathlib.Path(generations).parent / 'current')), 1),
    "${toString config.repo.backups.retainedSuccessfulGenerations}": (retention, 1),
}
for marker, (replacement, expected_count) in substitutions.items():
    actual_count = script.count(marker)
    if actual_count != expected_count:
        raise SystemExit(f"Expected {expected_count} substitutions for {marker!r}; found {actual_count}")
    script = script.replace(marker, replacement)
if "${lib." in script or "${toString" in script or "''${" in script:
    raise SystemExit("Unaccounted Nix interpolation remains in production fixture")
header = (
    "#!/usr/bin/env bash\nset -euo pipefail\n"
    f"successfulGenerationRoot={generations!r}\n"
    f"stagingRoot={staging!r}\n"
    f"successfulCurrentPath={str(pathlib.Path(generations).parent / 'current')!r}\n"
    f"retention={retention!r}\nwork=\"$stagingRoot/prepared\"\n"
    "mkdir -p \"$work/metadata\" \"$work/dumps\"\n"
    "printf 'published\\n' >\"$work/dumps/payload\"\n"
    "(cd \"$work\" && sha256sum dumps/payload > metadata/SHA256SUMS)\n"
    "jq -n --arg createdAt '2026-01-01T00:00:00+00:00' --arg host 'synthetic-fixture' "
    "'{schemaVersion: 1, createdAt: $createdAt, host: $host, sqliteDumps: 0, postgresqlDumps: []}' "
    ">\"$work/metadata/manifest.json\"\n"
    f"if [[ {ordering!r} == reordered ]]; then touch -d '@1000000200' \"$work\"; "
    f"elif [[ {ordering!r} == tied ]]; then touch -d '@1000000200' \"$work\"; "
    "else touch -d '@1000000200' \"$work\"; fi\n"
)
pathlib.Path(executable_path).write_text(header + script + "\n")
pathlib.Path(substitutions_path).write_text(
    f"source={source_path}\n"
    f"source_sha256={hashlib.sha256(source.encode()).hexdigest()}\n"
    f"function_boundaries={function_start}:{function_end}\n"
    f"tail_boundaries={tail_start}:{tail_end}\n"
    + "".join(
        f"marker={marker!r} count={expected_count} replacement={replacement!r}\n"
        for marker, (replacement, expected_count) in substitutions.items()
    )
)
PY
  chmod +x "$executable"
  set +e
  "$executable" >"$fixture_root/stdout" 2> "$fixture_root/stderr"
  return_code=$?
  set -e
  if [[ "$return_code" -ne 0 ]]; then
    cp "$executable" "$evidence_case/production-retention.sh"
    cp "$fixture_root/stdout" "$evidence_case/stdout"
    cp "$fixture_root/stderr" "$evidence_case/stderr"
    printf 'Production retention shell returned %s (%s, retention %s).\n' \
      "$return_code" "$ordering" "$retention" >&2
    printf '%s\n' '--- extracted production shell ---' >&2
    cat "$executable" >&2
    printf '%s\n' '--- production shell stderr ---' >&2
    cat "$fixture_root/stderr" >&2
    printf '%s\n' '--- production shell stdout ---' >&2
    cat "$fixture_root/stdout" >&2
    printf 'Evidence: %s\n' "$evidence_case" >&2
    return 1
  fi
  cp "$executable" "$evidence_case/production-retention.sh"
  cp "$fixture_root/stdout" "$evidence_case/stdout"
  cp "$fixture_root/stderr" "$evidence_case/stderr"

  assert_backup_retention_fixture() {
  current_link="$(readlink "$fixture_root/current")"
  current_target="$(readlink -f "$fixture_root/current")"
  [[ "$current_link" == generations/* && "$current_target" == "$generations"/* && -d "$current_target" ]] || {
    printf 'Published current link/target is invalid (%s, retention %s).\n' "$ordering" "$retention" >&2
    return 1
  }
  case "${current_target##*/}" in
    old-current | prior-a | prior-b)
      printf 'Publication must point at the newly published generation, not %s (%s, retention %s).\n' \
        "${current_target##*/}" "$ordering" "$retention" >&2
      return 1
      ;;
  esac
  assert_complete_generation "$current_target" "published generation ${current_target##*/}" || return 1
  set +e
  (cd "$current_target" && sha256sum --check metadata/SHA256SUMS) >"$fixture_root/current-checksum" 2>&1
  checksum_return_code=$?
  set -e
  [[ "$checksum_return_code" -eq 0 ]] || {
    cat "$fixture_root/current-checksum" >&2
    return 1
  }
  prepare_sentinel_after="$(sha256sum "$generations/.prepare.sentinel/marker" | cut -d' ' -f1)"
  outside_sentinel_after="$(sha256sum "$fixture_root/outside-sentinel" | cut -d' ' -f1)"
  [[ "$prepare_sentinel_after" == "$prepare_sentinel_before" ]] || {
    printf 'The .prepare.sentinel marker changed bytes during publication (%s, retention %s).\n' \
      "$ordering" "$retention" >&2
    return 1
  }
  [[ "$outside_sentinel_after" == "$outside_sentinel_before" ]] || {
    printf 'The sentinel outside the generation root changed bytes during publication (%s, retention %s).\n' \
      "$ordering" "$retention" >&2
    return 1
  }
  count="$(find "$generations" -mindepth 1 -maxdepth 1 -type d ! -name '.prepare.*' | wc -l)"
  [[ "$count" -le "$retention" ]] || {
    printf 'Retention bound exceeded: %s > %s.\n' "$count" "$retention" >&2
    find "$generations" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' >&2
    return 1
  }
  while IFS= read -r generation_path; do
    assert_complete_generation "$generation_path" \
      "retained generation ${generation_path##*/}" || return 1
    set +e
    (cd "$generation_path" && sha256sum --check metadata/SHA256SUMS) >"$fixture_root/retained-checksum" 2>&1
    generation_checksum_exit=$?
    set -e
    printf 'retained_generation=%s checksum_exit=%s files=' "${generation_path##*/}" "$generation_checksum_exit"
    find "$generation_path" -mindepth 1 -maxdepth 2 -type f -printf '%P,' | sort
    printf 'manifest_sha256='
    sha256sum "$generation_path/metadata/SHA256SUMS"
    [[ "$generation_checksum_exit" -eq 0 ]] || return 1
  done < <(find "$generations" -mindepth 1 -maxdepth 1 -type d ! -name '.prepare.*')
  # Retained fixture bytes must be byte-identical to the captured inputs: a
  # symlink that merely satisfies the count is not preserved data.
  while read -r recorded_hash recorded_path; do
    [[ -n "$recorded_hash" ]] || continue
    [[ -f "$generations/${recorded_path#./}" ]] || continue
    actual_hash="$(sha256sum "$generations/${recorded_path#./}" | cut -d' ' -f1)"
    [[ "$actual_hash" == "$recorded_hash" ]] || {
      printf 'Retained input %s changed bytes during publication (%s, retention %s).\n' \
        "${recorded_path#./}" "$ordering" "$retention" >&2
      return 1
    }
    printf 'unchanged_input=%s sha256=%s\n' "${recorded_path#./}" "$actual_hash"
  done <"$evidence_case/inputs.sha256"
  if [[ "$layout" == full && "$ordering" != tied && "$retention" -eq 2 ]]; then
    [[ -d "$generations/prior-b" ]] || return 1
  elif [[ "$layout" == below ]]; then
    # Fewer inputs than the bound: publication must add the new generation,
    # keep the existing complete one byte-for-byte and stay strictly below the
    # bound instead of deleting a prior generation.
    [[ -d "$generations/old-current" ]] || return 1
    [[ "$count" -lt "$retention" ]] || {
      printf 'Post-publication inventory is not below the bound: %s >= %s (%s).\n' \
        "$count" "$retention" "$layout" >&2
      return 1
    }
  elif [[ "$layout" == few && "$retention" -eq 2 ]]; then
    [[ -d "$generations/old-current" ]] || return 1
  elif [[ "$layout" == few && "$retention" -eq 1 ]]; then
    # At a bound of one the previously current generation must be pruned; the
    # published generation alone is the complete inventory.
    [[ ! -d "$generations/old-current" ]] || {
      printf 'A bound of one must prune the previously current generation (%s).\n' "$layout" >&2
      return 1
    }
  fi
  }
  set +e
  assert_backup_retention_fixture
  fixture_assertion_exit=$?
  set -e
  # Preserve the post-publication tree and a complete observation record before
  # the fixture directory is removed.
  if [[ -d "$generations" ]]; then
    while IFS= read -r generation_path; do
      cp -a "$generation_path" "$evidence_case/retained/${generation_path##*/}"
    done < <(find "$generations" -mindepth 1 -maxdepth 1 -type d ! -name '.prepare.*')
  fi
  [[ ! -f "$fixture_root/outside-sentinel" ]] || \
    cp -a "$fixture_root/outside-sentinel" "$evidence_case/retained/outside-sentinel"
  jq -n \
    --arg case_name "$retention-$ordering-$layout" \
    --arg retention "$retention" \
    --arg ordering "$ordering" \
    --arg layout "$layout" \
    --arg shell_exit "$return_code" \
    --arg assertion_exit "$fixture_assertion_exit" \
    --arg current_link "${current_link:-}" \
    --arg current_resolved "${current_target:-}" \
    --arg current_checksum_exit "${checksum_return_code:-unset}" \
    --arg complete_generation_count "${count:-unset}" \
    --arg prepare_sentinel_before "$prepare_sentinel_before" \
    --arg prepare_sentinel_after "${prepare_sentinel_after:-unset}" \
    --arg outside_sentinel_before "$outside_sentinel_before" \
    --arg outside_sentinel_after "${outside_sentinel_after:-unset}" \
    --arg evidence "$evidence_case" \
    '{
      case: $case_name,
      retention: $retention,
      ordering: $ordering,
      layout: $layout,
      shell_exit: $shell_exit,
      assertion_exit: $assertion_exit,
      current_link: $current_link,
      current_resolved: $current_resolved,
      current_checksum_exit: $current_checksum_exit,
      complete_generation_count: $complete_generation_count,
      prepare_sentinel_sha256: {before: $prepare_sentinel_before, after: $prepare_sentinel_after},
      outside_sentinel_sha256: {before: $outside_sentinel_before, after: $outside_sentinel_after},
      evidence: $evidence
    }' >"$evidence_case/observations.json"
  (
    cd "$evidence_case" && find . -type f ! -name SHA256SUMS -printf '%P\n' | sort |
      while IFS= read -r evidence_file; do sha256sum "$evidence_file"; done
  ) >"$evidence_case/SHA256SUMS"
  printf 'retention case=%s/%s bound=%s shell_exit=%s assertion_exit=%s current=%s resolved=%s checksum_exit=%s count=%s inventory=' \
    "$ordering" "$layout" "$retention" "$return_code" "$fixture_assertion_exit" \
    "${current_link:-}" "${current_target:-}" "${checksum_return_code:-unset}" "${count:-unset}"
  find "$generations" -mindepth 1 -maxdepth 1 -type d ! -name '.prepare.*' -printf '%f,' | sort
  printf 'shell stdout:\n'
  cat "$fixture_root/stdout"
  printf 'shell stderr:\n'
  cat "$fixture_root/stderr"
  sha256sum "$source_file" "$executable"
  printf 'evidence=%s\n' "$evidence_case"
  [[ "$fixture_assertion_exit" -eq 0 ]] || return "$fixture_assertion_exit"
}

mkdir -p "$backup_evidence_run"
printf 'Synthetic backup-retention evidence captured %s. Every payload, manifest and sentinel here is fabricated fixture data; no live backup data is read or written.\n' \
  "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$backup_evidence_run/README.txt"

retention_fixture_root="$(mktemp -d "${TMPDIR:-/tmp}/t_c32871c3-backup-retention.XXXXXX")"
trap 'rm -rf -- "$retention_fixture_root"' EXIT
for retention_case in \
  '2 chronological full' '2 reordered full' '1 chronological full' '1 reordered full' \
  '2 tied full' '2 chronological few' '1 chronological few' '3 chronological below'; do
  read -r retention_value ordering_value layout_value <<<"$retention_case"
  run_backup_retention_fixture "$retention_value" "$ordering_value" "$layout_value" \
    "$retention_fixture_root/$retention_case"
done
rm -rf -- "$retention_fixture_root"
trap - EXIT
printf '✅ Backup retention matrix passed; evidence preserved at %s\n' "$backup_evidence_run"

require_fixed modules/Core_Modules/backups/default.nix 'mktemp -d ${lib.escapeShellArg stagingRoot}/.current-link.XXXXXX' \
  "Backup publication must use a unique temporary symlink directory."
forbid_match modules/Core_Modules/backups/default.nix 'successfulCurrentPath[}]?[.]new' \
  "Backup publication must not be wedged by a crash-persistent current.new path."
forbid_match modules/Core_Modules/backups/default.nix 'sha256sum .*[$]work/dumps' \
  "Backup checksum manifests must not retain transient staging paths."
require_fixed modules/Core_Modules/syncthing/default.nix 'repo.authGateway.protectedApps.syncthing' \
  "The Syncthing administrative GUI must remain behind the shared SSO gateway."
forbid_match modules/Core_Modules/syncthing/default.nix 'reverse_proxy http://127[.]0[.]0[.]1:8384' \
  "Syncthing must not regain a direct unauthenticated Caddy proxy."
require_fixed modules/files/services.nix 'webAccessGroups = [ webAccessGroup ];' \
  "Supplementary USB or backup groups must not independently grant Filestash login."
require_fixed modules/Core_Modules/kanidm/sftp-files.nix '${sftpAuthorizedKeysDir}/.filestash' \
  "The Filestash backend key must work for dynamically managed web users."
require_fixed modules/Core_Modules/rclone/service.nix '${pkgs.rclone}/bin/rclone check' \
  "Offsite sync must independently verify the uploaded repository."
require_fixed modules/Core_Modules/rclone/service.nix 'last-mega-sync-success.json' \
  "Offsite verification must publish an operator-visible success marker."
require_fixed documentation/operations.md 'offsiteBackup.enable = true' \
  "Offsite setup documentation must explicitly enable the declarative service."
require_fixed documentation/restore-and-recovery.md 'Use `rclone copy`, never reverse `rclone sync`' \
  "Recovery documentation must guard the only offsite copy from reverse-sync deletion."
require_fixed documentation/quickstart.md 'mount --bind /mnt/persist/etc/nixos /mnt/etc/nixos' \
  "Fresh installs must seed the on-host repository into persisted storage before first rollback."
require_fixed modules/Core_Modules/impermanence/default.nix 'system.activationScripts.seedCorePersistence' \
  "Existing hosts must migrate newly centralized core persistence before bind mounts hide live state."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/power-schedule"' \
  "The dashboard-editable power schedule must survive root rollback and live impermanence activation."
require_fixed system-resources.nix 'wakeTime must not fall before the end of the forced-suspend window' \
  "The shared power-schedule validator must reject wake times inside the forced-suspend window."
require_fixed system-resources.nix 'forcedWindowEndHour must not be later than idleWindowStartHour' \
  "The shared power-schedule validator must keep the suspend windows ordered."
require_fixed system-resources.nix 'Power schedule file is invalid; falling back to Nix defaults' \
  "The suspend service must fail safe to Nix defaults when the runtime schedule is unreadable."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/nixhomeserver-deploy"' \
  "Guarded deployment state must survive root rollback and live impermanence activation."
require_fixed modules/Core_Modules/impermanence/default.nix 'seed_directory /var/lib/nixhomeserver-deploy' \
  "The first live adoption of persistent deployment state must preserve the active transaction token."
require_fixed modules/Core_Modules/impermanence/default.nix 'mount --bind "$persistent_path" "$source_path"' \
  "Existing core files must be safely adopted during a live impermanence activation."
require_fixed modules/Core_Modules/impermanence/default.nix 'if [ ! -e "$source_path" ]; then' \
  "Live adoption must recreate file mountpoints removed while switch-to-configuration rebuilds /etc."
require_fixed modules/Core_Modules/impermanence/default.nix '/dev/null' \
  "Live adoption must create an empty regular-file mountpoint before binding persisted state."
require_fixed scripts/test-homepage-ui.sh '--inputs-from "$NIXHOMESERVER_RUN_FLAKE_REF"' \
  "Playwright must resolve from the flake-pinned nixpkgs input."
require_fixed scripts/test-homepage-ui.sh '#checks.${system}.homepage' \
  "Homepage browser tests must build and run the hermetic flake check output."
forbid_match scripts/test-homepage-ui.sh 'pnpm run build' \
  "Homepage browser tests must not rely on a pre-existing pnpm installation or node_modules tree."
forbid_match scripts/test-homepage-ui.sh 'rm -rf tests/e2e/node_modules' \
  "Homepage browser tests must not destructively remove a pre-existing node_modules tree."
require_fixed custom_apps/node/apps/homepage/tests/e2e/bin/start-e2e-stack.mjs 'HOMEPAGE_E2E_SERVER_COMMAND' \
  "Homepage browser tests must support the packaged server command supplied by the hermetic harness."
require_fixed custom_apps/node/apps/homepage/tests/e2e/bin/start-e2e-stack.mjs 'HOMEPAGE_E2E_STATIC_DIR' \
  "Homepage browser tests must support packaged static assets supplied by the hermetic harness."
require_fixed scripts/validate-repo.sh '"$repo_root/scripts/test-homepage-ui.sh"' \
  "The full validation gate must include the Homepage Playwright suite."
require_fixed scripts/validate-repo.sh 'need nix jq rg' \
  "The validation gate must preflight every command used to retain passing build outputs."
require_fixed scripts/validate-repo.sh 'ensure_local_attic_tunnel' \
  "Validation must keep the configured local Attic tunnel available for the complete Nix build."
require_fixed flake/checks.nix 'nodejs' \
  "The hermetic repo-policy check must provide Node for canary render tests."
require_fixed flake/apps.nix 'settings_json="$(nix eval --json "$repo#lib.nixhomeserverSerializableSettings")"' \
  "Maintenance apps must discover the configured host instead of assuming a fixed hostname."
forbid_match flake/apps.nix 'nixhomeserverSettings[.]serverLanIP' \
  "Maintenance apps must not address host settings as though they were top-level attributes."
forbid_match scripts 'builtins[.]getFlake[[:space:]]*[(][[:space:]]*toString' \
  "Repository checks must use Git-filtered flake references so ignored build artifacts cannot break evaluation."
require_fixed scripts/helpers/repo-common.sh 'NIXHOMESERVER_FLAKE_REF_FOR_EVAL="path:$repo_root"' \
  "Manifest-filtered deployment archives must remain evaluable without a .git directory."
forbid_match scripts/tests/module-removal-matrix.nix 'self = repo;' \
  "Module-removal checks must not coerce the unfiltered working tree into the Nix store."

echo "✅ Core runtime safety regression tests passed."
