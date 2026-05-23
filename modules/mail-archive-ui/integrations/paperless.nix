{ lib, vars, ... }:

{
  services.mail-archive-ui = {
    paperlessConsumeRoot = lib.mkDefault vars.paperlessInboxRoot;
    paperlessHandoffStagingRoot = lib.mkDefault vars.paperlessHandoffStagingRoot;
  };

  users.users.mail-archive-ui.extraGroups = lib.mkAfter [
    "paperless"
  ];
}
