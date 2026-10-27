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
    CLICKHOUSE_MIGRATION_URL = "clickhouse://${loopback}:${toString vars.networking.ports.langfuseClickhouseTcp}";
    CLICKHOUSE_URL = "http://${loopback}:${toString vars.networking.ports.langfuseClickhouseHttp}";
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
    # Neither image needs Linux capabilities: minio and the Langfuse runtime
    # both run as an unprivileged user against their own bind-mounted state.
    extraOptions = [ "--memory=${memory}" "--memory-reservation=1g" "--security-opt=no-new-privileges" "--cap-drop=ALL" ];
  };
  # A rotated langfuseServerEnv makes langfuse-prepare rewrite /run/langfuse/*
  # and the Redis password file, and langfuse-db-bootstrap rotate the PostgreSQL
  # role password. A running process keeps the environment it started with, so
  # without these triggers the containers and stores would keep the superseded
  # credentials and fail against peers that already moved on - the app would
  # crash-loop instead of converging. Each consumer restarts when the encrypted
  # source changes, exactly like langfuse-prepare and langfuse-db-bootstrap.
  secretRestartTriggers = [ config.age.secrets.langfuseServerEnv.file ];
  # The interactive owner is the local administrator's Kanidm identity. Browser
  # sign-in now goes through Kanidm, and Langfuse links accounts by email, so
  # the headless-init owner must carry that account's mail address; otherwise
  # the first SSO sign-in would be turned away while signup stays disabled.
  ownerEmail =
    if builtins.hasAttr vars.localAdminUser vars.kanidmAppUserEmails then
      vars.kanidmAppUserEmails.${vars.localAdminUser}
    else
      vars.kanidmAdminEmail;
  # Non-secret half of the Langfuse custom OIDC provider. The client secret is
  # supplied separately through /run/langfuse/oidc.env.
  oidcEnvironment = {
    AUTH_CUSTOM_CLIENT_ID = "langfuse";
    AUTH_CUSTOM_ISSUER = vars.kanidmIssuer "langfuse";
    AUTH_CUSTOM_NAME = "Kanidm";
    AUTH_CUSTOM_SCOPE = "openid profile email";
    # Kanidm carries the profile in the id_token, but sourcing it from the
    # userinfo endpoint keeps the login working if a claim moves.
    AUTH_CUSTOM_FETCH_USERINFO = "true";
    # Migrate the existing email/password owner onto the Kanidm identity: once
    # the addresses match, Auth.js merges the accounts on first SSO sign-in.
    AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING = "true";
  };
  # ClickHouse creates each system log table from its config section only when
  # the table is missing, and the packaged config ships no TTL for the sections
  # below, so they grow without bound. On this host they were 1.86 GiB of the
  # 2.2 GiB ClickHouse footprint while Langfuse's own data was ~60 MiB, and
  # trace_log alone gains ~100 MiB/day. Bound the sections the package leaves
  # unbounded; the ones it already bounds (processors_profile_log,
  # asynchronous_insert_log, blob_storage_log, the zookeeper logs) are left
  # alone so their tables keep their definition. Adding a TTL to a table that
  # already exists makes ClickHouse rename it to <name>_N and create a fresh
  # bounded table, so a one-time drop of those copies reclaims the old rows.
  clickhouseLogTtl = days: table: {
    inherit table;
    database = "system";
    ttl = "event_date + INTERVAL ${toString days} DAY DELETE";
  };
  clickhouseLogTtls = {
    # Query profiler samples are the heaviest log and only aid short debugging.
    trace_log = clickhouseLogTtl 3 "trace_log";
    query_log = clickhouseLogTtl 7 "query_log";
    query_thread_log = clickhouseLogTtl 7 "query_thread_log";
    query_views_log = clickhouseLogTtl 7 "query_views_log";
    query_metric_log = clickhouseLogTtl 7 "query_metric_log";
    metric_log = clickhouseLogTtl 7 "metric_log";
    asynchronous_metric_log = clickhouseLogTtl 7 "asynchronous_metric_log";
    part_log = clickhouseLogTtl 7 "part_log";
    text_log = clickhouseLogTtl 7 "text_log";
    error_log = clickhouseLogTtl 7 "error_log";
    background_schedule_pool_log = clickhouseLogTtl 7 "background_schedule_pool_log";
    backup_log = clickhouseLogTtl 7 "backup_log";
    session_log = clickhouseLogTtl 7 "session_log";
    s3queue_log = clickhouseLogTtl 7 "s3queue_log";
    # The packaged config pins a full engine spec for this log because it
    # partitions by finish_date rather than event_date, and ClickHouse refuses a
    # separate `ttl` beside an `engine`, so the retention goes in the spec.
    opentelemetry_span_log = {
      database = "system";
      table = "opentelemetry_span_log";
      engine = "engine MergeTree partition by toYYYYMM(finish_date) order by (finish_date, finish_time_us) ttl finish_date + INTERVAL 7 DAY delete";
    };
  };
  # A data-store restart must not stay silent: bounded retries, then an alert.
  dataStoreUnit = overrides: {
    serviceConfig = overrides.serviceConfig // {
      Restart = lib.mkForce "on-failure";
      RestartSec = lib.mkForce "15s";
    };
    unitConfig = {
      # Enough headroom for a transient port or disk stall, low enough that a
      # permanently broken store alerts instead of looping indefinitely.
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 5;
      OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      OnFailureJobMode = "replace-irreversibly";
    };
  };
  appService = {
    requires = deps;
    after = deps;
    restartTriggers = secretRestartTriggers;
    # The readiness loop below waits on two endpoints, up to 90 attempts each at
    # 3s plus 2s of sleep, so its worst case is 900s. The container module
    # defaults this to 0, which would let a container that never becomes ready
    # hang forever instead; the previous 10min sat under that worst case, so
    # systemd could kill the unit while the loop was still legitimately waiting
    # on a cold ClickHouse or MinIO, which reads as a crash loop rather than a
    # slow start.
    serviceConfig = { Restart = "on-failure"; RestartSec = "10s"; TimeoutStartSec = lib.mkForce "25min"; MemoryHigh = "3G"; MemoryMax = "4G"; };
    unitConfig = {
      StartLimitIntervalSec = "10min";
      StartLimitBurst = 5;
      OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      OnFailureJobMode = "replace-irreversibly";
    };
    path = [ pkgs.curl pkgs.coreutils ];
    preStart = lib.mkBefore ''
      # OCI startup ordering alone does not imply database readiness.
      for endpoint in http://${loopback}:${toString vars.networking.ports.langfuseClickhouseHttp}/ping http://${loopback}:${s3Port}/minio/health/live; do
        ready=0
        for _attempt in $(seq 1 90); do
          if curl --fail --silent --max-time 3 "$endpoint" >/dev/null; then ready=1; break; fi
          sleep 2
        done
        test "$ready" = 1
      done
    '';
  };
  # Ingestion freshness: Redis, ClickHouse, MinIO and the app containers cover
  # their own failures through unit OnFailure alerting, but the only silent
  # failure mode is a worker that is running yet no longer consumes the
  # ingestion queues. The BullMQ queue depth detects that while staying
  # independent of fleet traffic: healthy processing drains wait+active within
  # seconds even under a whole-board burst, and an idle fleet reads as zero
  # depth. Trace timestamps are deliberately not the signal, because the fleet
  # legitimately idles. The four-queue family matches this Langfuse release
  # (verified against the live Redis key space): the standard and OTLP paths,
  # plus their secondary variants. The check skips its alert while Redis
  # itself is down - that outage alerting already covers it - and lives in
  # this module so it disappears with the app.
  ingestionStallQueueDepth = 500;
  ingestionFreshnessCheck = pkgs.writeShellApplication {
    name = "langfuse-ingestion-freshness";
    runtimeInputs = with pkgs; [ coreutils redis ];
    text = ''
      host="${loopback}"
      port="${toString vars.networking.ports.langfuseRedis}"
      password="$(tr -d '\r\n' < "$CREDENTIALS_DIRECTORY/redis-password")"

      redis() {
        ${pkgs.redis}/bin/redis-cli --no-auth-warning \
          -h "$host" -p "$port" -a "$password" "$@"
      }

      if [[ "$(redis PING 2>/dev/null)" != PONG ]]; then
        echo "Redis is down; its own failure alerting covers the outage. Skipping." >&2
        exit 0
      fi

      depth=0
      for queue in ingestion-queue otel-ingestion-queue \
                   secondary-ingestion-queue secondary-otel-ingestion-queue; do
        wait="$(redis LLEN "bull:$queue:wait")"
        active="$(redis ZCARD "bull:$queue:active")"
        depth=$((depth + wait + active))
        echo "ingestion queue depth: $queue (wait: $wait, active: $active)"
      done
      echo "ingestion queue depth: $depth (total)"

      if (( depth > ${toString ingestionStallQueueDepth} )); then
        echo "Langfuse ingestion stalled: queue depth $depth (across the ingestion queue family) exceeds the ${toString ingestionStallQueueDepth} bound" >&2
        exit 1
      fi
    '';
  };
  ingestionFreshnessHardening = {
    serviceConfig = {
      Type = "oneshot";
      ExecStart = "${ingestionFreshnessCheck}/bin/langfuse-ingestion-freshness";
      LoadCredential = [ "redis-password:/run/langfuse-redis/password" ];
      DynamicUser = true;
      NoNewPrivileges = true;
      PrivateDevices = true;
      PrivateTmp = true;
      ProtectClock = true;
      ProtectControlGroups = true;
      ProtectHome = true;
      ProtectHostname = true;
      ProtectKernelLogs = true;
      ProtectKernelModules = true;
      ProtectKernelTunables = true;
      ProtectSystem = "strict";
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" ];
      RestrictNamespaces = true;
      RestrictSUIDSGID = true;
      SystemCallArchitectures = "native";
      UMask = "0077";
    };
    unitConfig = {
      OnFailure = [ config.repo.monitoring.failureAlerts.targetUnit ];
      OnFailureJobMode = "replace-irreversibly";
    };
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
      restartTriggers = secretRestartTriggers;
    } // dataStoreUnit {
      serviceConfig = { MemoryHigh = "768M"; MemoryMax = "1G"; };
    };
    services.clickhouse = {
      enable = true;
      serverConfig = clickhouseLogTtls // {
        listen_host = loopback;
        # Langfuse writes UTC date strings; a local timezone shifts stored instants.
        timezone = "UTC";
        http_port = vars.networking.ports.langfuseClickhouseHttp;
        tcp_port = vars.networking.ports.langfuseClickhouseTcp;
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
      restartTriggers = secretRestartTriggers;
    } // dataStoreUnit {
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
        cmd = [ "server" "--address" "${loopback}:${s3Port}" "--console-address" "${loopback}:${toString vars.networking.ports.langfuseS3Console}" "/data" ];
        extraOptions = [ "--memory=2g" "--memory-reservation=1g" "--security-opt=no-new-privileges" "--cap-drop=ALL" ];
      };
      langfuse-web = (container "docker.langfuse.com/langfuse/langfuse@sha256:3d2ae888a0e6edb41fdba6e7d5baca5e4baede3a870dac7970dadd9d925b018e" "4g") // {
        serviceName = "langfuse-web";
        environmentFiles = [ "/run/langfuse/app.env" "/run/langfuse/web.env" "/run/langfuse/oidc.env" ];
        environment = commonEnvironment // oidcEnvironment // {
          HOSTNAME = loopback;
          PORT = webPort;
          AUTH_DISABLE_SIGNUP = "true";
          LANGFUSE_INIT_ORG_ID = "nixhomeserver";
          LANGFUSE_INIT_ORG_NAME = "NixHomeServer";
          LANGFUSE_INIT_PROJECT_ID = "ai-usage";
          LANGFUSE_INIT_PROJECT_NAME = "AI Usage";
          LANGFUSE_INIT_USER_EMAIL = ownerEmail;
          LANGFUSE_INIT_USER_NAME = vars.localAdminUser;
        };
      };
      langfuse-worker = (container "docker.langfuse.com/langfuse/langfuse-worker@sha256:52f7fd41ded2f1a6acab13ff7cb1832d36dfe2cbf44adea402b7a09cfa4ce800" "4g") // {
        serviceName = "langfuse-worker";
        environment = commonEnvironment // { PORT = toString vars.networking.ports.langfuseWorker; HOSTNAME = loopback; };
      };
    };
    systemd.services.langfuse-minio = {
      requires = [ "langfuse-prepare.service" ];
      after = [ "langfuse-prepare.service" ];
      restartTriggers = secretRestartTriggers;
    } // dataStoreUnit {
      serviceConfig = { MemoryHigh = "1G"; MemoryMax = "2G"; };
    };
    systemd.services.langfuse-web = appService // {
      # A rotated OIDC client secret must reach the running container too.
      restartTriggers = secretRestartTriggers ++ [ config.age.secrets.langfuseClientSecret.file ];
    };
    systemd.services.langfuse-worker = appService;
    systemd.services.langfuse-ingestion-freshness = ingestionFreshnessHardening;
    systemd.timers.langfuse-ingestion-freshness = {
      wantedBy = [ "timers.target" ];
      timerConfig = {
        # A stuck worker reaches the depth bound well inside one interval, so a
        # 15 minute check cadence is enough; boot persistence catches ticks a
        # restart skips.
        OnBootSec = "5min";
        OnUnitActiveSec = "15min";
        Persistent = true;
      };
    };
  };
}
