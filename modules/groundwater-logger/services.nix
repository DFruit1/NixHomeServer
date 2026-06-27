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
    "topic readwrite azman1/feeds/#"
    "topic readwrite testtopic/9"
    "topic readwrite requesttesta"
    "topic readwrite cmd/#"
    "topic readwrite cfg/#"
  ];
  loggerAcl = [
    "topic readwrite azman1/feeds/#"
    "topic readwrite testtopic/9"
    "topic read requesttesta"
    "topic read cmd/#"
    "topic read cfg/#"
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
    description = "Whether to enable the LAN MQTT groundwater logger test console.";
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
      wantedBy = [ "multi-user.target" ];
      wants = [
        "network-online.target"
        "mosquitto.service"
      ];
      after = [
        "network-online.target"
        "mosquitto.service"
      ];
      path = with pkgs; [
        sqlite
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
      };
      serviceConfig = {
        Type = "simple";
        User = "groundwater-logger";
        Group = "groundwater-logger";
        ExecStart = "${appPackages.groundwater-logger}/bin/groundwater-logger";
        Restart = "on-failure";
        RestartSec = "5s";
        TimeoutStartSec = "60s";
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
