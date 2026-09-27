{ pkgs, ... }:

let
  shutdownGuard = pkgs.writeShellApplication {
    name = "nixhomeserver-shutdown-guard";
    runtimeInputs = with pkgs; [
      coreutils
      gnugrep
      procps
      systemd
      zfs
    ];
    text = builtins.readFile ../../../scripts/helpers/shutdown-guard.sh;
  };
in
{
  # Guarded server shutdown helper for the desktop orchestrator. The script
  # schedules a shutdown, postpones it while a critical task is active, and
  # exposes machine-readable status over SSH. It is covered by the host's
  # existing NOPASSWD admin contract, so the desktop never prompts for a sudo
  # password.
  environment.systemPackages = [ shutdownGuard ];

  environment.etc."nixhomeserver/shutdown-guard.conf".text = ''
    # Critical tasks that postpone a guarded server shutdown. Edit through this
    # module, not directly on the host. Only task units belong here: always-on
    # daemons such as kopia.service, media-manager.service, and
    # youtube-downloader.service stay active by design and must never block a
    # shutdown. Their child work is covered by CRITICAL_PROCESSES.
    CRITICAL_UNITS=(
      backup-prepare.service
      files-archives-sync.service
      jellyfin-library-sync.service
      kiwix-library-sync.service
      kopia-full-maintenance.service
      kopia-persist-snapshot.service
      kopia-snapshot-verify.service
      mail-archive-sync.service
      media-manager-refresh-dispatch.service
      media-manager-scanner.service
      rclone-mega-kopia-sync.service
    )
    CRITICAL_PROCESSES=(
      aapt2
      apksigner
      borg
      cargo
      cc1
      cc1plus
      clang
      ffmpeg
      gcc
      make
      ninja
      nix
      nix-build
      nix-instantiate
      nix-store
      nixos-rebuild
      playwright
      pnpm
      pytest
      qbittorrent-nox
      rclone
      restic
      rsync
      rustc
      vitest
      yt-dlp
      zfs
      zipalign
    )
    # Match active command lines for tools launched through bash, Java, or Node.
    # Avoid matching idle Gradle/Kotlin daemons and always-on app processes.
    CRITICAL_PROCESS_PATTERNS=(
      '(^|[[:space:]/])validate-repo[.]sh([[:space:]]|$)'
      '(^|[[:space:]/])run-script-tests[.]sh([[:space:]]|$)'
      '(^|[[:space:]/])build-android[.]sh([[:space:]]|$)'
      'org[.]gradle[.]wrapper[.]GradleWrapperMain'
      '(^|[[:space:]/])(pnpm|npm|npx)([[:space:]]|$)'
      '(^|[[:space:]/])(vitest|playwright|jest|bats|ctest)([[:space:]]|$)'
    )
    CRITICAL_COMMANDS=(
      "zpool status 2>/dev/null | grep -Eq 'scrub in progress|resilver in progress'"
    )
  '';
}
