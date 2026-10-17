{ ... }:
{
  imports = [ ./services.nix ./bootstrap.nix ./identity.nix ./oidc-reconcile.nix ./networking.nix ./backups.nix ];
  nixhomeserver.modules.langfuse = true;
}
