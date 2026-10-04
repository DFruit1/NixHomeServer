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
' <<<"$value" >/dev/null
# Persistence entries can be either a path string or a directory record.
for path in /var/lib/langfuse /var/lib/clickhouse /var/lib/redis-langfuse; do
  jq -e --arg path "$path" '.persistence | any(. == $path or (type == "object" and .directory == $path))' <<<"$value" >/dev/null
done
echo 'Langfuse reuses platform dependencies, keeps private routing, and retains backup state.'
