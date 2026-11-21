{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./audio-import.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.mkvmaker = true;
}
