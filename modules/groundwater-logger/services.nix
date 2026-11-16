{ appPackages, config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.groundwaterLogger;
  paths = cfg.paths;
  creds = cfg.deviceCredentials;
  notifications = cfg.notifications;
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
  # gwl/v1 protocol revision 2 (firmware 2.2, docs/gwl-v1-rev2.md in the
  # groundwater-server app) adds health, data/stream, data/file and
  # cmd/basic. Revision 1 channels (storage, motion, config/desired,
  # cmd/test) stay until no V2.1 unit uses them.
  loggerAcl = [
    "write gwl/v1/+/status"
    "write gwl/v1/+/info"
    "write gwl/v1/+/health"
    "write gwl/v1/+/data/stream"
    "write gwl/v1/+/data/file"
    "write gwl/v1/+/alerts"
    "write gwl/v1/+/test/result"
    "write gwl/v1/+/reading"
    "write gwl/v1/+/gps"
    "write gwl/v1/+/config/applied"
    "write gwl/v1/+/cmd/ack"
    "write gwl/v1/+/storage"
    "write gwl/v1/+/motion"
    "read gwl/v1/+/config/set"
    "read gwl/v1/+/cmd/basic"
    "read gwl/v1/+/cmd/danger"
    "read gwl/v1/+/config/desired"
    "read gwl/v1/+/cmd/test"
    "readwrite azman1/feeds/#"
    "readwrite testtopic/9"
    "read requesttesta"
    "read cmd/#"
    "read cfg/#"
    "write cfg/desired/applied"
    "write cfg/danger_ack"
  ];
  # Per-device accounts (opt-in): the username is the unit's DeviceID, and
  # these patterns give such an account exactly its own gwl/v1 topics. The
  # shared groundwater-logger account keeps its broad ACL above; a unit in
  # mode "device" additionally gets a deny for the shared account, written
  # by mqtt-auth-merge.sh from the server's devices.deny.
  devicePatternAcl =
    map (rule: "pattern ${lib.replaceStrings [ "gwl/v1/+/" ] [ "gwl/v1/%u/" ] rule}")
      (lib.filter (rule: lib.hasInfix "gwl/v1/+/" rule) loggerAcl);
  authDir = creds.directory;
  # writeShellApplication pins the tools (systemd's default PATH has no
  # awk) and shellchecks the script at build time.
  mergeScript = lib.getExe (pkgs.writeShellApplication {
    name = "groundwater-mqtt-auth-merge";
    runtimeInputs = [ pkgs.coreutils pkgs.gawk pkgs.gnugrep pkgs.gnused ];
    text = builtins.readFile ./mqtt-auth-merge.sh;
  });
  # Listener positions below: 0 loopback, 1 LAN, 2 NetBird, 3 TLS.
  deviceListeners = [ 1 2 3 ];
  mergeCommand = "${mergeScript} ${authDir} ${paths.brokerStateDir} groundwater-logger ${lib.concatMapStringsSep " " toString deviceListeners}";
  withDeviceAccounts = index: listener:
    listener // lib.optionalAttrs creds.enable {
      acl = devicePatternAcl;
      # The password file is the module's own passwd-N plus the device
      # accounts, merged by mqtt-auth-merge.sh; the plugin is the same one
      # the module would load, pointed at the merged copy.
      omitPasswordAuth = true;
      authPlugins = [{
        plugin = "${lib.getLib config.services.mosquitto.package}/lib/mosquitto_password_file.so";
        options.password_file = "${paths.brokerStateDir}/passwd-merged-${toString index}";
      }];
    };
  loggerUser = {
    groundwater-logger = {
      passwordFile = config.age.secrets.groundwaterLoggerMqttPassword.path;
      acl = loggerAcl;
    };
  };
  # Internet-facing listener: with tlsDeviceAccountsOnly the shared account
  # (which may publish as any DeviceID and read every unit's commands) is
  # absent, and the client ID must equal the authenticated DeviceID, so no
  # account can take over another unit's session.
  tlsDeviceOnly = creds.enable && creds.tlsDeviceAccountsOnly;
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

  options.repo.groundwaterLogger.notifications = {
    ntfyUrl = lib.mkOption {
      type = lib.types.nullOr (lib.types.strMatching "http://(127[.][0-9.]+|localhost)(:[0-9]+)?(/[A-Za-z0-9_-]+)?/?");
      default = null;
      example = "http://127.0.0.1:8099/groundwater";
      description = ''
        ntfy topic URL for alert notifications, on loopback only: ntfy topics
        are unauthenticated and messages name the device and its location.
        The ntfy integration sets this when the ntfy app is enabled; null
        records notifications without sending them.
      '';
    };
    publicUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://groundwater.${vars.domain}";
      description = "Base URL used for device links in notifications.";
    };
    maxPerHour = lib.mkOption {
      type = lib.types.ints.between 1 10000;
      default = 30;
      description = "Fleet-wide cap on notifications per hour; critical messages are exempt.";
    };
  };

  options.repo.groundwaterLogger.deviceCredentials = {
    enable = lib.mkEnableOption ''
      per-device MQTT accounts generated from the groundwater server's
      registry. Opt-in per unit: the shared groundwater-logger account keeps
      working until an operator moves a unit to its own account. Enabling
      this alone changes no unit's access
    '';
    tlsDeviceAccountsOnly = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Accept only per-device accounts on the internet-facing TLS listener
        (port 8883) and force each client ID to its username (the DeviceID).
        The shared groundwater-logger account then works only on the LAN and
        NetBird listeners. Enable once every field unit has been reflashed
        with its own account: a unit still using the shared account can no
        longer reach the broker through the router.
      '';
    };
    directory = lib.mkOption {
      type = lib.types.str;
      default = "/run/groundwater-mqtt-auth";
      description = ''
        Where the server writes devices.passwd and devices.deny. Derived from
        the database and rewritten at every server start, so tmpfs is enough.
      '';
    };
  };

  options.repo.groundwaterLogger.metrics.tokenFile = lib.mkOption {
    type = lib.types.nullOr lib.types.path;
    default = null;
    description = ''
      Root-readable file holding a bearer token that lets a scraper on this
      host read /metrics on the loopback port without a gateway session.
      Without it, /metrics needs an operator session.
    '';
  };

  options.repo.groundwaterLogger.retention = {
    days = lib.mkOption {
      type = lib.types.ints.positive;
      default = 90;
      description = "Maximum age of the raw MQTT delivery log; observations and audit records are retained.";
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = creds.tlsDeviceAccountsOnly -> creds.enable;
      message = "repo.groundwaterLogger.deviceCredentials.tlsDeviceAccountsOnly needs deviceCredentials.enable: without per-device accounts the TLS listener would accept no logger.";
    }];

    # Match the Unix service identity for passwordless local peer auth. This
    # app owns only its role/database; shared cluster tuning stays central.
    services.postgresql = {
      enable = true;
      ensureDatabases = [ "groundwater" ];
      ensureUsers = [{ name = "groundwater"; ensureDBOwnership = true; }];
    };

    services.mosquitto = {
      enable = true;
      # Loggers and the platform's -telemetry client use persistent sessions:
      # the broker queues commands for sleeping loggers and data for the
      # platform while it restarts. Persistence keeps both across a broker
      # restart.
      persistence = true;
      dataDir = paths.brokerStateDir;
      settings = {
        # A logger may sleep up to 27 days (send_s <= 2,332,800); keep its
        # session, subscriptions and queued commands well beyond that.
        persistent_client_expiration = "60d";
        # Per client (Mosquitto has no per-account value). A logger session
        # holds a few commands; the platform's durable -telemetry session
        # holds the fleet's uploads while the server is down. Past either
        # limit Mosquitto drops a queued QoS 1 message although the logger
        # already has its PUBACK and frees that ring space: permanent loss.
        # memory_limit below is sized above everything these limits allow,
        # so they, not memory, decide when that happens.
        # Sized for a week-long server outage: 50 loggers (the fleet is
        # tens), each sending a full ring (122 KiB = about 84 batches of
        # 1.5 KB plus about 15 JSON messages) once a day, is 350 connections,
        # about 35,000 messages and 47 MiB. A weekly logger sends at most one
        # ring a week, so the daily case bounds it. Twice that, rounded up:
        # 100,000 messages, 100 MiB. At about 250 bytes of broker overhead per
        # message the full queue takes about 124 MiB.
        max_queued_messages = 100000;
        max_queued_bytes = 104857600;
        # data/stream batches are <= 1,500 bytes binary or ~1.5 KiB hex;
        # JSON acks/status <= 4 KiB. 16 KiB leaves room for the topic and
        # MQTT framing while bounding abuse.
        max_packet_size = 16384;
        # Bound the broker's heap below its cgroup limit: anyone holding the
        # shared logger password can create persistent sessions and fill
        # their queues (the legacy readwrite topics let one account both
        # publish and subscribe). Past the limit Mosquitto fails allocations
        # instead of growing until the cgroup kills it (losing every queued
        # command), but a failed allocation also drops messages it has
        # already acknowledged to a logger, queued for the server's session
        # (mosquitto.conf(5)). So the limit sits above what legitimate
        # traffic can hold: the server session's full queue (about 124 MiB)
        # plus 512 KiB for each connection the listeners admit (176 below:
        # session state and 16 KiB packet buffers, 88 MiB) plus 44 MiB
        # headroom = 256 MiB. MemoryHigh/MemoryMax of the unit sit above it
        # for allocator overhead.
        memory_limit = 268435456;
        # Write queued messages and sessions to disk every minute rather
        # than the default 30: a power cut while the platform is down then
        # loses at most a minute of acknowledged uploads.
        autosave_interval = 60;
      };
      # max_connections per listener bounds the connections memory_limit is
      # sized for (176 in all): the server and local tools on loopback;
      # bench and legacy loggers on LAN and NetBird; field loggers on TLS
      # (the fleet is tens; raise with memory_limit past 64 units).
      listeners = [
        {
          address = listenAddress;
          port = mqttPort;
          users = listenerUsers;
          settings.max_connections = 16;
        }
        (withDeviceAccounts 1 {
          address = lanAddress;
          port = mqttPort;
          users = listenerUsers;
          settings.max_connections = 64;
        })
        (withDeviceAccounts 2 {
          address = netbirdAddress;
          port = mqttPort;
          users = listenerUsers;
          settings.max_connections = 32;
        })
        # Internet-facing TLS endpoint for field loggers: the router forwards
        # public TCP 8883 to this LAN address. Only logger accounts exist
        # here (the shared one unless tlsDeviceAccountsOnly, plus per-device
        # accounts), so the web app's broad ACL is never reachable from outside.
        # Ciphers stay at OpenSSL defaults; the Quectel EC21 needs RSA
        # certificates with ECDHE-RSA AES-CBC/GCM suites.
        (withDeviceAccounts 3 {
          address = lanAddress;
          port = mqttTlsPort;
          users = if tlsDeviceOnly then { } else loggerUser;
          settings = {
            certfile = "${./mqtt-tls/server.pem}";
            keyfile = config.age.secrets.groundwaterMqttTlsKey.path;
            tls_version = "tlsv1.2";
            require_certificate = false;
            max_connections = 64;
          } // lib.optionalAttrs tlsDeviceOnly {
            use_username_as_clientid = true;
          };
        })
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
      # After the module wrote passwd-N/acl-N.conf: add the device accounts
      # the server last published (none before its first start).
      preStart = lib.mkIf creds.enable (lib.mkAfter mergeCommand);
      serviceConfig = {
        ReadOnlyPaths = lib.mkIf creds.enable [ "-${authDir}" ];
        # Normal use is a few MiB. memory_limit (256 MiB) refuses
        # allocations first; these leave room for allocator overhead.
        MemoryHigh = "320M";
        MemoryMax = "448M";
      };
    };

    # The server writes into a setgid directory owned by its own user and the
    # broker's group; the broker reads, never writes, it.
    systemd.tmpfiles.rules = lib.mkIf creds.enable [
      "d ${authDir} 2750 groundwater mosquitto -"
    ];

    # Re-merge and reload the broker whenever the server bumps `serial`.
    systemd.paths.groundwater-mqtt-auth = lib.mkIf creds.enable {
      description = "Watch the groundwater server's per-device MQTT accounts";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = "${authDir}/serial";
        Unit = "groundwater-mqtt-auth.service";
      };
    };
    systemd.services.groundwater-mqtt-auth = lib.mkIf creds.enable {
      description = "Merge per-device MQTT accounts into Mosquitto and reload it";
      after = [ "mosquitto.service" ];
      # A stopped broker merges in its own preStart instead.
      requisite = [ "mosquitto.service" ];
      serviceConfig = {
        Type = "oneshot";
        User = "mosquitto";
        Group = "mosquitto";
        ExecStart = mergeCommand;
        # SIGHUP: the password-file and acl-file plugins reload their files.
        ExecStartPost = "+${config.systemd.package}/bin/systemctl reload mosquitto.service";
        UMask = "0077";
        NoNewPrivileges = true;
        PrivateTmp = true;
        PrivateNetwork = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ paths.brokerStateDir ];
        ReadOnlyPaths = [ authDir ];
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        LockPersonality = true;
        SystemCallArchitectures = "native";
      };
    };

    systemd.services.groundwater-server = {
      description = "Groundwater telemetry, commands and private web platform";
      # Never give up: an unattended ingest service that stopped after five
      # failed starts (PostgreSQL still recovering, say) stayed down until
      # someone noticed. Back off to one attempt every five minutes instead.
      unitConfig.StartLimitIntervalSec = 0;
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
        GROUNDWATER_PUBLIC_URL = notifications.publicUrl;
        GROUNDWATER_NOTIFY_MAX_PER_HOUR = toString notifications.maxPerHour;
      } // lib.optionalAttrs (notifications.ntfyUrl != null) {
        GROUNDWATER_NTFY_URL = notifications.ntfyUrl;
      } // lib.optionalAttrs creds.enable {
        GROUNDWATER_MQTT_AUTH_DIR = authDir;
      } // lib.optionalAttrs (cfg.metrics.tokenFile != null) {
        GROUNDWATER_METRICS_TOKEN_FILE = "%d/metrics-token";
      };
      serviceConfig = {
        Type = "simple";
        User = "groundwater";
        Group = "groundwater";
        ExecStart = "${appPackages.groundwater-server}/bin/groundwater-server";
        # PID 1 reads the existing agenix file; the new Unix identity never
        # needs access to the retained logger account or its historical files.
        LoadCredential = [ "mqtt-password:${config.age.secrets.groundwaterAppMqttPassword.path}" ]
          ++ lib.optional (cfg.metrics.tokenFile != null) "metrics-token:${toString cfg.metrics.tokenFile}";
        ReadWritePaths = lib.optional creds.enable authDir;
        Restart = "on-failure";
        RestartSec = "5s";
        RestartSteps = 6;
        RestartMaxDelaySec = "5min";
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
