{ appPackages, config, lib, vars, ... }:

let
  cfg = config.repo.groundwaterLogger;
  paths = cfg.paths;
  listenAddress = vars.networking.loopbackIPv4;
  lanAddress = vars.networking.lan.ip;
  lanIface = vars.networking.interfaces.lan;
  netbirdAddress = vars.networking.netbird.ip;
  netbirdIface = vars.networking.interfaces.netbird;
  mqttPort = vars.networking.ports.groundwaterMqtt;
  appPort = vars.networking.ports.groundwaterLogger;
  appAcl = [
    "readwrite gwl/v1/#"
    "readwrite azman1/feeds/#"
    "readwrite testtopic/9"
    "readwrite requesttesta"
    "readwrite cmd/#"
    "readwrite cfg/#"
  ];
  loggerAcl = [
    "write gwl/v1/+/reading"
    "write gwl/v1/+/status"
    "write gwl/v1/+/gps"
    "write gwl/v1/+/storage"
    "write gwl/v1/+/motion"
    "write gwl/v1/+/alerts"
    "write gwl/v1/+/test/result"
    "write gwl/v1/+/config/applied"
    "write gwl/v1/+/cmd/ack"
    "write gwl/v1/+/info"
    "read gwl/v1/+/config/set"
    "read gwl/v1/+/config/desired"
    "read gwl/v1/+/cmd/test"
    "read gwl/v1/+/cmd/danger"
    "readwrite azman1/feeds/#"
    "readwrite testtopic/9"
    "read requesttesta"
    "read cmd/#"
    "read cfg/#"
    "write cfg/desired/applied"
    "write cfg/danger_ack"
  ];
  listenerUsers = {
    groundwater-app = {
      passwordFile = config.age.secrets.groundwaterAppMqttPassword.path;
      acl = appAcl;
    };
    groundwater-logger = {
      passwordFile = config.age.secrets.groundwaterLoggerMqttPassword.path;
      acl = loggerAcl;
    };
  };
in
{
  options.repo.groundwaterLogger.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable the private groundwater platform and MQTT broker.";
  };

  options.repo.groundwaterLogger.retention = {
    days = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Maximum age of the raw MQTT delivery log; observations and audit records are retained.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Match the Unix service identity for passwordless local peer auth. This
    # app owns only its role/database; shared cluster tuning stays central.
    services.postgresql = {
      enable = true;
      ensureDatabases = [ "groundwater" ];
      ensureUsers = [{ name = "groundwater"; ensureDBOwnership = true; }];
    };

    services.mosquitto = {
      enable = true;
      persistence = true;
      dataDir = paths.brokerStateDir;
      listeners = [
        {
          address = listenAddress;
          port = mqttPort;
          users = listenerUsers;
        }
        {
          address = lanAddress;
          port = mqttPort;
          users = listenerUsers;
        }
        {
          address = netbirdAddress;
          port = mqttPort;
          users = listenerUsers;
        }
      ];
    };

    networking.firewall.interfaces.${lanIface}.allowedTCPPorts = [ mqttPort ];
    networking.firewall.interfaces.${netbirdIface}.allowedTCPPorts = [ mqttPort ];

    # The overlay address must exist before Mosquitto binds it. The NetBird
    # client belongs to Core_Modules and remains present when this app is off.
    systemd.services.mosquitto = {
      wants = [ "netbird-address-verify.service" ];
      after = [ "netbird-address-verify.service" ];
    };

    systemd.services.groundwater-server = {
      description = "Groundwater telemetry, commands and private web platform";
      unitConfig = {
        StartLimitIntervalSec = "5min";
        StartLimitBurst = 5;
      };
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
      ];
      requires = [ "postgresql.service" "mosquitto.service" ];
      after = [
        "network-online.target"
        "mosquitto.service"
        "postgresql.service"
      ];
      environment = {
        GROUNDWATER_DATABASE_URL = "postgresql:///?host=/run/postgresql&user=groundwater&dbname=groundwater";
        GROUNDWATER_ADDRESS = listenAddress;
        GROUNDWATER_PORT = toString appPort;
        GROUNDWATER_MQTT_URL = "mqtt://${listenAddress}:${toString mqttPort}";
        GROUNDWATER_MQTT_USERNAME = "groundwater-app";
        GROUNDWATER_MQTT_PASSWORD_FILE = "%d/mqtt-password";
        GROUNDWATER_RETENTION_DAYS = toString cfg.retention.days;
        GROUNDWATER_FRONTEND_DIR = "${appPackages.groundwater-server}/share/groundwater-server/frontend";
      };
      serviceConfig = {
        Type = "simple";
        User = "groundwater";
        Group = "groundwater";
        ExecStart = "${appPackages.groundwater-server}/bin/groundwater-server";
        # PID 1 reads the existing agenix file; the new Unix identity never
        # needs access to the retained logger account or its historical files.
        LoadCredential = [ "mqtt-password:${config.age.secrets.groundwaterAppMqttPassword.path}" ];
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "60s";
        TimeoutStopSec = "15s";
        MemoryHigh = "384M";
        MemoryMax = "768M";
        OOMPolicy = "stop";
        UMask = "0077";
        CPUWeight = 20;
        Nice = 5;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectClock = true;
        ProtectControlGroups = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelModules = true;
        ProtectKernelTunables = true;
        LockPersonality = true;
        RestrictSUIDSGID = true;
        RestrictNamespaces = true;
        RestrictAddressFamilies = [
          "AF_INET"
          "AF_INET6"
          "AF_UNIX"
        ];
        SystemCallArchitectures = "native";
      };
    };
  };
}
