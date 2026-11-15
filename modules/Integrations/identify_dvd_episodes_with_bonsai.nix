# Bonsai reads DVD menus ("Series One - Episode Five 'Title'"), splits
# run-together volume labels, and ranks episode summaries against a transcript
# for mkvmaker's episode identifier. Requests go through the concurrency gate
# like every other local background client. Every answer is cross-checked
# against TVmaze before it can name a file.
{ config, lib, ... }:
{
  repo.mkvmaker.identify.bonsaiUrl = lib.mkIf config.repo.bonsai.gate.enable
    config.repo.bonsai.gate.gateBaseUrl;
}
