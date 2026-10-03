{ ... }:

{
  imports = [
    ./package.nix
    ./identity.nix
    ./networking.nix
    ./services.nix
    ./backups.nix
  ];

  nixhomeserver.modules.ai-tools = true;
}
