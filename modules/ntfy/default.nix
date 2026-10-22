{ ... }:

{
  # registration.nix is deliberately not imported here: the module catalog
  # reads it as the app's port and Homepage registration rather than as a
  # NixOS module.
  imports = [
    ./identity.nix
    ./options.nix
    ./networking.nix
    ./services.nix
    ./backups.nix
    ./bootstrap.nix
  ];

  nixhomeserver.modules.ntfy = true;
}