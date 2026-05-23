{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
    ./integrations/audiobookshelf.nix
    ./integrations/copyparty.nix
    ./integrations/jellyfin.nix
    ./integrations/kavita.nix
    ./integrations/kiwix.nix
  ];
}
