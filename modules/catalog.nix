let
  app = module: displayName: category: secrets: guardedServices: {
    inherit module displayName category secrets guardedServices;
    registration =
      if builtins.pathExists (module + "/registration.nix") then
        import (module + "/registration.nix")
      else { ports = { }; homepage = _: [ ]; };
  };
in
rec {
  apps = {
    attic = app ./attic "Attic Build Cache" "operations" [ "atticServerEnv" ] [ ];
    audiobookshelf = app ./audiobookshelf "Audiobookshelf" "media" [
      "absBootstrapPass"
      "absClientSecret"
    ] [ ];
    bonsai = app ./bonsai "Bonsai AI" "automation" [ ] [ ];
    browsertrix-downloader = app ./browsertrix-downloader "Web Archives" "knowledge" [
      "browsertrixDownloaderOauth2ProxyClientSecret"
      "browsertrixDownloaderOauth2ProxyCookieSecret"
    ] [
      "browsertrix-downloader-storage-layout-v1"
      "browsertrix-downloader"
      "browsertrix-downloader-worker"
    ];
    chaptarr = app ./chaptarr "Chaptarr" "media-automation" [ ] [
      "chaptarr"
      "chaptarr-storage-layout-v1"
      "media-automation-bootstrap-chaptarr"
    ];
    files = app ./files "Files" "storage" [ ] [ ];
    freshrss = app ./freshrss "FreshRSS" "knowledge" [ ] [ ];
    groundwater-logger = app ./groundwater-logger "Groundwater Logger" "operations" [
      "groundwaterAppMqttPassword"
      "groundwaterLoggerMqttPassword"
    ] [ ];
    immich = app ./immich "Immich" "media" [ "immichClientSecret" ] [
      "immich-storage-layout-v1"
      "immich-server"
    ];
    jellyfin = app ./jellyfin "Jellyfin" "media" [ "jellyfinOidcClientSecret" ] [
      "jellyfin-oidc-bootstrap-v1"
      "jellyfin-metadata-bootstrap-v1"
    ];
    kavita = app ./kavita "Kavita" "media" [
      "kavitaClientSecret"
      "kavitaTokenKey"
    ] [
      "kavita-storage-layout-v1"
      "kavita"
      "kavita-stale-reference-cleanup"
    ];
    kiwix = app ./kiwix "Kiwix" "knowledge" [
      "kiwixOauth2ProxyClientSecret"
      "kiwixOauth2ProxyCookieSecret"
    ] [
      "kiwix-library-root-layout-v1"
      "kiwix-library-sync"
      "kiwix-library-watch"
      "kiwix-serve"
      "kiwix-serve-archives"
    ];
    mail-archive-ui = app ./mail-archive-ui "Mail Archive" "productivity" [
      "mailArchiveOauth2ProxyClientSecret"
      "mailArchiveOauth2ProxyCookieSecret"
    ] [
      "mail-archive-ui-storage-layout-v1"
      "mail-archive-ui"
      "mail-archive-sync"
      "mail-archive-canary-seed"
      "mail-archive-paperless-tasks"
    ];
    mkvmaker = app ./mkvmaker "DVD ISO Converter" "media" [ ] [
      "mkvmaker-storage-layout-v1"
      "mkvmaker-import"
      "mkvmaker-import-worker"
    ];
    offline-music = app ./offline-music "Offline Music" "media" [ ] [
      "offline-media-reconcile"
    ];
    paperless = app ./paperless "Paperless" "productivity" [ "paperlessClientSecret" ] [
      "paperless-storage-layout-v1"
      "paperless-consumer"
      "paperless-scheduler"
      "paperless-task-queue"
      "paperless-web"
      "paperless-exporter"
      "paperless-stale-reference-check"
    ];
    prowlarr = app ./prowlarr "Prowlarr" "media-automation" [
      "prowlarrOauth2ProxyClientSecret"
      "prowlarrOauth2ProxyCookieSecret"
    ] [ ];
    qbittorrent = app ./qbittorrent "qBittorrent" "media-automation" [
      "qbittorrentOauth2ProxyClientSecret"
      "qbittorrentOauth2ProxyCookieSecret"
    ] [
      "qbittorrent"
      "media-automation-bootstrap-qbittorrent"
    ];
    qwen-flash-next = app ./qwen-flash-next "Qwen Flash Next" "automation" [ ] [
      "qwen-flash-next-storage-layout-v1"
      "qwen-flash-next-model-prepare"
      "qwen-flash-next-llama"
    ];
    radarr = app ./radarr "Radarr" "media-automation" [
      "radarrOauth2ProxyClientSecret"
      "radarrOauth2ProxyCookieSecret"
    ] [
      "radarr"
      "media-automation-bootstrap-radarr"
    ];
    search = app ./search "Search" "knowledge" [ ] [
      "search-solr"
      "search-solr-core-bootstrap"
      "search-ui"
      "search-index"
      "search-reindex"
      "search-reconcile"
    ];
    sonarr = app ./sonarr "Sonarr" "media-automation" [
      "sonarrOauth2ProxyClientSecret"
      "sonarrOauth2ProxyCookieSecret"
    ] [
      "sonarr"
      "media-automation-bootstrap-sonarr"
    ];
    vaultwarden = app ./vaultwarden "Vaultwarden" "security" [ "vaultwardenAdminToken" ] [ ];
    youtube-downloader = app ./youtube-downloader "YouTube Downloader" "media" [
      "youtubeDownloaderOauth2ProxyClientSecret"
      "youtubeDownloaderOauth2ProxyCookieSecret"
    ] [ ];
  };

  integrationDefinitions = [
    { module = ./Integrations/expose_browsertrix_crawls_to_search.nix; allApps = [ "search" "browsertrix-downloader" ]; anyApps = [ ]; }
    { module = ./Integrations/expose_freshrss_entries_to_search.nix; allApps = [ "search" "freshrss" ]; anyApps = [ ]; }
    { module = ./Integrations/expose_kiwix_archives_to_search.nix; allApps = [ "search" "kiwix" ]; anyApps = [ ]; }
    { module = ./Integrations/expose_mail_archive_emails_to_search.nix; allApps = [ "search" "mail-archive-ui" ]; anyApps = [ ]; }
    { module = ./Integrations/expose_paperless_documents_to_search.nix; allApps = [ "search" "paperless" ]; anyApps = [ ]; }
    { module = ./Integrations/expose_mail_archive_emails_in_files.nix; allApps = [ "mail-archive-ui" "files" ]; anyApps = [ ]; }
    { module = ./Integrations/grant_archives_access_to_kiwix_library.nix; allApps = [ "browsertrix-downloader" "kiwix" ]; anyApps = [ ]; }
    { module = ./Integrations/grant_files_access_to_audiobookshelf_media.nix; allApps = [ "files" "audiobookshelf" ]; anyApps = [ ]; }
    { module = ./Integrations/grant_files_access_to_jellyfin_media.nix; allApps = [ "files" "jellyfin" ]; anyApps = [ ]; }
    { module = ./Integrations/grant_files_access_to_kavita_media.nix; allApps = [ "files" "kavita" ]; anyApps = [ ]; }
    { module = ./Integrations/grant_files_access_to_kiwix_library.nix; allApps = [ "files" "kiwix" ]; anyApps = [ ]; }
    { module = ./Integrations/grant_mail_archive_access_to_paperless_consume_subdirectory.nix; allApps = [ "mail-archive-ui" "paperless" ]; anyApps = [ ]; }
    { module = ./Integrations/send_mail_archive_documents_to_paperless.nix; allApps = [ "mail-archive-ui" "paperless" ]; anyApps = [ ]; }
    { module = ./Integrations/wait_for_audiobookshelf_storage_before_youtube_downloader.nix; allApps = [ "audiobookshelf" "youtube-downloader" ]; anyApps = [ ]; }
    { module = ./Integrations/wait_for_jellyfin_storage_before_youtube_downloader.nix; allApps = [ "jellyfin" "youtube-downloader" ]; anyApps = [ ]; }
    { module = ./Integrations/wire_media_automation_stack.nix; allApps = [ ]; anyApps = [ "chaptarr" "sonarr" "radarr" "prowlarr" "qbittorrent" ]; }
  ];
  integrations = map (entry: entry.module) integrationDefinitions;
}
