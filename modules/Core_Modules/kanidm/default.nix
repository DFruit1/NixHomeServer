{ ... }:

{
  imports = [
    ./service.nix
    ./provision.nix
    ./files-posix-groups.nix
    ./branding.nix
    ./account-policy.nix
    ./user-tui.nix
  ];
}
