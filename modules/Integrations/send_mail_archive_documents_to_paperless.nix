{ config, lib, ... }:

{
  services.mail-archive-ui = {
    paperlessConsumeRoot = lib.mkDefault config.repo.paperless.paths.inbox;
    paperlessHandoffStagingRoot = lib.mkDefault config.repo.paperless.paths.handoffStaging;
  };

  users.users.mail-archive-ui.extraGroups = lib.mkAfter [
    "paperless"
  ];
}
