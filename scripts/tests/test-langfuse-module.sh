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
  freshnessExec = cfg.systemd.services.langfuse-ingestion-freshness.serviceConfig.ExecStart or null;
  freshnessCredential = cfg.systemd.services.langfuse-ingestion-freshness.serviceConfig.LoadCredential or [];
  freshnessOnFailure = cfg.systemd.services.langfuse-ingestion-freshness.unitConfig.OnFailure or [];
  freshnessTimer = cfg.systemd.timers.\"langfuse-ingestion-freshness\".timerConfig or {};
  prepareTriggers = cfg.systemd.services.langfuse-prepare.restartTriggers;
  bootstrapTriggers = cfg.systemd.services.langfuse-db-bootstrap.restartTriggers;
  consumerTriggers = map (name: cfg.systemd.services.\${name}.restartTriggers)
    [ \"langfuse-web\" \"langfuse-worker\" \"langfuse-minio\" \"clickhouse\" \"redis-langfuse\" ];
  webEnvironment = containers.langfuse-web.environment;
  webEnvironmentFiles = containers.langfuse-web.environmentFiles;
  oauth2Client = cfg.services.kanidm.provision.systems.oauth2.langfuse;
  oauth2SecretMode = cfg.age.secrets.langfuseClientSecret.mode;
  expectedOwnerEmail = vars.kanidmAppUserEmails.\${vars.localAdminUser} or vars.kanidmAdminEmail;
  backupWants = cfg.systemd.services.backup-prepare.wants;
  backupRequires = cfg.systemd.services.backup-prepare.requires;
  containerOptions = map (name: containers.\${name}.extraOptions)
    [ \"langfuse-web\" \"langfuse-worker\" \"langfuse-minio\" ];
  postgresTimezone = cfg.services.postgresql.settings.timezone or null;
  rebuildable = cfg.repo.backups.rebuildableSnapshotPaths;
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
  and .clickhouse.trace_log.database == "system"
  and .clickhouse.trace_log.ttl == "event_date + INTERVAL 3 DAY DELETE"
  and .clickhouse.query_log.ttl == "event_date + INTERVAL 7 DAY DELETE"
  and ([ .clickhouse | to_entries[] | select(.key | endswith("_log")) | .value.ttl ]
       | length == 15 and all(endswith("DELETE")))
  and (.clickhouse.processors_profile_log | not)
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
  and (.freshnessExec | test("/bin/langfuse-ingestion-freshness$") != null)
  and .freshnessCredential == ["redis-password:/run/langfuse-redis/password"]
  and (.freshnessOnFailure | length) == 1
  and .freshnessTimer.OnUnitActiveSec == "15min"
  and .freshnessTimer.Persistent == true
  and (.prepareTriggers | length) == 2 and (.bootstrapTriggers | length) == 1
  and (.consumerTriggers[0] | length) == 2
  and all(.consumerTriggers[1:][]; length == 1)
  and .webEnvironment.AUTH_CUSTOM_CLIENT_ID == "langfuse"
  and .webEnvironment.AUTH_CUSTOM_NAME == "Kanidm"
  and (.webEnvironment.AUTH_CUSTOM_ISSUER | startswith("https://id."))
  and (.webEnvironment.AUTH_CUSTOM_ISSUER | endswith("/oauth2/openid/langfuse"))
  and .webEnvironment.AUTH_CUSTOM_ALLOW_ACCOUNT_LINKING == "true"
  and .webEnvironment.LANGFUSE_INIT_USER_EMAIL == .expectedOwnerEmail
  and (.webEnvironmentFiles | index("/run/langfuse/oidc.env")) != null
  and .oauth2Client.basicSecretFile == "/run/agenix/langfuseClientSecret"
  and (.oauth2Client.originUrl | endswith("/api/auth/callback/custom"))
  and .oauth2Client.scopeMaps."langfuse-users" == ["openid","profile","email"]
  and .oauth2SecretMode == "0440"
  and (.backupWants | index("clickhouse.service")) != null
  and ((.backupRequires | index("clickhouse.service")) == null)
  and all(.containerOptions[]; index("--cap-drop=ALL") != null)
  and .postgresTimezone == "UTC"
  and (.rebuildable | index("var/lib/clickhouse") != null)
  and (.rebuildable | index("var/lib/langfuse/minio") != null)
  and (.fragment | contains("langfuse_clickhouse_backup"))
  and (.fragment | contains("if ! /nix/store/"))
  and (.fragment | contains("BACKUP DATABASE default TO Disk("))
  and (.fragment | contains("return 0"))
  and (.seedScript | contains("seed_directory /var/lib/clickhouse"))
  and (.seedScript | contains("seed_directory /var/lib/langfuse"))
  and (.seedScript | contains("seed_directory /var/lib/redis-langfuse"))
' <<<"$value" >/dev/null
# Persistence entries can be either a path string or a directory record.
for path in /var/lib/langfuse /var/lib/clickhouse /var/lib/redis-langfuse; do
  jq -e --arg path "$path" '.persistence | any(. == $path or (type == "object" and .directory == $path))' <<<"$value" >/dev/null
done
echo 'Langfuse reuses platform dependencies, keeps private routing, and retains backup state.'
