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
    ./integrations/jellyfin.nix
  ];
}
