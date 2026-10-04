{ config, lib, pkgs, vars, ... }:
let
  cfg = config.repo.langfuse;
  loopback = vars.networking.loopbackIPv4;
  webPort = toString cfg.port;
  s3Port = toString vars.networking.ports.langfuseS3;
  deps = [ "langfuse-prepare.service" "langfuse-db-bootstrap.service" "redis-langfuse.service" "clickhouse.service" "langfuse-minio.service" ];
  commonEnvironment = {
    NEXTAUTH_URL = "https://langfuse.${vars.domain}";
    TELEMETRY_ENABLED = "false";
    CLICKHOUSE_MIGRATION_URL = "clickhouse://${loopback}:9140";
    CLICKHOUSE_URL = "http://${loopback}:8140";
    CLICKHOUSE_USER = "langfuse";
    CLICKHOUSE_CLUSTER_ENABLED = "false";
    REDIS_HOST = loopback;
    REDIS_PORT = toString vars.networking.ports.langfuseRedis;
    REDIS_TLS_ENABLED = "false";
    LANGFUSE_S3_EVENT_UPLOAD_BUCKET = "langfuse";
    LANGFUSE_S3_EVENT_UPLOAD_REGION = "us-east-1";
    LANGFUSE_S3_EVENT_UPLOAD_ACCESS_KEY_ID = "langfuse";
    LANGFUSE_S3_EVENT_UPLOAD_ENDPOINT = "http://${loopback}:${s3Port}";
    LANGFUSE_S3_EVENT_UPLOAD_FORCE_PATH_STYLE = "true";
    LANGFUSE_S3_EVENT_UPLOAD_PREFIX = "events/";
    LANGFUSE_S3_MEDIA_UPLOAD_BUCKET = "langfuse";
    LANGFUSE_S3_MEDIA_UPLOAD_REGION = "us-east-1";
    LANGFUSE_S3_MEDIA_UPLOAD_ACCESS_KEY_ID = "langfuse";
    LANGFUSE_S3_MEDIA_UPLOAD_ENDPOINT = "http://${loopback}:${s3Port}";
    LANGFUSE_S3_MEDIA_UPLOAD_FORCE_PATH_STYLE = "true";
    LANGFUSE_S3_MEDIA_UPLOAD_PREFIX = "media/";
  };
  container = image: memory: {
    inherit image;
    pull = "missing";
    networks = [ "host" ];
    environment = commonEnvironment;
    environmentFiles = [ "/run/langfuse/app.env" ];
    extraOptions = [ "--memory=${memory}" "--memory-reservation=1g" "--security-opt=no-new-privileges" ];
  };
  appService = {
    requires = deps;
    after = deps;
    serviceConfig = { Restart = "on-failure"; RestartSec = "10s"; TimeoutStartSec = lib.mkForce "10min"; MemoryHigh = "3G"; MemoryMax = "4G"; };
    path = [ pkgs.curl pkgs.coreutils ];
    preStart = lib.mkBefore ''
      # OCI startup ordering alone does not imply database readiness.
      for endpoint in http://${loopback}:8140/ping http://${loopback}:${s3Port}/minio/health/live; do
        ready=0
        for _attempt in $(seq 1 90); do
          if curl --fail --silent --max-time 3 "$endpoint" >/dev/null; then ready=1; break; fi
          sleep 2
        done
        test "$ready" = 1
      done
    '';
  };
in {
  options.repo.langfuse = {
    enable = lib.mkOption { type = lib.types.bool; default = true; description = "Enable private Langfuse observability."; };
    port = lib.mkOption { type = lib.types.port; default = vars.networking.ports.langfuse; };
  };
  config = lib.mkIf cfg.enable {
    # Reuse the shared PostgreSQL cluster and repository-pinned native services.
    # Langfuse is the backend; this module adds no new backend implementation.
    services.postgresql = {
      enable = true;
      ensureDatabases = [ "langfuse" ];
      ensureUsers = [ { name = "langfuse"; ensureDBOwnership = true; } ];
      authentication = lib.mkBefore "host langfuse langfuse 127.0.0.1/32 scram-sha-256\n";
    };
    services.redis.servers.langfuse = {
      enable = true;
      bind = loopback;
      port = vars.networking.ports.langfuseRedis;
      requirePassFile = "/run/langfuse-redis/password";
      appendOnly = true;
    };
    systemd.services.redis-langfuse = {
      requires = [ "langfuse-prepare.service" ];
      after = [ "langfuse-prepare.service" ];
      serviceConfig = { MemoryHigh = "768M"; MemoryMax = "1G"; };
    };
    services.clickhouse = {
      enable = true;
      serverConfig = {
        listen_host = loopback;
        http_port = 8140;
        tcp_port = 9140;
        max_server_memory_usage = 4294967296;
        storage_configuration.disks.backups = { type = "local"; path = "/var/lib/langfuse/clickhouse-backups/"; };
        backups.allowed_disk = "backups";
      };
      extraUsersConfig = ''
        <clickhouse><users>
          <default remove="remove"/>
          <langfuse>
            <password from_env="CLICKHOUSE_PASSWORD"/>
            <networks><ip>127.0.0.1</ip></networks>
            <profile>default</profile><quota>default</quota>
            <access_management>1</access_management>
          </langfuse>
        </users></clickhouse>
      '';
    };
    systemd.services.clickhouse = {
      requires = [ "langfuse-prepare.service" ];
      after = [ "langfuse-prepare.service" ];
      serviceConfig = { EnvironmentFile = "/run/langfuse/clickhouse.env"; MemoryHigh = "4G"; MemoryMax = "5G"; };
    };
    # Application images follow the upstream runtime contract. PostgreSQL,
    # Redis, and ClickHouse reuse the repository-pinned native packages.
    virtualisation.oci-containers.containers = {
      langfuse-minio = {
        # Nixpkgs MinIO is insecure; upstream Langfuse uses this maintained image.
        image = "cgr.dev/chainguard/minio@sha256:4cf4831a2bbcf13ddca09c1cbcc9faff716dd3c4247e0babc32864b8ee8e0034";
        serviceName = "langfuse-minio";
        pull = "missing";
        networks = [ "host" ];
        environmentFiles = [ "/run/langfuse/minio.env" ];
        volumes = [ "/var/lib/langfuse/minio:/data" ];
        cmd = [ "server" "--address" "${loopback}:${s3Port}" "--console-address" "${loopback}:9041" "/data" ];
        extraOptions = [ "--memory=2g" "--memory-reservation=1g" "--security-opt=no-new-privileges" ];
      };
      langfuse-web = (container "docker.langfuse.com/langfuse/langfuse@sha256:3d2ae888a0e6edb41fdba6e7d5baca5e4baede3a870dac7970dadd9d925b018e" "4g") // {
        serviceName = "langfuse-web";
        environmentFiles = [ "/run/langfuse/app.env" "/run/langfuse/web.env" ];
        environment = commonEnvironment // {
          HOSTNAME = loopback;
          PORT = webPort;
          AUTH_DISABLE_SIGNUP = "true";
          LANGFUSE_INIT_ORG_ID = "nixhomeserver";
          LANGFUSE_INIT_ORG_NAME = "NixHomeServer";
          LANGFUSE_INIT_PROJECT_ID = "hermes";
          LANGFUSE_INIT_PROJECT_NAME = "Hermes";
          LANGFUSE_INIT_USER_EMAIL = vars.kanidmAdminEmail;
          LANGFUSE_INIT_USER_NAME = vars.localAdminUser;
        };
      };
      langfuse-worker = (container "docker.langfuse.com/langfuse/langfuse-worker@sha256:52f7fd41ded2f1a6acab13ff7cb1832d36dfe2cbf44adea402b7a09cfa4ce800" "4g") // {
        serviceName = "langfuse-worker";
        environment = commonEnvironment // { PORT = "3041"; HOSTNAME = loopback; };
      };
    };
    systemd.services.langfuse-minio = {
      requires = [ "langfuse-prepare.service" ];
      after = [ "langfuse-prepare.service" ];
      serviceConfig = { MemoryHigh = "1G"; MemoryMax = "2G"; };
    };
    systemd.services.langfuse-web = appService;
    systemd.services.langfuse-worker = appService;
  };
}
