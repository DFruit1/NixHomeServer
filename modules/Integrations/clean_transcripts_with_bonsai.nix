# Bonsai proofreads finished transcripts when a job asks for it (the Media
# Manager upload form does by default): names, uncommon words and clearly
# misheard words, returned as short corrections that the worker checks before
# applying. Requests go through the loopback concurrency gate like every other
# background Bonsai client. The worker otherwise has no network, so it gains
# loopback IPv4 only.
{ config, lib, ... }:
{
  config = lib.mkIf (config.repo.transcribe.enable && config.repo.bonsai.enable && config.repo.bonsai.gate.enable) {
    systemd.services.transcribe-worker = {
      environment = {
        TRANSCRIBE_CLEANUP_URL = config.repo.bonsai.gate.gateBaseUrl;
        TRANSCRIBE_CLEANUP_MODEL = config.repo.bonsai.modelName;
      };
      serviceConfig = {
        PrivateNetwork = lib.mkForce false;
        RestrictAddressFamilies = lib.mkForce [ "AF_UNIX" "AF_INET" ];
        IPAddressDeny = "any";
        IPAddressAllow = "localhost";
      };
    };
  };
}
