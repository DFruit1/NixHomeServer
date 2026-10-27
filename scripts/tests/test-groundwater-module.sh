#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/test-common.sh"
cd "$TESTS_REPO_ROOT"
ensure_tools nix jq rg

# Evaluate only the groundwater facets and their shared settings contracts.
# There is no nixosConfiguration, toplevel derivation, remote helper or build.
settings="$(flake_eval_json '
  pkgs = f.inputs.nixpkgs.legacyPackages.x86_64-linux;
  vars = import ./vars.nix { inherit lib; };
  catalog = import ./modules/catalog.nix;
  schema = { lib, ... }: {
    options = {
      age.secrets = lib.mkOption { type = lib.types.attrs; };
      assertions = lib.mkOption { type = lib.types.listOf lib.types.attrs; default = []; };
      nixhomeserver = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      services = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      systemd = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      users = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      networking = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
      repo.authGateway = lib.mkOption { type = lib.types.attrsOf lib.types.anything; };
      repo.backups = lib.mkOption { type = lib.types.attrsOf lib.types.anything; default = {}; };
    };
    config = {
      age.secrets = {
        groundwaterAppMqttPassword.path = "/run/agenix/groundwaterAppMqttPassword";
        groundwaterLoggerMqttPassword.path = "/run/agenix/groundwaterLoggerMqttPassword";
      };
      repo.authGateway = { enable = true; mode = "gateway"; };
      services.postgresql.dataDir = "/var/lib/postgresql/17";
    };
  };
  evaluate = modules: (lib.evalModules {
    modules = [ schema ] ++ modules;
    specialArgs = {
      inherit pkgs vars;
      appPackages.groundwater-server = "/groundwater-package";
    };
  }).config;
  enabled = evaluate [ ./modules/groundwater-logger ];
  disabled = evaluate [ ./modules/groundwater-logger {
    repo.groundwaterLogger.enable = false;
  } ];
  removed = evaluate [];
  noGateway = evaluate [ ./modules/groundwater-logger {
    repo.authGateway.enable = lib.mkForce false;
  } ];
  surface = cfg: {
    services = builtins.attrNames (cfg.systemd.services or {});
    groups = builtins.attrNames (cfg.services.kanidm.provision.groups or {});
    users = builtins.attrNames (cfg.users.users or {});
    gateway = builtins.attrNames (cfg.repo.authGateway.protectedApps or {});
    backups = cfg.repo.backups;
    firewall = cfg.networking.firewall or {};
    database = cfg.services.postgresql.ensureDatabases or [];
  };
  canary = import ./modules/Core_Modules/homepage/canary.nix {
    inherit lib pkgs vars;
    appPackages = {};
    config = {
      nixhomeserver.modules = enabled.nixhomeserver.modules;
      repo.authGateway.domain = "auth.${vars.domain}";
      services.caddy.virtualHosts = builtins.listToAttrs
        (map (app: lib.nameValuePair app.host {}) (builtins.attrValues enabled.repo.authGateway.protectedApps));
    };
  };
in {
  inherit (enabled) services users;
  unit = enabled.systemd.services.groundwater-server;
  backup = enabled.repo.backups;
  gateway = enabled.repo.authGateway.protectedApps.groundwater;
  firewall = enabled.networking.firewall;
  paths = enabled.repo.groundwaterLogger.paths;
  assertionsPass = lib.all (entry: entry.assertion) enabled.assertions;
  rejectsMissingGateway = lib.any (entry: !entry.assertion) noGateway.assertions;
  disabled = surface disabled;
  removed = surface removed;
  catalog = {
    inherit (catalog.apps.groundwater-logger) secrets guardedServices;
    ports = catalog.apps.groundwater-logger.registration.ports;
  };
  covered = canary.options.repo.canary.coveredHosts.default;
  host = "groundwater.${vars.domain}";
  lanIface = vars.networking.interfaces.lan;
  netbirdIface = vars.networking.interfaces.netbird;
  mqttAddresses = [ vars.networking.loopbackIPv4 vars.networking.lan.ip vars.networking.netbird.ip ];
  viewerMembers = enabled.services.kanidm.provision.groups.groundwater-user.members;
  canaryUser = vars.kanidmCanaryUser;
  ownerEnabled = builtins.elem "groundwater-logger" vars.enabledApps;
}')"

jq -e '
  .assertionsPass and .rejectsMissingGateway and .ownerEnabled
  and (.unit.serviceConfig.User == "groundwater")
  and (.unit.serviceConfig.Group == "groundwater")
  and (.unit.serviceConfig.ExecStart == "/groundwater-package/bin/groundwater-server")
  and (.unit.requires | sort == ["mosquitto.service", "postgresql.service"])
  and (.unit.after | index("postgresql.service") != null)
  and (.unit.environment.GROUNDWATER_DATABASE_URL == "postgresql:///?host=/run/postgresql&user=groundwater&dbname=groundwater")
  and (.unit.environment.GROUNDWATER_ADDRESS == "127.0.0.1")
  and (.unit.environment.GROUNDWATER_PORT == "8091")
  and (.unit.environment.GROUNDWATER_MQTT_URL == "mqtt://127.0.0.1:1883")
  and (.unit.environment.GROUNDWATER_MQTT_USERNAME == "groundwater-app")
  and (.unit.environment.GROUNDWATER_MQTT_PASSWORD_FILE == "%d/mqtt-password")
  and (.unit.serviceConfig.LoadCredential == ["mqtt-password:/run/agenix/groundwaterAppMqttPassword"])
  and (.unit.environment.GROUNDWATER_RETENTION_DAYS == "90")
  and (.unit.environment.GROUNDWATER_FRONTEND_DIR == "/groundwater-package/share/groundwater-server/frontend")
  and (.unit.serviceConfig.NoNewPrivileges and .unit.serviceConfig.PrivateTmp and .unit.serviceConfig.ProtectHome)
  and (.unit.serviceConfig.ProtectSystem == "strict")
  and (.unit.serviceConfig.ProtectKernelModules and .unit.serviceConfig.ProtectKernelTunables and .unit.serviceConfig.RestrictSUIDSGID)
  and (.unit.serviceConfig.RestrictAddressFamilies | sort == ["AF_INET", "AF_INET6", "AF_UNIX"])
  and (.unit.serviceConfig | has("ReadWritePaths") | not)
  and (.services.postgresql.ensureDatabases == ["groundwater"])
  and (.services.postgresql.ensureUsers == [{name:"groundwater",ensureDBOwnership:true}])
  and (.services.postgresql | has("settings") | not)
  and ((.services.mosquitto.listeners | map(.address) | sort) == (.mqttAddresses | sort))
  and (all(.services.mosquitto.listeners[]; .port == 1883 and (.users | keys == ["groundwater-app", "groundwater-logger"])))
  and (.firewall.interfaces[.lanIface].allowedTCPPorts == [1883])
  and (.firewall.interfaces[.netbirdIface].allowedTCPPorts == [1883])
  and (.firewall | has("allowedTCPPorts") | not)
  and (.gateway.allowedGroups | sort == ["app-admin", "groundwater-user"])
  and .gateway.apiUnauthenticated401
  and (.host as $host | .covered | index($host) != null)
  and (.canaryUser as $user | .viewerMembers | index($user) != null)
  and (.backup.postgresqlDumps == [{database:"groundwater",user:"groundwater",outputName:"groundwater.pgdump"}])
  and (.backup | has("sqliteDumps") | not)
  and (.backup.appStateEntries | map(.stateRoot) | sort == ["/var/lib/groundwater-logger", "/var/lib/groundwater-mosquitto", "/var/lib/postgresql/17"])
  and (.paths.database == "/var/lib/groundwater-logger/state/messages.sqlite")
  and (.users.users | has("groundwater-logger"))
  and (.catalog.guardedServices | sort == ["groundwater-server", "mosquitto"])
  and (.catalog.secrets | sort == ["groundwaterAppMqttPassword", "groundwaterLoggerMqttPassword"])
  and (all(.disabled, .removed; .services == [] and .groups == [] and .users == [] and .gateway == [] and .backups == {} and .firewall == {} and .database == []))
' <<<"$settings" >/dev/null

require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/groundwater-logger"' \
  "Groundwater removal must retain the historical SQLite archive."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/groundwater-mosquitto"' \
  "Groundwater removal must retain broker state."
require_fixed modules/Core_Modules/impermanence/default.nix '"/var/lib/postgresql"' \
  "Groundwater removal must retain PostgreSQL state."
for header in User Email Groups Preferred-Username; do
  require_fixed modules/Core_Modules/auth-gateway/default.nix "header_up -X-Auth-Request-$header" \
    "The loopback gateway must strip untrusted authentication headers."
done
echo '✅ Groundwater module settings, peer identity, private broker, backups, canary and disable/removal checks passed.'
