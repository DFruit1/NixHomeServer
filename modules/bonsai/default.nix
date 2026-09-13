{ ... }:

{
  imports = [
    ./package.nix
    ./identity.nix
    ./networking.nix
    ./bootstrap.nix
    ./services.nix
    ./gate.nix
    ./backups.nix
  ];

  nixhomeserver.modules.bonsai = true;
}
