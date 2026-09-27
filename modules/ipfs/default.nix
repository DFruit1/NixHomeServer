{ ... }:

{
  imports = [
    ./identity.nix
    ./filepaths.nix
    ./networking.nix
    ./bootstrap.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.ipfs = true;
}
