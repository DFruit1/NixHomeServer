{ config, lib, pkgs, self, vars, ... }:

let
  cfg = config.services.mail-archive-ui;
  user = "mail-archive-ui";
  group = "mail-archive-ui";
  defaultTags = [ "new" ];
  mailArchiveUiPort = 9011;
  mailArchiveStoreRoot = "${vars.dataRoot}/mail-archive";
  dataDirDefault = "/persist/appdata/mail-archive-ui";
  runtimeDirDefault = "/run/mail-archive-ui";
  lockDirDefault = "${dataDirDefault}/locks";
  environmentEntries =
    [
      "MAIL_ARCHIVE_UI_ADDRESS=${cfg.address}"
      "MAIL_ARCHIVE_UI_PORT=${toString cfg.port}"
      "MAIL_ARCHIVE_UI_DATA_DIR=${cfg.dataDir}"
      "MAIL_ARCHIVE_UI_STORE_ROOT=${cfg.storeRoot}"
      "MAIL_ARCHIVE_UI_RUNTIME_DIR=${cfg.runtimeDir}"
      "MAIL_ARCHIVE_UI_LOCK_DIR=${cfg.lockDir}"
      "MAIL_ARCHIVE_UI_DEFAULT_TAGS=${lib.concatStringsSep ";" defaultTags}"
    ]
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;
in
{
  imports = [ ./oauth2-proxy.nix ];

  options.services.mail-archive-ui = {
    enable = lib.mkEnableOption "the private mail archive UI service";

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.mail-archive-ui;
      description = "Package to run for the mail archive UI service.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = "127.0.0.1";
      description = "Address the mail archive UI listens on.";
    };

    port = lib.mkOption {
      type = lib.types.port;
      default = mailArchiveUiPort;
      description = "Port the mail archive UI listens on.";
    };

    dataDir = lib.mkOption {
      type = lib.types.str;
      default = dataDirDefault;
      description = "Writable app data directory for sqlite state and the app master key.";
    };

    storeRoot = lib.mkOption {
      type = lib.types.str;
      default = mailArchiveStoreRoot;
      description = "Writable root for downloaded mail archives.";
    };

    runtimeDir = lib.mkOption {
      type = lib.types.str;
      default = runtimeDirDefault;
      description = "Runtime directory used for temporary sync secrets and generated config.";
    };

    lockDir = lib.mkOption {
      type = lib.types.str;
      default = lockDirDefault;
      description = "Directory used for per-account sync locks.";
    };

    environment = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      description = "Extra environment variables passed to the mail archive UI service.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = group;
      home = cfg.dataDir;
      createHome = false;
    };

    users.groups.${group} = { };

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${user} ${group} -"
      "d ${cfg.runtimeDir} 0750 ${user} ${group} -"
      "d ${cfg.lockDir} 0750 ${user} ${group} -"
    ];

    systemd.services.mail-archive-ui = {
      description = "Mail archive UI";
      wantedBy = [ "multi-user.target" ];
      wants = [
        "app-state-migration-v1.service"
        "data-pool-layout.service"
        "network-online.target"
        "local-fs.target"
      ];
      after = [
        "app-state-migration-v1.service"
        "data-pool-layout.service"
        "network-online.target"
        "local-fs.target"
      ];
      path = [ pkgs.isync pkgs.notmuch pkgs.coreutils ];

      serviceConfig = {
        Type = "simple";
        User = user;
        Group = group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${cfg.package}/bin/mail-archive-ui";
        Environment = environmentEntries;
        Restart = "on-failure";
        DynamicUser = false;
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
        ReadWritePaths = [
          cfg.dataDir
          cfg.storeRoot
          cfg.runtimeDir
          cfg.lockDir
        ];
      };
    };
  };
}
