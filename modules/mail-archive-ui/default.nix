{ config, lib, pkgs, self, vars, ... }:

let
  cfg = config.services.mail-archive-ui;
  user = "mail-archive-ui";
  group = "mail-archive-ui";
  hardening = import ../lib/systemd-hardening.nix { inherit lib; };
  defaultTags = [ "new" ];
  mailArchiveUiPort = vars.networking.ports.mailArchiveUi;
  mailArchiveStoreRoot = vars.usersRoot;
  dataDirDefault = "/persist/appdata/mail-archive-ui";
  runtimeDirDefault = "/run/mail-archive-ui";
  lockDirDefault = "${dataDirDefault}/locks";
  environmentEntries =
    [
      "MAIL_ARCHIVE_UI_ADDRESS=${cfg.address}"
      "MAIL_ARCHIVE_UI_PORT=${toString cfg.port}"
      "MAIL_ARCHIVE_UI_DATA_DIR=${cfg.dataDir}"
      "MAIL_ARCHIVE_UI_STORE_ROOT=${cfg.storeRoot}"
      "MAIL_ARCHIVE_UI_ACCOUNT_STATE_ROOT=${cfg.accountStateRoot}"
      "MAIL_ARCHIVE_UI_RUNTIME_DIR=${cfg.runtimeDir}"
      "MAIL_ARCHIVE_UI_LOCK_DIR=${cfg.lockDir}"
      "MAIL_ARCHIVE_UI_DEFAULT_TAGS=${lib.concatStringsSep ";" defaultTags}"
      "TMPDIR=${cfg.runtimeDir}"
      "SQLITE_TMPDIR=${cfg.runtimeDir}"
    ]
    ++ lib.optional (cfg.paperlessConsumeRoot != null) "MAIL_ARCHIVE_UI_PAPERLESS_CONSUME_ROOT=${cfg.paperlessConsumeRoot}"
    ++ lib.optional (cfg.paperlessHandoffStagingRoot != null) "MAIL_ARCHIVE_UI_PAPERLESS_HANDOFF_STAGING_ROOT=${cfg.paperlessHandoffStagingRoot}"
    ++ lib.optional (cfg.visibleMirrorReadGroup != null) "MAIL_ARCHIVE_UI_VISIBLE_MIRROR_READ_GROUP=${cfg.visibleMirrorReadGroup}"
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;
  mailArchiveUiPath = with pkgs; [
    acl
    coreutils
    file
    isync
    notmuch
    ripmime
  ];
in
{
  imports = [
    ./oauth2-proxy.nix
    ./storage.nix
  ];

  options.services.mail-archive-ui = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.nixhomeserver.apps."mail-archive-ui".enable;
      description = "Whether to run the private mail archive UI service.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = self.packages.${pkgs.stdenv.hostPlatform.system}.mail-archive-ui;
      description = "Package to run for the mail archive UI service.";
    };

    address = lib.mkOption {
      type = lib.types.str;
      default = vars.networking.loopbackIPv4;
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
      description = "Writable root containing per-user content directories for downloaded mail archives.";
    };

    accountStateRoot = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.dataDir}/accounts";
      description = "Writable root for per-account derived sync and indexing state.";
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

    visibleMirrorReadGroup = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = "filebrowser-quantum";
      description = "Optional local group granted read ACLs on the user-visible email mirror files.";
    };

    paperlessConsumeRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if (config.services.paperless.enable or false) then vars.paperlessInboxRoot else null;
      description = "Optional Paperless consume directory where attachment handoffs are copied.";
    };

    paperlessHandoffStagingRoot = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = if (config.services.paperless.enable or false) then vars.paperlessHandoffStagingRoot else null;
      description = "Optional staging directory used to finish attachment copies before publishing them to the Paperless consume directory.";
    };
  };

  config = lib.mkIf cfg.enable {
    users.users.${user} = {
      isSystemUser = true;
      group = group;
      home = cfg.dataDir;
      createHome = false;
      extraGroups = lib.optional (cfg.paperlessConsumeRoot != null) "paperless";
    };

    users.groups.${group} = { };

    environment.systemPackages = [
      cfg.package
    ];

    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0750 ${user} ${group} -"
      "d ${cfg.accountStateRoot} 0750 ${user} ${group} -"
      "d ${cfg.runtimeDir} 0750 ${user} ${group} -"
      "d ${cfg.lockDir} 0750 ${user} ${group} -"
    ];

    systemd.services.mail-archive-ui = {
      description = "Mail archive UI";
      wantedBy = [ "multi-user.target" ];
      unitConfig = {
        ConditionPathIsMountPoint = vars.dataRoot;
        RequiresMountsFor = [
          cfg.storeRoot
          cfg.dataDir
          cfg.accountStateRoot
          cfg.runtimeDir
          cfg.lockDir
        ] ++ lib.optional (cfg.paperlessConsumeRoot != null) cfg.paperlessConsumeRoot
          ++ lib.optional (cfg.paperlessHandoffStagingRoot != null) cfg.paperlessHandoffStagingRoot;
      };
      wants = [
        "data-pool-layout.service"
        "local-fs.target"
      ];
      after = [
        "data-pool-layout.service"
        "local-fs.target"
      ];
      path = mailArchiveUiPath;

      serviceConfig = hardening.merge hardening.networkProxy {
        Type = "simple";
        User = user;
        Group = group;
        WorkingDirectory = cfg.dataDir;
        ExecStart = "${cfg.package}/bin/mail-archive-ui";
        Environment = environmentEntries;
        Restart = "on-failure";
        UMask = "0077";
        DynamicUser = false;
        ReadWritePaths = [
          cfg.dataDir
          cfg.storeRoot
          cfg.accountStateRoot
          cfg.runtimeDir
          cfg.lockDir
        ] ++ lib.optional (cfg.paperlessConsumeRoot != null) cfg.paperlessConsumeRoot
          ++ lib.optional (cfg.paperlessHandoffStagingRoot != null) cfg.paperlessHandoffStagingRoot;
      };
    };
  };
}
