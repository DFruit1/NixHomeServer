{ ... }:

{
  imports = [
    ./package.nix
    ./identity.nix
    ./networking.nix
    ./filepaths.nix
    ./bootstrap.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.qwen-27b = true;
}
