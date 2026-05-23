{ ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./modules/Core_Modules

    ./modules/audiobookshelf
    ./modules/copyparty
    ./modules/files
    ./modules/immich
    ./modules/jellyfin
    ./modules/kiwix
    ./modules/kavita
    ./modules/mail-archive-ui
    ./modules/youtube-downloader
    ./modules/paperless
    ./modules/power-management
    ./modules/vaultwarden

    ./modules/copyparty/integrations/kiwix.nix
    ./modules/files/integrations/audiobookshelf.nix
    ./modules/files/integrations/copyparty.nix
    ./modules/files/integrations/jellyfin.nix
    ./modules/files/integrations/kavita.nix
    ./modules/files/integrations/kiwix.nix
    ./modules/mail-archive-ui/integrations/files.nix
    ./modules/mail-archive-ui/integrations/paperless.nix
    ./modules/paperless/integrations/copyparty.nix
    ./modules/paperless/integrations/mail-archive-ui.nix
    ./modules/youtube-downloader/integrations/audiobookshelf.nix
    ./modules/youtube-downloader/integrations/jellyfin.nix
  ];
}
