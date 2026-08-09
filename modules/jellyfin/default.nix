{ ... }:

{
  imports = [
    ./package.nix
    ./plugins.nix
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./bootstrap.nix
    ./oidc.nix
    ./metadata.nix
    ./backups.nix
  ];

  nixhomeserver.modules.jellyfin = true;
}
