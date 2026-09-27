{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./filepaths.nix
    ./bootstrap.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.fdroid = true;
}
