{ ... }:

{
  imports = [
    ./identity.nix
    ./networking.nix
    ./services.nix
  ];

  nixhomeserver.modules.filesync = true;
}
