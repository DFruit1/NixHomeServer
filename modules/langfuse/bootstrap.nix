{ config, lib, pkgs, ... }:
let cfg = config.repo.langfuse;
in {
  config = lib.mkIf cfg.enable {
    age.secrets.langfuseServerEnv = {
      file = ../../secrets/langfuseServerEnv.age;
      owner = "root";
      mode = "0400";
    };
    systemd.services.langfuse-db-bootstrap = {
      description = "Set the Langfuse role password in the shared PostgreSQL cluster";
      requires = [ "postgresql.service" "langfuse-prepare.service" ];
      after = [ "postgresql.service" "langfuse-prepare.service" ];
      path = [ pkgs.coreutils pkgs.gnused pkgs.util-linux config.services.postgresql.package ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; UMask = "0077"; Nice = 10; CPUWeight = 20; IOWeight = 20; MemoryHigh = "128M"; MemoryMax = "256M"; };
      script = ''
        set -euo pipefail
        password="$(sed -n 's/^POSTGRES_PASSWORD=//p' ${lib.escapeShellArg config.age.secrets.langfuseServerEnv.path})"
        [[ "$password" =~ ^[a-f0-9]{64}$ ]]
        printf "ALTER ROLE langfuse PASSWORD '%s';\n" "$password" | \
          runuser -u postgres -- psql --no-psqlrc --set ON_ERROR_STOP=1 --dbname postgres >/dev/null
      '';
    };
    systemd.services.langfuse-prepare = {
      description = "Prepare Langfuse state and scoped credentials";
      wantedBy = [ "multi-user.target" ];
      after = [ "local-fs.target" ];
      before = [ "langfuse-db-bootstrap.service" "redis-langfuse.service" "clickhouse.service" "langfuse-minio.service" ];
      path = [ pkgs.coreutils pkgs.gnugrep pkgs.gnused ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        RuntimeDirectory = [ "langfuse" "langfuse-redis" ];
        RuntimeDirectoryMode = "0700";
        UMask = "0077";
        Nice = 10;
        CPUWeight = 20;
        IOWeight = 20;
        MemoryHigh = "128M";
        MemoryMax = "256M";
      };
      script = ''
        set -euo pipefail
        install -d -m 0755 /var/lib/langfuse
        install -d -m 0750 -o clickhouse -g clickhouse /var/lib/langfuse/clickhouse-backups
        install -d -m 0750 -o 65532 -g 65532 /var/lib/langfuse/minio /var/lib/langfuse/minio/langfuse
        chown redis-langfuse:redis-langfuse /run/langfuse-redis
        # Split the generated environment without evaluating it as shell code.
        # Each infrastructure service receives only its own credential.
        source_file=${lib.escapeShellArg config.age.secrets.langfuseServerEnv.path}
        sed -n 's/^REDIS_AUTH=//p' "$source_file" > /run/langfuse-redis/password
        chown redis-langfuse:redis-langfuse /run/langfuse-redis/password
        chmod 0400 /run/langfuse-redis/password
        grep -E '^CLICKHOUSE_PASSWORD=' "$source_file" > /run/langfuse/clickhouse.env
        grep -E '^MINIO_ROOT_PASSWORD=' "$source_file" > /run/langfuse/minio.env
        printf 'MINIO_ROOT_USER=langfuse\n' >> /run/langfuse/minio.env
        grep -E '^(SALT|ENCRYPTION_KEY|CLICKHOUSE_PASSWORD|REDIS_AUTH)=' "$source_file" > /run/langfuse/app.env
        pg_password="$(sed -n 's/^POSTGRES_PASSWORD=//p' "$source_file")"
        s3_password="$(sed -n 's/^MINIO_ROOT_PASSWORD=//p' "$source_file")"
        [[ "$pg_password" =~ ^[a-f0-9]{64}$ && "$s3_password" =~ ^[a-f0-9]{64}$ ]]
        printf 'DATABASE_URL=postgresql://langfuse:%s@127.0.0.1:5432/langfuse\n' "$pg_password" >> /run/langfuse/app.env
        printf 'LANGFUSE_S3_EVENT_UPLOAD_SECRET_ACCESS_KEY=%s\nLANGFUSE_S3_MEDIA_UPLOAD_SECRET_ACCESS_KEY=%s\n' \
          "$s3_password" "$s3_password" >> /run/langfuse/app.env
        grep -E '^(NEXTAUTH_SECRET|LANGFUSE_INIT_)' "$source_file" > /run/langfuse/web.env
        clickhouse_password="$(sed -n 's/^CLICKHOUSE_PASSWORD=//p' "$source_file")"
        [[ "$clickhouse_password" =~ ^[a-f0-9]{64}$ ]]
        printf '<config><host>127.0.0.1</host><port>9140</port><user>langfuse</user><password>%s</password></config>\n' \
          "$clickhouse_password" > /run/langfuse/clickhouse-client.xml
        chmod 0600 /run/langfuse/*.env /run/langfuse/clickhouse-client.xml
      '';
    };
  };
}
