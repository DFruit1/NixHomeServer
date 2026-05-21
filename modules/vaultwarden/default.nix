{ ... }:

{
  imports = [
    ./filepaths.nix
    ./impermanence.nix
    ./backups.nix
    ./networking.nix
    ./service.nix
    ./kanidm-admin.nix
  ];
}
