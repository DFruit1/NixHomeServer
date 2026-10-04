{ config, lib, pkgs, ... }:
{
  config = lib.mkIf config.repo.langfuse.enable {
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
        backup_name="langfuse-$(date --utc +%Y%m%dT%H%M%SZ)-$$.zip"
        ${pkgs.clickhouse}/bin/clickhouse-client --config-file /run/langfuse/clickhouse-client.xml \
          --query "BACKUP DATABASE default TO Disk('backups', '$backup_name')"
        cp "/var/lib/langfuse/clickhouse-backups/$backup_name" "$work/dumps/langfuse-clickhouse.zip"
        rm "/var/lib/langfuse/clickhouse-backups/$backup_name"
        (cd "$work"; sha256sum dumps/langfuse-clickhouse.zip) >> "$work/metadata/SHA256SUMS"
      '';
    };
  };
}
