{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.mail-archive-ui;
  mailArchiveSyncTimer = "*-*-* 06,18:15:00";
  defaultTags = [ "new" ];
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
    ]
    ++ lib.optional (cfg.visibleMirrorReadGroup != null) "MAIL_ARCHIVE_UI_VISIBLE_MIRROR_READ_GROUP=${cfg.visibleMirrorReadGroup}"
    ++ lib.mapAttrsToList (name: value: "${name}=${value}") cfg.environment;
in
{
  environment.systemPackages = [
    pkgs.isync
    pkgs.notmuch
  ];

  systemd.services.mail-archive-sync = lib.mkIf cfg.enable {
    description = "Synchronize mail archive UI accounts and refresh notmuch indexes";
    wants = [ "mail-archive-ui.service" "local-fs.target" "network-online.target" "unbound.service" ];
    after = [ "mail-archive-ui.service" "local-fs.target" "network-online.target" "unbound.service" ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      User = "mail-archive-ui";
      Group = "mail-archive-ui";
      WorkingDirectory = cfg.dataDir;
      ExecStart = "${cfg.package}/bin/mail-archive-ui sync-due";
      Environment = environmentEntries;
      UMask = "0077";
      NoNewPrivileges = true;
      PrivateTmp = true;
      ProtectSystem = "strict";
      ProtectHome = true;
      RestrictAddressFamilies = [ "AF_INET" "AF_INET6" "AF_UNIX" ];
      ReadWritePaths = [
        cfg.dataDir
        cfg.storeRoot
        cfg.accountStateRoot
        cfg.runtimeDir
        cfg.lockDir
      ];
    };
    path = [ pkgs.acl pkgs.isync pkgs.notmuch pkgs.coreutils pkgs.file pkgs.ripmime ];
  };

  systemd.timers.mail-archive-sync = lib.mkIf cfg.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = mailArchiveSyncTimer;
      Persistent = true;
    };
  };
}
