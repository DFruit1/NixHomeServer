{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./collabora.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.opencloud = true;
}
