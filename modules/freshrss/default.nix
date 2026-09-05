{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./filepaths.nix
    ./package.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.freshrss = true;
}
