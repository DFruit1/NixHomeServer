{ ... }:
{
  imports = [ ./services.nix ./bootstrap.nix ./identity.nix ./networking.nix ./backups.nix ];
  nixhomeserver.modules.langfuse = true;
}
