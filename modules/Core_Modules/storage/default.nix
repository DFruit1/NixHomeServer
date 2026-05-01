{ ... }:

{
  imports = [
    ./fileshare-user-roots.nix
    ./import-fix.nix
    ./layout.nix
    ./media-retirement.nix
    ./retired-roots-cleanup.nix
  ];
}
