{ appPackages, config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.groundwaterLogger;
  paths = cfg.paths;
  listenAddress = vars.networking.loopbackIPv4;
  lanAddress = vars.networking.lan.ip;
  lanIface = vars.networking.interfaces.lan;
  mqttPort = vars.networking.ports.groundwaterMqtt;
  appPort = vars.networking.ports.groundwaterLogger;
  subscribeTopics = [
    "azman1/feeds/#"
    "testtopic/9"
    "requesttesta"
    "cmd/#"
    "cfg/#"
  ];
  subscribeTopicsCsv = lib.concatStringsSep "," subscribeTopics;
  appAcl = [
    "readwrite azman1/feeds/#"
    "readwrite testtopic/9"
    "readwrite requesttesta"
    "readwrite cmd/#"
    "readwrite cfg/#"
  ];
  loggerAcl = [
    "readwrite azman1/feeds/#"
    "readwrite testtopic/9"
    "read requesttesta"
    "read cmd/#"
    "read cfg/#"
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
  repairStateOwnership = pkgs.writeShellScript "groundwater-logger-repair-state-ownership" ''
    ${pkgs.coreutils}/bin/chown -R groundwater-logger:groundwater-logger ${lib.escapeShellArg paths.stateRoot}
  '';
in
{
  options.repo.groundwaterLogger.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Whether to enable the LAN MQTT groundwater logger test console.";
  };

  options.repo.groundwaterLogger.retention = {
    days = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Maximum age of retained MQTT messages.";
    };
    maximumMessages = lib.mkOption {
      type = lib.types.ints.positive;
      default = 500000;
      description = "Maximum number of retained MQTT messages.";
    };
  };

  config = lib.mkIf cfg.enable {
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
      ];
    };

    networking.firewall.interfaces.${lanIface}.allowedTCPPorts = [ mqttPort ];

    systemd.services.groundwater-logger = {
      description = "Groundwater logger MQTT test console";
      unitConfig = {
        StartLimitIntervalSec = "5min";
        StartLimitBurst = 5;
      };
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "mosquitto.service"
      ];
      after = [
        "network-online.target"
        "mosquitto.service"
      ];
      environment = {
        GROUNDWATER_LOGGER_HOST = listenAddress;
        GROUNDWATER_LOGGER_PORT = toString appPort;
        GROUNDWATER_LOGGER_STATE_DIR = paths.stateDir;
        GROUNDWATER_LOGGER_DATABASE = paths.database;
        GROUNDWATER_MQTT_URL = "mqtt://${listenAddress}:${toString mqttPort}";
        GROUNDWATER_MQTT_USERNAME = "groundwater-app";
        GROUNDWATER_MQTT_PASSWORD_FILE = config.age.secrets.groundwaterAppMqttPassword.path;
        GROUNDWATER_MQTT_SUBSCRIBE_TOPICS = subscribeTopicsCsv;
        GROUNDWATER_MQTT_DEFAULT_QOS = "1";
        GROUNDWATER_LOGGER_RETENTION_DAYS = toString cfg.retention.days;
        GROUNDWATER_LOGGER_MAXIMUM_MESSAGES = toString cfg.retention.maximumMessages;
      };
      serviceConfig = {
        Type = "simple";
        User = "groundwater-logger";
        Group = "groundwater-logger";
        ExecStart = "${appPackages.groundwater-logger}/bin/groundwater-logger";
        ExecStartPre = "+${repairStateOwnership}";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "60s";
        TimeoutStopSec = "15s";
        MemoryHigh = "384M";
        MemoryMax = "768M";
        OOMPolicy = "stop";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [
          paths.stateRoot
        ];
      };
    };
  };
}
