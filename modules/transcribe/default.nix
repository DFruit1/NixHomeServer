{ lib, ... }:
{
  imports = [ ./package.nix ./identity.nix ./networking.nix ./filepaths.nix ./bootstrap.nix ./services.nix ./backups.nix ];
  options.repo.transcribe.enable = lib.mkOption { type = lib.types.bool; default = true; description = "Enable private inbox-based local speech transcription."; };
  config.nixhomeserver.modules.transcribe = true;
}
