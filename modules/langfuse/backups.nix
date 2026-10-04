{ config, lib, pkgs, ... }:
{
  config = lib.mkIf config.repo.langfuse.enable {
    # Both stores hold reproducible artifacts, not user data: ClickHouse is
    # restored from the logical archive and MinIO objects are re-uploaded by
    # the ingestion path. Excluding them keeps Kopia off the growth curve.
    repo.backups.rebuildableSnapshotPaths = [
      "var/lib/clickhouse"
      "var/lib/langfuse/minio"
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
        # The whole step is guarded: a ClickHouse outage must still publish the
        # PostgreSQL dump collected earlier this run, and must not leave a stale
        # archive or a checksum line for a file this generation does not have.
        langfuse_clickhouse_backup() {
          local backup_name="langfuse-$(date --utc +%Y%m%dT%H%M%SZ)-$$.zip"
          local archive="/var/lib/langfuse/clickhouse-backups/$backup_name"

          # The client must come from the same package as the server, or a
          # future switch to a different ClickHouse build silently breaks
          # BACKUP/RESTORE compatibility with the archive format it writes.
          if ! ${config.services.clickhouse.package}/bin/clickhouse-client --config-file /run/langfuse/clickhouse-client.xml \
            --query "BACKUP DATABASE default TO Disk('backups', '$backup_name')"; then
            echo "Langfuse ClickHouse archive failed; continuing without it" >&2
            rm -f -- "$archive"
            return 0
          fi
          if ! cp -- "$archive" "$work/dumps/langfuse-clickhouse.zip"; then
            echo "Langfuse ClickHouse archive copy failed; continuing without it" >&2
            rm -f -- "$archive" "$work/dumps/langfuse-clickhouse.zip"
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
