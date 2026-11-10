{ config, lib, ... }:
{
  imports = [ ./identity.nix ./networking.nix ./bootstrap.nix ./services.nix ./backups.nix ];
  options.repo.paperlessGpt.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
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
