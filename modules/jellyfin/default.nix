{ ... }:

{
  imports = [
    ./package.nix
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./bootstrap.nix
    ./oidc.nix
    ./backups.nix
  ];

  nixhomeserver.modules.jellyfin = true;
}
