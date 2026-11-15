# Bonsai checks Media Manager's EYE photo tags against each photo and removes
# tags that do not describe it. The provider broker sends only the photo
# preview and EYE's tag names to the loopback Bonsai concurrency gate, like
# other background Bonsai clients; Immich credentials never leave the broker.
{ config, lib, ... }:
{
  config = lib.mkIf (config.services.immich.enable && config.repo.bonsai.enable && config.repo.bonsai.gate.enable) {
    # No unit ordering: Bonsai verifies its weights before starting, and the
    # broker must not wait for that. The reviewer retries until Bonsai answers.
    systemd.services.media-manager-provider-broker = {
      environment = {
        MEDIA_MANAGER_BONSAI_URL = config.repo.bonsai.gate.gateBaseUrl;
        MEDIA_MANAGER_BONSAI_MODEL = config.repo.bonsai.modelName;
      };
    };
  };
}
