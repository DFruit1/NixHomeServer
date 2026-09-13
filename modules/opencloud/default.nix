{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./collabora.nix
    ./webapps.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.opencloud = true;
}
