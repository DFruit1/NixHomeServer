{ ... }:

{
  imports = [
    ./package.nix
    ./identity.nix
    ./networking.nix
    ./filepaths.nix
    ./bootstrap.nix
    ./services.nix
    ./admin.nix
    ./backups.nix
  ];

  nixhomeserver.modules.ai-tools = true;
}
