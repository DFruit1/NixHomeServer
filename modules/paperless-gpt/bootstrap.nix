{ config, lib, ... }:
{
  config = lib.mkIf config.repo.paperlessGpt.enable {
    systemd.tmpfiles.rules = map
      (suffix: "d /var/lib/paperless-gpt${suffix} 0750 paperless-gpt paperless-gpt - -")
      [ "" "/config" "/db" "/prompts" ];
  };
}
