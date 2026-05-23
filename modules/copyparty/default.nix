{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
    ./integrations/kiwix.nix
  ];
}
