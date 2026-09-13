{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./oauth2-proxy.nix
    ./bootstrap.nix
    ./backups.nix
  ];

  nixhomeserver.modules.calibre-web = true;
}
