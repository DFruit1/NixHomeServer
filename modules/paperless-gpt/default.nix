{ config, lib, ... }:
{
  imports = [ ./identity.nix ./networking.nix ./bootstrap.nix ./services.nix ./backups.nix ];
  options.repo.paperlessGpt.enable = lib.mkOption {
    type = lib.types.bool;
    # The integration enables this only while its required apps are enabled.
    # Explicit enable requests still retain the dependency assertions below.
    default = false;
    description = "Enable private Paperless-GPT metadata suggestions.";
  };
  config.nixhomeserver.modules.paperless-gpt = true;
  config.assertions = lib.mkIf config.repo.paperlessGpt.enable [
    {
      assertion = (config.nixhomeserver.modules.paperless or false)
        && (config.nixhomeserver.modules.bonsai or false);
      message = "Paperless-GPT requires the paperless and bonsai applications.";
    }
  ];
}
