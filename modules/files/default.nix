{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./archives.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.files = true;
}
