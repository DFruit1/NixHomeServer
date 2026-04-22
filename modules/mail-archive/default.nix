{ config, lib, pkgs, vars, ... }:

let
  cfg = config.services.mail-archive-ui;
  mailArchiveSyncTimer = "*-*-* 06,18:15:00";
in
{
  environment.systemPackages = [
    pkgs.isync
    pkgs.notmuch
  ];

  systemd.services.mail-archive-sync = lib.mkIf cfg.enable {
    description = "Synchronize mail archive UI accounts and refresh notmuch indexes";
    wants = [ "mail-archive-ui.service" "local-fs.target" ];
    after = [ "mail-archive-ui.service" "local-fs.target" ];
    unitConfig.ConditionPathIsMountPoint = vars.dataRoot;
    serviceConfig = {
      Type = "oneshot";
      User = "mail-archive-ui";
      Group = "mail-archive-ui";
      WorkingDirectory = cfg.dataDir;
      ExecStart = "${cfg.package}/bin/mail-archive-ui sync-due";
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
    path = [ pkgs.isync pkgs.notmuch pkgs.coreutils ];
  };

  systemd.timers.mail-archive-sync = lib.mkIf cfg.enable {
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = mailArchiveSyncTimer;
      Persistent = true;
    };
  };
}
