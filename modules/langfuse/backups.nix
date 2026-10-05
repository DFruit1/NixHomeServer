{ config, lib, ... }:
{
  config = lib.mkIf config.repo.langfuse.enable {
    # ClickHouse is excluded because it is restored from the logical archive
    # published below, not from a live parts directory. MinIO is NOT excluded:
    # its event and media objects are not reconstructible from the databases,
    # so /persist keeps snapshotting them.
    repo.backups.rebuildableSnapshotPaths = [ "var/lib/clickhouse" ];
    systemd.services.backup-prepare.requires = [ "clickhouse.service" ];
    systemd.services.backup-prepare.after = [ "clickhouse.service" ];
    repo.backups = {
      appStateEntries = [ {
        app = "langfuse";
        stateRoot = "/var/lib/langfuse";
        payloadRoots = [ "/var/lib/clickhouse" "/var/lib/redis-langfuse" ];
        notes = "Object storage and ingestion queue. Restore PostgreSQL and ClickHouse from their logical backups; MinIO objects come from the /persist snapshot because they cannot be re-derived; retained encrypted project credentials are required.";
      } ];
      postgresqlDumps = [ { database = "langfuse"; user = "langfuse"; outputName = "langfuse.pgdump"; } ];
      prepareFragments.langfuse = ''
        # BACKUP writes a consistent ClickHouse archive. Copy only that archive
        # into the central successful generation, never a live parts directory.
        #
        # A ClickHouse outage must still publish the PostgreSQL dump collected
        # earlier this run, but it must never silently drop ClickHouse coverage:
        # generations are pruned to a fixed count, so publishing bare
        # generations would eventually evict the last restorable archive. On
        # failure the previous successful generation's archive is carried
        # forward after its recorded checksum is verified, and the generation is
        # marked degraded so the missing fresh archive is visible.
        langfuse_current_generation="${config.repo.backups.successfulCurrentPath}"
        langfuse_mark_degraded() {
          local reason="$1"
          local carried="$2"
          jq -n \
            --arg reason "$reason" \
            --arg carried "$carried" \
            --arg carriedFrom "$langfuse_previous_generation" \
            '{schemaVersion: 1, degraded: true, component: "langfuse-clickhouse",
              reason: $reason, retainedArchive: "dumps/langfuse-clickhouse.zip",
              archiveCarriedForward: $carried, previousGeneration: $carriedFrom}' \
            > "$work/metadata/degraded-langfuse-clickhouse.json"
          echo "Langfuse ClickHouse backup degraded: $reason" >&2
        }
        langfuse_retain_last_good() {
          local reason="$1"
          local previous_archive="$langfuse_previous_generation/dumps/langfuse-clickhouse.zip"
          local recorded

          rm -f -- "$work/dumps/langfuse-clickhouse.zip"
          if [[ -z "$langfuse_previous_generation" || ! -d "$langfuse_previous_generation/dumps" ]]; then
            langfuse_mark_degraded "$reason; no previous generation to carry forward" false
            return 0
          fi
          if [[ ! -s "$previous_archive" ]]; then
            langfuse_mark_degraded "$reason; the previous generation has no ClickHouse archive" false
            return 0
          fi
          # Trust the previous generation's own checksum line, not the file's
          # mere existence, before this generation inherits the archive.
          recorded="$(grep -F 'dumps/langfuse-clickhouse.zip' "$langfuse_previous_generation/metadata/SHA256SUMS" 2>/dev/null || true)"
          if [[ -z "$recorded" ]] || ! (cd "$langfuse_previous_generation" && printf '%s\n' "$recorded" | sha256sum --check --status -); then
            langfuse_mark_degraded "$reason; the previous ClickHouse archive failed checksum verification" false
            return 0
          fi
          if ! cp -- "$previous_archive" "$work/dumps/langfuse-clickhouse.zip"; then
            rm -f -- "$work/dumps/langfuse-clickhouse.zip"
            langfuse_mark_degraded "$reason; copying the previous ClickHouse archive failed" false
            return 0
          fi
          (cd "$work"; sha256sum dumps/langfuse-clickhouse.zip) >> "$work/metadata/SHA256SUMS"
          langfuse_mark_degraded "$reason; carrying forward the last verified ClickHouse archive" true
        }
        langfuse_previous_generation="$(readlink -f -- "$langfuse_current_generation" 2>/dev/null || true)"
        langfuse_clickhouse_backup() {
          local backup_name="langfuse-$(date --utc +%Y%m%dT%H%M%SZ)-$$.zip"
          local archive="/var/lib/langfuse/clickhouse-backups/$backup_name"

          # The client must come from the same package as the server, or a
          # future switch to a different ClickHouse build silently breaks
          # BACKUP/RESTORE compatibility with the archive format it writes.
          if ! ${config.services.clickhouse.package}/bin/clickhouse-client --config-file /run/langfuse/clickhouse-client.xml \
            --query "BACKUP DATABASE default TO Disk('backups', '$backup_name')"; then
            rm -f -- "$archive"
            langfuse_retain_last_good "ClickHouse BACKUP failed"
            return 0
          fi
          if ! cp -- "$archive" "$work/dumps/langfuse-clickhouse.zip"; then
            rm -f -- "$archive"
            langfuse_retain_last_good "ClickHouse archive copy failed"
            return 0
          fi
          rm -f -- "$archive"
          (cd "$work"; sha256sum dumps/langfuse-clickhouse.zip) >> "$work/metadata/SHA256SUMS"
        }
        langfuse_clickhouse_backup
      '';
    };
  };
}