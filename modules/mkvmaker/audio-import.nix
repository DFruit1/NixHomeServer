{ appPackages, config, lib, pkgs, vars, ... }:

let
  cfg = config.repo.mkvmaker;
  audio = cfg.audio;
  package = appPackages.mkvmaker;
  sharedAccessGroup = vars.fileAccess.sharedAccessGroup or "files-shared-users";
  # The personal inbox, relative to each user's file root.
  userInbox = "_ISO/_AudioCDs";
  # People rename a held folder to confirm it, so this one is group-writable.
  writableDirs = [
    audio.sharedInbox
    "${audio.sharedInbox}/_NeedsIdentification"
  ];
  archiveDirs = [
    "${audio.sharedInbox}/_Processed"
    "${audio.sharedInbox}/_Failed"
    "${audio.sharedInbox}/_Duplicate"
  ];
  command = lib.escapeShellArgs ([
    "${package}/bin/audio-import"
    "--inbox"
    "${audio.sharedInbox}=${toString audio.sharedLibrary}"
    "--state-dir"
    "${cfg.paths.stateRoot}/audio"
    "--status-file"
    "/run/mkvmaker-audio/status.json"
    # HandBrake's own FFmpeg build is already in the closure.
    "--ffmpeg"
    "${pkgs.handbrake.ffmpeg-hb}/bin/ffmpeg"
    "--ffprobe"
    "${pkgs.handbrake.ffmpeg-hb}/bin/ffprobe"
    "--sevenzip"
    "${pkgs._7zz}/bin/7zz"
    "--settle-seconds"
    (toString cfg.settleSeconds)
    "--max-attempts"
    (toString cfg.maxAttempts)
    "--retry-seconds"
    (toString cfg.retrySeconds)
  ] ++ lib.optionals (audio.userLibrary != null) [
    "--users-root"
    vars.usersRoot
    "--user-inbox"
    userInbox
    "--user-library"
    audio.userLibrary
  ]);
in
{
  options.repo.mkvmaker.audio = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = ''
        Import the desktop ripper's audio CD ISOs. Set by the integration
        that supplies a library to publish into.
      '';
    };
    sharedInbox = lib.mkOption {
      type = lib.types.str;
      default = "${cfg.paths.sharedIsoRoot}/_AudioCDs";
      description = "Shared inbox holding one folder per book with one ISO per CD.";
    };
    sharedLibrary = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Library that books from the shared inbox are published into.";
    };
    userLibrary = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      example = "_Audiobooks";
      description = ''
        Library folder inside each user's file root. When set, each user's
        ${userInbox} is watched too and publishes into that user's library.
      '';
    };
    libraryGroups = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Groups that grant the importer write access to the libraries.";
    };
    libraryUnits = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "Units that provision the libraries before the importer runs.";
    };
  };

  config = lib.mkIf audio.enable {
    assertions = [
      {
        assertion = audio.sharedLibrary != null;
        message = "repo.mkvmaker.audio.enable needs repo.mkvmaker.audio.sharedLibrary.";
      }
    ];

    repo.storage.dataPool.guardedServices = [
      "mkvmaker-audio-storage-layout-v1"
      "mkvmaker-audio-import"
    ];

    # The importer moves a user's ISOs out of that user's inbox, so it needs
    # write access below _ISO; the sticky bit on _ISO itself still keeps it
    # from removing the ISOs a user stores there directly.
    repo.storage.userRoots = lib.mkIf (audio.userLibrary != null) {
      rootTraverseGroups = [ "mkvmaker" ];
      recursiveWritableGrants = [
        {
          group = "mkvmaker";
          relativePaths = [ "_ISO" ];
        }
      ];
      perUserDirectories = [
        {
          root = vars.usersRoot;
          relativePath = userInbox;
          mode = "2770";
          user = "mkvmaker";
          group = "root";
        }
      ];
    };

    systemd.services.mkvmaker-audio-storage-layout-v1 = {
      description = "Provision the shared audio CD ISO inbox";
      wantedBy = [ "multi-user.target" ];
      requires = [ "mkvmaker-storage-layout-v1.service" ];
      after = [ "mkvmaker-storage-layout-v1.service" ];
      before = [ "mkvmaker-audio-import.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      path = [ pkgs.acl pkgs.coreutils ];
      script = ''
        set -euo pipefail

        install -d -m 2770 -o mkvmaker -g ${lib.escapeShellArg sharedAccessGroup} \
          ${lib.escapeShellArgs writableDirs}
        install -d -m 2750 -o mkvmaker -g ${lib.escapeShellArg sharedAccessGroup} \
          ${lib.escapeShellArgs archiveDirs}
        setfacl -m g:mkvmaker:rwx,d:g:mkvmaker:rwx \
          ${lib.escapeShellArgs (writableDirs ++ archiveDirs)}
      '';
    };

    systemd.timers.mkvmaker-audio-import = {
      description = "Check the audio CD ISO inboxes for settled uploads";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "2min";
        OnUnitInactiveSec = "1min";
        AccuracySec = "10s";
        Unit = "mkvmaker-audio-import.service";
      };
    };

    # Type=simple, started only by the timer: a book that is still encoding
    # never holds up a NixOS activation the way a long oneshot would.
    systemd.services.mkvmaker-audio-import = {
      description = "Import audio CD ISOs into their libraries";
      requires = [ "mkvmaker-audio-storage-layout-v1.service" ] ++ audio.libraryUnits;
      after = [ "mkvmaker-audio-storage-layout-v1.service" ] ++ audio.libraryUnits;
      environment.HOME = cfg.paths.stateRoot;
      unitConfig.RequiresMountsFor = [ vars.dataRoot ];
      serviceConfig = {
        Type = "simple";
        RuntimeDirectory = "mkvmaker-audio";
        RuntimeDirectoryMode = "0755";
        # Keeps status.json readable while the importer is idle.
        RuntimeDirectoryPreserve = "yes";
        User = "mkvmaker";
        Group = "mkvmaker";
        SupplementaryGroups = [ sharedAccessGroup ] ++ audio.libraryGroups;
        ExecStart = command;
        Restart = "no";
        TimeoutStopSec = "2min";
        KillSignal = "SIGINT";
        KillMode = "control-group";
        SuccessExitStatus = [ 130 "SIGINT" ];
        UMask = "0002";
        Nice = 10;
        CPUWeight = 25;
        IOWeight = 20;
        IOSchedulingClass = "best-effort";
        IOSchedulingPriority = 7;
        MemoryHigh = "1G";
        MemoryMax = "2G";
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
        RestrictAddressFamilies = [ "AF_UNIX" ];
        SystemCallArchitectures = "native";
        # Each entry is its own bind mount, so a rename between two of them
        # fails with EXDEV. The importer therefore stages a book inside its
        # library and archives ISOs inside their inbox.
        ReadWritePaths = [
          cfg.paths.stateRoot
          audio.sharedInbox
          audio.sharedLibrary
        ] ++ lib.optional (audio.userLibrary != null) vars.usersRoot;
      };
    };

    systemd.tmpfiles.rules = [
      "d /run/mkvmaker-audio 0755 mkvmaker mkvmaker -"
    ];
  };
}
