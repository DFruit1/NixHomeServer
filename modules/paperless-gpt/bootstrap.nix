{ config, lib, pkgs, ... }:
{
  config = lib.mkIf config.repo.paperlessGpt.enable {
    # A new impermanence bind mount may appear after tmpfiles during a live
    # activation. Create children after that mount, before starting Podman.
    systemd.services.paperless-gpt-state = {
      description = "Prepare persistent Paperless-GPT settings and history directories";
      before = [ "paperless-gpt.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      unitConfig.RequiresMountsFor = [ "/var/lib/paperless-gpt" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        ${pkgs.coreutils}/bin/install -d -m 0750 -o paperless-gpt -g paperless-gpt \
          /var/lib/paperless-gpt /var/lib/paperless-gpt/config \
          /var/lib/paperless-gpt/db /var/lib/paperless-gpt/prompts
      '';
    };
    systemd.services.paperless-gpt = {
      requires = [ "paperless-gpt-state.service" ];
      after = [ "paperless-gpt-state.service" ];
    };
  };
}
