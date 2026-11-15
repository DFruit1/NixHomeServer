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
  mqttTlsPort = vars.networking.ports.groundwaterMqttTls;
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
  loggerUser = {
    groundwater-logger = {
      passwordFile = config.age.secrets.groundwaterLoggerMqttPassword.path;
      acl = loggerAcl;
    };
  };
  listenerUsers = loggerUser // {
    groundwater-app = {
      passwordFile = config.age.secrets.groundwaterAppMqttPassword.path;
      acl = appAcl;
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
        # Internet-facing TLS endpoint for field loggers: the router forwards
        # public TCP 8883 to this LAN address. Only the logger account exists
        # here, so the web app's broad ACL is never reachable from outside.
        # Ciphers stay at OpenSSL defaults; the Quectel EC21 needs RSA
        # certificates with ECDHE-RSA AES-CBC/GCM suites.
        {
          address = lanAddress;
          port = mqttTlsPort;
          users = loggerUser;
          settings = {
            certfile = "${./mqtt-tls/server.pem}";
            keyfile = config.age.secrets.groundwaterMqttTlsKey.path;
            tls_version = "tlsv1.2";
            require_certificate = false;
          };
        }
      ];
    };

    networking.firewall.interfaces.${lanIface}.allowedTCPPorts = [ mqttPort mqttTlsPort ];
    networking.firewall.interfaces.${netbirdIface}.allowedTCPPorts = [ mqttPort ];

    # The overlay address must exist before Mosquitto binds it. The NetBird
    # client belongs to Core_Modules and remains present when this app is off.
    #
    # agenix installs the TLS key during activation, before units start.
    # Restart on key rotation, since /run/agenix/... never changes. Hash the
    # ciphertext: its store path embeds the whole flake source, which would
    # bounce the broker and every connected logger on each deploy.
    systemd.services.mosquitto = {
      wants = [ "netbird-address-verify.service" ];
      after = [ "netbird-address-verify.service" ];
      restartTriggers = [
        (builtins.hashFile "sha256" config.age.secrets.groundwaterMqttTlsKey.file)
      ];
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
