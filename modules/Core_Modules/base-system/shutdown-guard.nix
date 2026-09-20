{ pkgs, ... }:

let
  shutdownGuard = pkgs.writeShellApplication {
    name = "nixhomeserver-shutdown-guard";
    runtimeInputs = with pkgs; [
      coreutils
      procps
      systemd
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
    # module, not directly on the host.
    CRITICAL_UNITS=(
      backup-prepare.service
      files-archives-sync.service
      jellyfin-library-sync.service
      kiwix-library-sync.service
      kopia-full-maintenance.service
      kopia-persist-snapshot.service
      kopia-snapshot-verify.service
      kopia.service
      mail-archive-sync.service
      media-manager-refresh-dispatch.service
      media-manager-scanner.service
      media-manager.service
      rclone-mega-kopia-sync.service
      youtube-downloader.service
    )
    CRITICAL_PROCESSES=(
      borg
      ffmpeg
      qbittorrent-nox
      rclone
      restic
      rsync
      yt-dlp
      zfs
    )
  '';
}
