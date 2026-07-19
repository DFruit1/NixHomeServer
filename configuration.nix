{ ... }:

{
  imports = [
    ./system-resources.nix
    ./modules/Core_Modules

    ./modules/audiobookshelf
    ./modules/files
    ./modules/groundwater-logger
    ./modules/homepage
    ./modules/immich
    ./modules/jellyfin
    ./modules/kiwix
    ./modules/kavita
    ./modules/mail-archive-ui
    ./modules/offline-music
    ./modules/youtube-downloader
    ./modules/paperless
    ./modules/prowlarr
    ./modules/qbittorrent
    ./modules/radarr
    ./modules/seerr
    ./modules/sonarr
    ./modules/vaultwarden

    ./modules/Integrations/expose_mail_archive_emails_in_files.nix
    ./modules/Integrations/grant_files_access_to_audiobookshelf_media.nix
    ./modules/Integrations/grant_files_access_to_jellyfin_media.nix
    ./modules/Integrations/grant_files_access_to_kavita_media.nix
    ./modules/Integrations/grant_files_access_to_kiwix_library.nix
    ./modules/Integrations/remove_direct_mail_archive_access_from_paperless_inbox.nix
    ./modules/Integrations/send_mail_archive_documents_to_paperless.nix
    ./modules/Integrations/wait_for_audiobookshelf_storage_before_youtube_downloader.nix
    ./modules/Integrations/wait_for_jellyfin_storage_before_youtube_downloader.nix
    ./modules/Integrations/wire_media_automation_stack.nix
  ];
}
