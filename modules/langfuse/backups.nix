{ config, lib, ... }:
{
  config = lib.mkIf config.repo.langfuse.enable {
    # ClickHouse is restored from the logical archive, so its raw store is
    # reproducible and stays excluded. MinIO events/media are unique object
    # data with no replay contract: they stay in the /persist snapshot.
    repo.backups.rebuildableSnapshotPaths = [
      "var/lib/clickhouse"
    ];
    systemd.services.backup-prepare.requires = [ "clickhouse.service" ];
    systemd.services.backup-prepare.after = [ "clickhouse.service" ];
    repo.backups = {
      appStateEntries = [ {
        app = "langfuse";
        stateRoot = "/var/lib/langfuse";
        payloadRoots = [ "/var/lib/clickhouse" "/var/lib/redis-langfuse" ];
        notes = "Object storage and ingestion queue. Restore PostgreSQL and ClickHouse from their logical backups; retained encrypted project credentials are required.";
      } ];
      postgresqlDumps = [ { database = "langfuse"; user = "langfuse"; outputName = "langfuse.pgdump"; } ];
      prepareFragments.langfuse = ''
        # BACKUP writes a consistent ClickHouse archive. Copy only that archive
        # into the central successful generation, never a live parts directory.
        # Raw ClickHouse is excluded from the snapshot, so a failed or partial
        # archive must abort the whole preparation: the central step would
        # otherwise verify present checksums, publish this generation and prune
        # the last complete archive.
        langfuse_clickhouse_backup() {
          local backup_name="langfuse-$(date --utc +%Y%m%dT%H%M%SZ)-$$.zip"
          local archive="/var/lib/langfuse/clickhouse-backups/$backup_name"

          # The client must come from the same package as the server, or a
          # future switch to a different ClickHouse build silently breaks
          # BACKUP/RESTORE compatibility with the archive format it writes.
          if ! ${config.services.clickhouse.package}/bin/clickhouse-client --config-file /run/langfuse/clickhouse-client.xml \
            --query "BACKUP DATABASE default TO Disk('backups', '$backup_name')"; then
            echo "Langfuse ClickHouse archive failed; aborting the backup preparation" >&2
            rm -f -- "$archive"
            return 1
          fi
          if [[ ! -s "$archive" ]]; then
            echo "Langfuse ClickHouse archive is missing or empty: $archive" >&2
            rm -f -- "$archive"
            return 1
          fi
          if ! cp -- "$archive" "$work/dumps/langfuse-clickhouse.zip"; then
            echo "Langfuse ClickHouse archive copy failed; aborting the backup preparation" >&2
            rm -f -- "$archive" "$work/dumps/langfuse-clickhouse.zip"
            return 1
          fi
          rm -f -- "$archive"
          if [[ ! -s "$work/dumps/langfuse-clickhouse.zip" ]]; then
            echo "Copied Langfuse ClickHouse archive is missing or empty" >&2
            rm -f -- "$work/dumps/langfuse-clickhouse.zip"
            return 1
          fi
          if ! (cd "$work"; sha256sum dumps/langfuse-clickhouse.zip) >> "$work/metadata/SHA256SUMS"; then
            echo "Langfuse ClickHouse archive checksum failed" >&2
            rm -f -- "$work/dumps/langfuse-clickhouse.zip"
            return 1
          fi
        }
        # Propagate explicitly instead of relying on errexit: this fragment is
        # generated shell, and errexit is suppressed for any command run in a
        # conditional or boolean context.
        langfuse_clickhouse_backup || exit 1
      '';
    };
  };
}
