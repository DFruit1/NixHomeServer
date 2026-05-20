{ ... }:

{
  imports = [
    ./service.nix
    ./provision.nix
    ./files-posix-groups.nix
    ./sftp-files.nix
    ./branding.nix
    ./account-policy.nix
    ./user-tui.nix
  ];
}
