{ ... }:

{
  imports = [
    ./networking.nix
    ./identity.nix
    ./filepaths.nix
    ./services.nix
    ./bootstrap.nix
    ./backups.nix
    ./integrations/copyparty.nix
    ./integrations/mail-archive-ui.nix
  ];
}
